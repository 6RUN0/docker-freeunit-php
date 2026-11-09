# Example: one image, two roles (the entrypoint hook system)

This example shows **why the entrypoint hook system exists**. A single image
built on the `freeunit-php` base runs in two roles, chosen per container by the
command:

- **web** — the default `freeunitd` command: the Unit web server serving a PHP app.
- **cron** — the `supercronic` command: a long-lived cron runner executing a PHP
  task on a schedule.

Both come from the **same image and the same entrypoint**. The only thing that
differs is the command, which the base entrypoint turns into a different launch
mode. No second Dockerfile, and crucially no overriding `/docker-entrypoint.sh`,
so every robustness and security fix in the base entrypoint reaches both roles.

## Run

```bash
docker compose up --build        # from this directory
```

- Web: open <http://localhost:8080/>.
- Cron: watch the scheduled task fire (every second) with

  ```bash
  docker compose logs -f cron
  ```

## How the hook works

The base image ships a thin dispatcher (`/docker-entrypoint.sh`) that, before
its default `freeunitd` path, sources every `*.sh` in `/docker-entrypoint-hook.d/`
and looks for a shell function `handle_<command>` matching the container's
command. If one exists, that function owns the launch.

This example adds exactly one such file,
[`supercronic-hook.sh`](supercronic-hook.sh), copied to
`/docker-entrypoint-hook.d/supercronic.sh`:

```sh
handle_supercronic() {
    shift                                        # drop the command word; "$@" = operator flags
    supercronic_crontab=${SUPERCRONIC_CRONTAB:-/etc/supercronic/crontab}  # prefixed: no `local`
    # set -- -passthrough-logs "$@"              # baked-in defaults, in front of operator flags
    run_entrypoint_scripts                       # reuse a public core-library routine
    log_notice "starting supercronic cron runner ($supercronic_crontab) as uid $(id -u)"
    exec supercronic "$@" "$supercronic_crontab" # already non-root: just exec
}
```

Starting the container with `command: ["supercronic"]` (see
[`docker-compose.yml`](docker-compose.yml)) makes the dispatcher call
`handle_supercronic`. It reuses the base library's public functions
(`run_entrypoint_scripts`, `log_notice`) and **execs** the cron runner, which
then becomes the container's main process.

The hook is written as a reusable template rather than a one-off. Because the
dispatcher invokes `handle_<cmd> "$@"` with the full argv, `$1` is always the
command word: `shift` it off and `"$@"` holds exactly the flags the operator
appended. So `command: ["supercronic", "-debug", "-split-logs"]` (or
`docker run IMG supercronic -debug`) forwards those flags straight to the
runner. Defaults go in front of them with `set -- -flag "$@"` (the positional
parameters are the one space-safe list of POSIX sh, and operator flags that
follow can override them), the crontab path is an env-overridable
`SUPERCRONIC_CRONTAB`, and the positional crontab stays last where supercronic
expects it — patterns that carry over to any companion command.

The contract the hook follows (enforced by the entrypoint):

- The file is **POSIX sh** (the entrypoint is `/bin/sh`, dash) and only
  **defines** `handle_*` functions - no top-level side effects (it is sourced
  into the entrypoint shell before the launch).
- Every variable it sets carries its own prefix (`supercronic_`): there is no
  `local`, and `UNIT_*`, `ENTRYPOINT_*`, `_ep_*` belong to the entrypoint.
- The handler **execs** the final process; returning or exiting is a fatal
  contract violation.
- It does not shadow the core library's function names or the
  `UNIT_*` / `ENTRYPOINT_*` variables.

## The cron role's user

The entrypoint already runs as the non-root image user `nonroot` (65532), so the
hook does no privilege drop: the cron jobs run as that user. The demo task only
reads `/www` (root-owned, world-readable) and prints its identity:
`cron-task.php` prints `uid=...(...) gid=...(...)`, so the logs show the jobs
running as `uid=65532(nonroot)`. A different uid for the cron role is a
different `user:` in compose, with its own writable mounts.

## What it shows

- [`Dockerfile`](Dockerfile) — `FROM` the published base, install a pinned +
  SHA256-verified `supercronic`, `COPY` the shared app to `/www/`, the web
  config to `/docker-entrypoint.d/`, the crontab to `/etc/supercronic/`, and the
  one hook file to `/docker-entrypoint-hook.d/`.
- [`docker-compose.yml`](docker-compose.yml) — two services, one image: `web`
  uses the default command; `cron` overrides it with `supercronic`. Both run
  under the same hardening (`cap_drop: [ALL]`, `no-new-privileges`, no
  `cap_add`).
- The base image runs as 65532: the `Dockerfile` switches to `USER 0:0` to
  install `supercronic` and back to `USER 65532:65532` at the end.
- The cron role never starts Unit: the hook execs `supercronic` before the
  entrypoint reaches its first-run/`freeunitd` path, so `config.json` is simply
  unused there. Because nothing listens on the control socket, the cron service
  also **disables the image `HEALTHCHECK`** (which probes that socket) — otherwise
  the container would report unhealthy forever.

## Verify

```bash
docker compose up --build -d
curl -s http://localhost:8080/ | grep 'web role'           # web role serves
sleep 3                                                     # the crontab fires every second
docker compose logs cron | grep 'uid=65532(nonroot)'       # cron runs as the non-root image user
docker compose down -v
```

## Why a hook instead of a second image

You could maintain a separate cron image, but it would either duplicate the base
entrypoint (and drift from its fixes) or override it (and lose them). The hook
keeps `/docker-entrypoint.sh` authoritative: add one small file declaring a new
launch mode, and the base image's hardening — bounded daemon waits, validated
pidfile handling, the root guard, hook vetting - applies to your companion
service for free.
