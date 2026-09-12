# truenas-app-updates

Automated application updates for **TrueNAS SCALE 24.10+** (Docker apps), driven
by `midclt` and triggered from a cron job.

The script is designed to be **quiet when nothing happens**: it writes to stdout
only when an application changed or something went wrong. Since the TrueNAS cron
job emails you only when there is output, a week with no changes produces no
message at all.

---

## ⚠️ Warning — read before installing

**This script updates production applications without human supervision. That
is not a trivial thing to do.**

Automating updates means accepting that an upstream change lands on your system
without anyone reviewing it first. The following outcomes have all been observed
on real TrueNAS installations:

- **Application data loss or corruption.** A major update can migrate a database
  schema irreversibly, or start from an empty configuration if the migration
  fails partway through.
- **Broken configuration.** A new version may rename, move, or drop options; the
  app then restarts with defaults.
- **Extended outage.** An app that refuses to restart stays down until you
  intervene — potentially for days.
- **Cascading failures.** One app going down can take others with it: DNS,
  reverse proxy, shared database, central authentication.
- **Unpredictable version jumps in phase 2.** Images tagged `latest` announce no
  version number. You can cross a major release and its breaking changes with no
  warning whatsoever.
- **Incomplete rollback.** `app.rollback` restores the application version, **not
  the data** the new version has already migrated.

### What this script does not do

It **does not back anything up**. It is not a substitute for ZFS snapshots,
offsite backups, or reading release notes. It assumes you already have a proven
backup strategy — **and that you have actually tested a restore**.

### Responsibility

This repository is published as-is, shared between administrators. Anyone who
installs it:

- runs it **entirely at their own risk**;
- is responsible for **reading and understanding it before** running it;
- is responsible for **their own backup and restore strategy**;
- is responsible for **handling the side effects** on their own system.

The author provides **no warranty**, offers **no support**, and **accepts no
liability** for any direct or indirect damage — data loss, service outage, or
otherwise — arising from the use of this script. See [License](#license).

**If you cannot afford to lose an application's data, do not automate it.** Put
it in `EXCLUDE` and handle it by hand.

---

## How it works

Each cycle runs in two distinct phases.

**Phase 1 — `app.upgrade`.** Applications for which the TrueNAS catalog reports
a newer version (`upgrade_available`) are upgraded to `latest`. Versions before
and after are logged.

**Phase 2 — `app.pull_images`.** Applications whose upstream Docker image has
changed without a catalog version bump (`image_updates_available`, typically
`latest` tags) get their images pulled and the app redeployed. Apps already
handled in phase 1 are skipped, since upgrading pulled their images anyway. Set
`PULL_IMAGES=false` to disable this phase.

Afterwards the script waits for the affected containers to settle, then compares
the state of **every** application against the snapshot taken at the start of the
cycle. An app that was running before and is not running after is reported as an
error.

### Log levels

| Level   | Contents | Emailed |
|---------|----------|---------|
| `INFO`  | Normal progress, skipped apps and why, catalog sync | no |
| `WARN`  | An application was upgraded or redeployed | yes |
| `ERROR` | Failure, timeout, state regression, middleware unreachable | yes |

Everything is written to the log file and to journald regardless of level. Only
`WARN` and `ERROR` reach stdout, and therefore the email.

---

## Repository layout

```
truenas-app-updates.sh            the script — never edit it
truenas-app-updates.conf.example  copy this, adjust, keep your copy out of git
README.md
LICENSE
```

---

## Requirements

- TrueNAS SCALE **24.10 (Electric Eel) or later** — apps must be running on
  Docker. Kubernetes-era versions (24.04 and earlier) used `chart.release.*` and
  are **not compatible**.
- `midclt`, `jq`, `flock`, `timeout`, `logger` — all present by default.
- `root` access (the `app.*` methods require the `APPS_WRITE` role).

Confirm your version exposes the methods used here:

```bash
midclt call core.get_methods | jq -r 'keys[] | select(startswith("app."))'
```

`app.query`, `app.upgrade`, `app.pull_images`, `app.outdated_docker_images`,
`app.rollback` and `app.rollback_versions` should all be listed.

---

## Installation

Put the script on a **data pool**, never on the boot pool: boot environments are
replaced on every system update and the script would disappear.

```bash
mkdir -p /mnt/YOUR_POOL/scripts
cd /mnt/YOUR_POOL/scripts
curl -fsSL -o truenas-app-updates.sh \
  https://raw.githubusercontent.com/michelwils/truenas-app-updates/main/truenas-app-updates.sh
chmod +x truenas-app-updates.sh
```

The executable bit matters: the TrueNAS cron job invokes the file directly, and
without an executable shebang it would run under `sh`, where associative arrays
fail.

Then create your configuration file — **do not edit the script itself**, so that
pulling a newer version stays a clean fast-forward:

```bash
curl -fsSL -o truenas-app-updates.conf \
  https://raw.githubusercontent.com/michelwils/truenas-app-updates/main/truenas-app-updates.conf.example
chmod 644 truenas-app-updates.conf
```

At minimum, set `LOGFILE` to a path on a data pool. Everything else has a
working default.

---

## Configuration

**The script is not meant to be edited.** Its defaults are overridden from two
places, in increasing order of precedence:

1. **built-in defaults** — the settings block at the top of the script;
2. **a configuration file** — plain shell assignments, sourced at startup;
3. **environment variables** — set on the command line or in the cron job.

The configuration file is looked up in this order, first match wins:

```
$TNAU_CONFIG                                  (environment variable)
<script directory>/truenas-app-updates.conf
/etc/truenas-app-updates.conf
```

Or pass one explicitly: `truenas-app-updates.sh --config /path/to/file`.

Since the file is sourced by a root shell, the script refuses to run if it is
group- or world-writable. `chmod 644` is what you want.

### Environment overrides

Any setting can be overridden per-invocation, which is convenient for a cron
job you would rather not pair with a file:

```bash
PULL_IMAGES=false LOGFILE=/mnt/tank/scripts/logs/app-updates.log \
  /mnt/tank/scripts/truenas-app-updates.sh
```

`EXCLUDE` is a bash array and cannot travel through the environment. Use
`EXCLUDE_LIST`, a space-separated string, which replaces it entirely:

```bash
EXCLUDE_LIST="stalwart nextcloud" /mnt/tank/scripts/truenas-app-updates.sh
```

### Settings

| Variable | Default | Purpose |
|---|---|---|
| `LOGFILE` | `/var/log/truenas-app-updates.log` | Path to the detailed log. Set this to a data pool — `/var/log` lives on the boot pool and is lost on system updates. |
| `LOCKFILE` | `/var/run/truenas-app-updates.lock` | Lock preventing two overlapping cycles. |
| `TAG` | `truenas-app-updates` | Identifier used for journald entries. |
| `UPGRADE_TIMEOUT` | `1800` | Maximum seconds **per application**. |
| `SETTLE_TIMEOUT` | `240` | Maximum wait for containers to settle before judging final state. |
| `GLOBAL_BUDGET` | `14400` | Maximum total cycle duration. Remaining apps are deferred to the next run. |
| `SNAPSHOT_HOSTPATHS` | `false` | ZFS snapshot of host paths before each upgrade. Set to `true` if you do not already have periodic snapshots covering your app datasets. |
| `SKIP_STOPPED` | `true` | Leave apps in `STOPPED` state alone — they are probably stopped on purpose. |
| `PULL_IMAGES` | `true` | Enables phase 2. Set to `false` to handle catalog versions only. |
| `EXCLUDE` | `()` | Apps never to touch, e.g. `EXCLUDE=(stalwart nextcloud)`. File only. |
| `EXCLUDE_LIST` | `""` | Same list as a space-separated string, usable from the environment. Replaces `EXCLUDE` when set. |
| `SEND_EMAIL` | `true` | Send the summary through the middleware's `mail.send`. See below. |
| `EMAIL_TO` | `""` | Space-separated recipients. Empty means the local administrators. |

### How the summary reaches you

TrueNAS ships no local mail transfer agent. Cron can only deliver a job's
output by invoking `sendmail`, so **unchecking *Hide Standard Output* is not
enough on its own** — the output has nowhere to go and is discarded silently.
Configured SMTP settings and a working test email do not change this; the
middleware sends its own notifications through its API, not through cron.

With `SEND_EMAIL=true` (the default), the script therefore sends its summary
itself, via the `mail.send` API method, using the same SMTP settings as every
other TrueNAS notification. Nothing is written to stdout under cron, so a
system that *does* have an MTA will not produce a duplicate. When you run the
script from a terminal, the summary is printed as well.

Set `SEND_EMAIL=false` if you have installed an MTA and would rather let cron
handle delivery. If `mail.send` fails, the script falls back to stdout and logs
an error.

### Command-line options

```
-c, --config FILE   Configuration file to source.
-n, --dry-run       Report what would be updated, change nothing.
-h, --help          Show usage.
```

### About `SNAPSHOT_HOSTPATHS`

When `true`, `app.upgrade` snapshots host path volumes before each update. It is
a useful safety net, but **those snapshots are never pruned automatically** —
they pile up every cycle. If you enable it, set up a retention task.

When `false`, make sure your periodic snapshot tasks actually cover the app
configuration dataset — the one TrueNAS creates under the applications pool,
separate from your data datasets. It is easy to have excluded it without
noticing when the task targets datasets by name rather than the pool
recursively. Schedule the cycle **after** your daily snapshots, with a 15–30
minute margin.

---

## Cron job

In the UI: **System → Advanced → Cron Jobs → Add**.

| Field | Value |
|---|---|
| Description | Application updates |
| Command | `/mnt/YOUR_POOL/scripts/truenas-app-updates.sh` — prefix with `VAR=value ` to override settings here rather than in a file |
| Run As User | `root` |
| Schedule | e.g. `0 4 * * 0` (Sunday 4 a.m.) |
| Hide Standard Output | **unchecked** — this is the channel carrying the summary |
| Hide Standard Error | **checked** — already redirected to the log |

Weekly is a reasonable compromise: often enough not to accumulate changes,
spaced enough that you can identify the culprit when something breaks.

---

## First run

**Do not wire up the cron job right away.** Start with a dry run, which reports
what would be updated and changes nothing:

```bash
/mnt/YOUR_POOL/scripts/truenas-app-updates.sh --dry-run
```

Then a real run with phase 2 disabled, to validate catalog upgrades on their own:

```bash
PULL_IMAGES=false /mnt/YOUR_POOL/scripts/truenas-app-updates.sh
```

What you see on screen is exactly what you would have received by email. Then
check the detailed log, confirm version numbers render correctly, enable phase 2,
and only then set up the cron job.

If versions show as `?`, your API does not expose the `human_version` field —
harmless beyond the display. Check with:

```bash
midclt call app.query | jq -r '.[0] | keys'
```

---

## Logs and troubleshooting

```bash
# detailed script log
tail -f /mnt/YOUR_POOL/scripts/logs/app-updates.log

# via journald
journalctl -t truenas-app-updates --since today
journalctl -t truenas-app-updates -p warning     # WARN and ERROR only

# middleware jobs, running or recent
midclt call core.get_jobs | jq -r '.[] | select(.method | startswith("app.")) | "\(.id) \(.method) \(.state)"'
```

The log rotates past 5 MB; the previous cycle is kept as `app-updates.log.1`.

---

## Rolling back

```bash
# versions you can roll back to
midclt call app.rollback_versions APP_NAME

# roll back
midclt call --job app.rollback APP_NAME '{"app_version": "1.2.3"}'
```

Remember: this restores the **application version**, not its data. If the new
version migrated a database, rolling back can leave an old application in front
of new data — often worse than the original problem. Restoring a ZFS snapshot is
the better path in that case.

---

## Known limitations

- Updates are **sequential**. On a large deployment with big images a cycle can
  run long; that is what `GLOBAL_BUDGET` is for.
- Settling only waits for the `DEPLOYING` state to clear. An app crash-looping
  may be observed as `RUNNING` at check time and slip through.
- No application-level health check: the script verifies the container is
  running, not that the service actually responds.
- `mail.send` is queued by the middleware. A failure to actually deliver
  (bad credentials, SMTP server down) will not be visible to the script; check
  the TrueNAS alerts.
- A failed `catalog.sync` produces a `WARN`, hence an email. If your link is
  flaky at cycle time this gets noisy — downgrade that case to `INFO`.
- `--dry-run` skips `catalog.sync`, so it reports against whatever the catalog
  last knew. An app with a pending update may not show up until a real run has
  refreshed the catalog.
- `--dry-run` also skips every job call it is reporting on, so it cannot
  surface a failure in `app.upgrade` or `app.pull_images` themselves. A clean
  dry run says the selection logic works, not that the updates will.

---

## Transparency: use of generative AI

This project was written with the assistance of generative AI (Anthropic's
Claude). The AI produced the initial implementation and the bulk of this
documentation, working from requirements, review comments, and TrueNAS API
output supplied by the author.

The author reviewed the result, and remains responsible for it. That said,
anyone considering running this script should weigh what AI assistance means in
practice here:

- The TrueNAS middleware methods used (`app.query`, `app.upgrade`,
  `app.pull_images`, `app.outdated_docker_images`) were verified against the
  published API reference and against a live installation, not assumed from
  training data.
- Several defects were found and fixed during review — among them a silent
  failure mode where an unreachable middleware looked like "nothing to update",
  and a jq expression whose substring matching could skip the wrong
  application. Others may well remain.
- The script has been exercised on a single TrueNAS installation. It carries no
  automated test suite.

Read it before you run it. That advice would hold for any script you found on
the internet; it holds here too.

---

## License

Released under the MIT License. Its warranty disclaimer is an integral part of
the terms of use:

> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
> CLAIM, DAMAGES OR OTHER LIABILITY.

See the [LICENSE](LICENSE) file.
