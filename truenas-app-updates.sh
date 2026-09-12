#!/usr/bin/env bash
#
# Automated application updates for TrueNAS SCALE (24.10+, Docker apps).
#
#   Phase 1 — app.upgrade      : new catalog versions
#   Phase 2 — app.pull_images  : newer Docker images at the same version
#
# stdout  = summary intended for the cron job's email (empty = no email sent).
# Details = $LOGFILE and journald (journalctl -t truenas-app-updates).
#
# Written with the assistance of generative AI (Anthropic's Claude), reviewed
# by the author. See the transparency section in README.md.
#
# Do not edit the defaults below. Override them in a configuration file or
# through the environment — see README.md. Precedence, lowest to highest:
#
#   built-in defaults  <  configuration file  <  environment variables
#
set -uo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_NAME=$(basename -- "${BASH_SOURCE[0]}")

# ------------------------------------------------------------------- arguments
CONFIG=""
DRY_RUN=false

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [options]

  -c, --config FILE   Configuration file to source.
                      Default search order:
                        \$TNAU_CONFIG
                        $SCRIPT_DIR/truenas-app-updates.conf
                        /etc/truenas-app-updates.conf
  -n, --dry-run       Report what would be updated, change nothing.
  -h, --help          Show this help.

Every setting can also be overridden through the environment, which takes
precedence over the configuration file:

  UPGRADE_TIMEOUT=3600 PULL_IMAGES=false $SCRIPT_NAME
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    -c | --config)
        CONFIG=${2:-}
        [ -z "$CONFIG" ] && {
            echo "$SCRIPT_NAME: --config requires a path" >&2
            exit 2
        }
        shift 2
        ;;
    -n | --dry-run)
        DRY_RUN=true
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "$SCRIPT_NAME: unknown option '$1'" >&2
        usage >&2
        exit 2
        ;;
    esac
done

# ------------------------------------------------------------------- settings
# Names of every overridable setting. EXCLUDE is an array and cannot be passed
# through the environment; use EXCLUDE_LIST, a space-separated string, instead.
SETTINGS=(
    LOGFILE LOCKFILE TAG UPGRADE_TIMEOUT SETTLE_TIMEOUT SETTLE_INTERVAL
    LOG_MAX_BYTES SNAPSHOT_HOSTPATHS SKIP_STOPPED PULL_IMAGES GLOBAL_BUDGET
    EXCLUDE_LIST SEND_EMAIL EMAIL_TO
)

# Capture whatever the environment already provides, before defaults are set.
declare -A FROM_ENV=()
for _s in "${SETTINGS[@]}"; do
    [ -n "${!_s+x}" ] && FROM_ENV["$_s"]=${!_s}
done
unset _s

# --- built-in defaults -------------------------------------------------------
LOGFILE=/var/log/truenas-app-updates.log
LOCKFILE=/var/run/truenas-app-updates.lock
TAG=truenas-app-updates
UPGRADE_TIMEOUT=1800          # seconds, per application
SETTLE_TIMEOUT=240            # max wait before judging final state
SETTLE_INTERVAL=10
LOG_MAX_BYTES=$((5 * 1024 * 1024))
SNAPSHOT_HOSTPATHS=false      # ZFS snapshot of host paths before each upgrade
SKIP_STOPPED=true             # do not wake up deliberately stopped apps
PULL_IMAGES=true              # phase 2: refresh images ("latest" tags)
GLOBAL_BUDGET=14400           # 4 h ceiling for the whole cycle
EXCLUDE=()                    # apps never to touch, e.g. EXCLUDE=(stalwart)
EXCLUDE_LIST=""               # same thing as a space-separated string
SEND_EMAIL=true               # send the summary through mail.send
EMAIL_TO=""                   # space-separated; empty = local administrators

# --- configuration file ------------------------------------------------------
if [ -z "$CONFIG" ]; then
    for _c in "${TNAU_CONFIG:-}" \
        "$SCRIPT_DIR/truenas-app-updates.conf" \
        /etc/truenas-app-updates.conf; do
        if [ -n "$_c" ] && [ -f "$_c" ]; then
            CONFIG=$_c
            break
        fi
    done
    unset _c
fi

if [ -n "$CONFIG" ]; then
    if [ ! -r "$CONFIG" ]; then
        echo "$SCRIPT_NAME: configuration file not readable: $CONFIG" >&2
        exit 2
    fi
    # Sourced as root: refuse anything group- or world-writable.
    _mode=$(stat -c '%a' "$CONFIG")
    if [ $((8#$_mode & 8#022)) -ne 0 ]; then
        echo "$SCRIPT_NAME: refusing to source $CONFIG (mode $_mode, writable by others)" >&2
        echo "Fix with: chmod 644 $CONFIG" >&2
        exit 2
    fi
    unset _mode
    # shellcheck source=/dev/null
    . "$CONFIG" || {
        echo "$SCRIPT_NAME: failed to source $CONFIG" >&2
        exit 2
    }
fi

# --- environment wins over the file ------------------------------------------
for _s in "${!FROM_ENV[@]}"; do
    printf -v "$_s" '%s' "${FROM_ENV[$_s]}"
done
unset _s

# EXCLUDE_LIST, from either source, replaces the EXCLUDE array.
if [ -n "$EXCLUDE_LIST" ]; then
    read -r -a EXCLUDE <<<"$EXCLUDE_LIST"
fi

# ------------------------------------------------------------------- logging
NOTIF=""

mkdir -p "$(dirname "$LOGFILE")" || {
    echo "$SCRIPT_NAME: cannot create $(dirname "$LOGFILE")"
    exit 1
}

# simple rotation: keep the current cycle and the previous one
if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE")" -gt "$LOG_MAX_BYTES" ]; then
    mv -f "$LOGFILE" "$LOGFILE.1"
fi

exec 2>>"$LOGFILE"            # stderr to the log; stdout reserved for the summary

log() {
    local level=$1
    shift
    local msg="$*"
    printf '%s [%-5s] %s\n' "$(date -Is)" "$level" "$msg" >>"$LOGFILE"
    case "$level" in
    INFO)  logger -t "$TAG" -p daemon.info    "$msg" ;;
    WARN)  logger -t "$TAG" -p daemon.warning "$msg"; NOTIF+="[WARN]  $msg"$'\n' ;;
    ERROR) logger -t "$TAG" -p daemon.err     "$msg"; NOTIF+="[ERROR] $msg"$'\n' ;;
    esac
}

build_summary() {
    echo "TrueNAS applications — $(hostname) — $(date '+%Y-%m-%d %H:%M')"
    [ "$DRY_RUN" = true ] && echo "(dry run — nothing was changed)"
    echo
    printf '%s' "$NOTIF"
    echo
    echo "Details: $LOGFILE   (or: journalctl -t $TAG --since today)"
    echo "Rollback: midclt call app.rollback_versions NAME"
    echo "          midclt call --job app.rollback NAME '{\"app_version\":\"X.Y.Z\"}'"
}

# TrueNAS ships no local MTA, so cron cannot deliver a job's output. Hand the
# summary to the middleware instead, which uses the configured SMTP settings.
send_mail() {
    local subject=$1 body=$2 payload recipients
    recipients=$(printf '%s\n' $EMAIL_TO | jq -R . | jq -sc 'map(select(length > 0))')
    payload=$(jq -n --arg s "$subject" --arg t "$body" --argjson to "$recipients" \
        '{subject: $s, text: $t, html: null}
         + (if ($to | length) > 0 then {to: $to} else {} end)') || return 1
    timeout 120 midclt call --job mail.send "$payload" >/dev/null 2>>"$LOGFILE"
}

emit_summary() {
    [ -z "$NOTIF" ] && return 0

    local body subject
    body=$(build_summary)
    if printf '%s' "$NOTIF" | grep -q '^\[ERROR\]'; then
        subject="[ERROR] TrueNAS app updates on $(hostname)"
    else
        subject="TrueNAS app updates on $(hostname)"
    fi

    if [ "$SEND_EMAIL" = true ]; then
        if send_mail "$subject" "$body"; then
            log INFO "Summary emailed via mail.send"
            # Also show it when run from a terminal; stays silent under cron so
            # that a working MTA would not produce a second copy.
            [ -t 1 ] && printf '%s\n' "$body"
            return 0
        fi
        log ERROR "mail.send failed — falling back to stdout"
    fi

    printf '%s\n' "$body"
}

# ------------------------------------------------------------------- lock
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "$SCRIPT_NAME: a previous cycle is still running, aborting."
    echo "Check pending jobs: midclt call core.get_jobs"
    exit 0
fi

# ------------------------------------------------------------------- helpers
# Fetch the full inventory; fail loudly rather than returning an empty set.
query_all() {
    local out
    if ! out=$(midclt call app.query 2>>"$LOGFILE"); then
        return 1
    fi
    if ! printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
        return 1
    fi
    printf '%s' "$out"
}

field_of() { # $1 = json, $2 = app name, $3 = field
    printf '%s' "$1" | jq -r --arg a "$2" --arg f "$3" \
        '(.[] | select(.name == $a) | .[$f]) // "?"'
}

# Filter candidates. Runs in the current shell (never in a subshell) so that
# log/NOTIF remain effective. Fills SELECTED.
SELECTED=()
filter_apps() {
    SELECTED=()
    local app reason excluded
    for app in "$@"; do
        reason=""
        for excluded in ${EXCLUDE[@]+"${EXCLUDE[@]}"}; do
            [ "$app" = "$excluded" ] && reason="manually excluded"
        done
        if [ -z "$reason" ] && [ "$SKIP_STOPPED" = true ] &&
            [ "${STATE_BEFORE[$app]:-}" = "STOPPED" ]; then
            reason="application is stopped"
        fi
        if [ -n "$reason" ]; then
            log INFO "$app skipped ($reason)"
        else
            SELECTED+=("$app")
        fi
    done
}

budget_exhausted() {
    if [ "$SECONDS" -ge "$GLOBAL_BUDGET" ]; then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------- inventory
log INFO "=== Cycle started ===${CONFIG:+ (config: $CONFIG)}${DRY_RUN:+}"
[ "$DRY_RUN" = true ] && log INFO "Dry run — no changes will be made"

if [ "$DRY_RUN" = true ]; then
    log INFO "Skipping catalog.sync in dry-run mode"
elif midclt call --job catalog.sync >/dev/null 2>>"$LOGFILE"; then
    log INFO "Catalogs synchronised"
else
    log WARN "catalog.sync failed — update detection may be stale"
fi

if ! BEFORE=$(query_all); then
    log ERROR "app.query failed — middleware unreachable, cycle aborted"
    emit_summary
    exit 0
fi

declare -A STATE_BEFORE VER_BEFORE
while IFS=$'\t' read -r name state ver; do
    STATE_BEFORE["$name"]=$state
    VER_BEFORE["$name"]=$ver
done < <(printf '%s' "$BEFORE" |
    jq -r '.[] | [.name, .state, (.human_version // .version // "?")] | @tsv')

TOUCHED=()

# ------------------------------------------------------------------- phase 1
mapfile -t CANDIDATES < <(printf '%s' "$BEFORE" |
    jq -r '.[] | select(.upgrade_available == true) | .name')

filter_apps ${CANDIDATES[@]+"${CANDIDATES[@]}"}
APPS=(${SELECTED[@]+"${SELECTED[@]}"})

log INFO "Phase 1 — ${#STATE_BEFORE[@]} apps in inventory, ${#CANDIDATES[@]} candidates, ${#APPS[@]} selected"

UPGRADED=()
for app in ${APPS[@]+"${APPS[@]}"}; do
    if budget_exhausted; then
        log ERROR "Budget of ${GLOBAL_BUDGET}s exhausted — $app and the rest deferred"
        break
    fi
    before=${VER_BEFORE[$app]:-?}

    if [ "$DRY_RUN" = true ]; then
        log WARN "$app would be upgraded from $before to latest"
        continue
    fi

    log INFO "Upgrading $app (current version $before)"
    timeout "$UPGRADE_TIMEOUT" \
        midclt call --job app.upgrade "$app" \
        "{\"app_version\":\"latest\",\"snapshot_hostpaths\":$SNAPSHOT_HOSTPATHS}" \
        >/dev/null 2>>"$LOGFILE"
    rc=$?

    if [ "$rc" -eq 0 ]; then
        UPGRADED+=("$app")
        TOUCHED+=("$app")
    elif [ "$rc" -eq 124 ]; then
        log ERROR "$app — timed out after ${UPGRADE_TIMEOUT}s; the middleware job may still be running"
    else
        log ERROR "$app — upgrade failed (exit $rc), still on $before"
    fi
done

# ------------------------------------------------------------------- phase 2
# Apps whose catalog version is current but whose upstream image has moved
# (typically "latest" tags). Apps handled in phase 1 already pulled their
# images along the way, so they are skipped here.
if [ "$PULL_IMAGES" = true ]; then
    declare -A ALREADY_DONE=()
    for app in ${UPGRADED[@]+"${UPGRADED[@]}"}; do
        ALREADY_DONE["$app"]=1
    done

    mapfile -t ALL_IMG < <(printf '%s' "$BEFORE" |
        jq -r '.[] | select(.image_updates_available == true) | .name')

    IMG_CANDIDATES=()
    for app in ${ALL_IMG[@]+"${ALL_IMG[@]}"}; do
        [ -n "${ALREADY_DONE[$app]:-}" ] || IMG_CANDIDATES+=("$app")
    done

    filter_apps ${IMG_CANDIDATES[@]+"${IMG_CANDIDATES[@]}"}
    IMGS=(${SELECTED[@]+"${SELECTED[@]}"})

    log INFO "Phase 2 — ${#IMG_CANDIDATES[@]} image candidates, ${#IMGS[@]} selected"

    for app in ${IMGS[@]+"${IMGS[@]}"}; do
        if budget_exhausted; then
            log ERROR "Budget exhausted — image refresh for $app deferred"
            break
        fi

        images=$(midclt call app.outdated_docker_images "$app" 2>>"$LOGFILE" |
            jq -r 'join(", ")' 2>/dev/null) || images=""

        if [ "$DRY_RUN" = true ]; then
            log WARN "$app would have its images refreshed${images:+ ($images)}"
            continue
        fi

        log INFO "Refreshing images for $app${images:+ : $images}"
        timeout "$UPGRADE_TIMEOUT" \
            midclt call --job app.pull_images "$app" '{"redeploy": true}' \
            >/dev/null 2>>"$LOGFILE"
        rc=$?

        if [ "$rc" -eq 0 ]; then
            TOUCHED+=("$app")
            log WARN "$app — images refreshed${images:+ ($images)}, redeployed"
        elif [ "$rc" -eq 124 ]; then
            log ERROR "$app — timed out while pulling images"
        else
            log ERROR "$app — image refresh failed (exit $rc)"
        fi
    done
fi

# ------------------------------------------------------------------- dry run stops here
if [ "$DRY_RUN" = true ]; then
    log INFO "=== Dry run finished (${SECONDS}s) ==="
    emit_summary
    exit 0
fi

# ------------------------------------------------------------------- settle
if [ "${#TOUCHED[@]}" -gt 0 ]; then
    log INFO "Waiting for containers to settle (max ${SETTLE_TIMEOUT}s)"
    deadline=$((SECONDS + SETTLE_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        AFTER=$(query_all) || break
        pending=0
        for app in "${TOUCHED[@]}"; do
            [ "$(field_of "$AFTER" "$app" state)" = "DEPLOYING" ] && pending=1
        done
        [ "$pending" -eq 0 ] && break
        sleep "$SETTLE_INTERVAL"
    done
fi

if ! AFTER=$(query_all); then
    log ERROR "app.query failed after the updates — final state cannot be verified"
    emit_summary
    exit 0
fi

# ------------------------------------------------------------------- versions
if [ "${#UPGRADED[@]}" -gt 0 ]; then
    for app in "${UPGRADED[@]}"; do
        after_ver=$(field_of "$AFTER" "$app" human_version)
        if [ "$after_ver" = "${VER_BEFORE[$app]:-?}" ]; then
            log WARN "$app — job succeeded but the version did not change (${after_ver})"
        else
            log WARN "$app upgraded: ${VER_BEFORE[$app]:-?} -> ${after_ver}"
        fi
    done
fi

# ------------------------------------------------------------------- regressions
while IFS=$'\t' read -r name state; do
    before=${STATE_BEFORE[$name]:-ABSENT}
    if [ "$state" = "CRASHED" ]; then
        log ERROR "$name is CRASHED (was $before)"
    elif [ "$before" = "RUNNING" ] && [ "$state" != "RUNNING" ]; then
        log ERROR "$name is no longer running: RUNNING -> $state"
    fi
done < <(printf '%s' "$AFTER" | jq -r '.[] | [.name, .state] | @tsv')

log INFO "=== Cycle finished (${SECONDS}s) ==="
emit_summary
exit 0
