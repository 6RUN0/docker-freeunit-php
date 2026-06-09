# Example: one image, two roles (the entrypoint hook system)

This example shows **why the entrypoint hook system exists**. A single image
built on the `freeunit-php` base runs in two roles, chosen per container by the
command:

- **web** — the default `unitd` command: the Unit web server serving a PHP app.
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
- Cron: watch the scheduled task fire (about once a minute) with

  ```bash
  docker compose logs -f cron
  ```

## How the hook works

The base image ships a thin dispatcher (`/docker-entrypoint.sh`) that, before
its default `unitd` path, sources every `*.sh` in `/docker-entrypoint-hook.d/`
and looks for a shell function `handle_<command>` matching the container's
command. If one exists, that function owns the launch.

This example adds exactly one such file,
[`supercronic-hook.sh`](supercronic-hook.sh), copied to
`/docker-entrypoint-hook.d/supercronic.sh`:

```bash
handle_supercronic() {
    local crontab=/etc/supercronic/crontab
    run_entrypoint_scripts                       # reuse a public core-library routine
    log_notice "starting supercronic cron runner ($crontab)"
    exec_as_user "$APPLICATION_USER" "$APPLICATION_GROUP" \
        supercronic "$crontab"                   # drop root -> app user, then exec
}
```

Starting the container with `command: ["supercronic"]` (see
[`docker-compose.yml`](docker-compose.yml)) makes the dispatcher call
`handle_supercronic`. It reuses the base library's public functions
(`run_entrypoint_scripts`, `exec_as_user`, `log_notice`) and **execs** the cron
runner, which then becomes the container's main process.

The contract the hook follows (enforced by the entrypoint):

- The file only **defines** `handle_*` functions — no top-level side effects (it
  is sourced as root before any privilege drop).
- The handler **execs** the final process; returning or exiting is a fatal
  contract violation.
- It does not shadow the core library's function names or the
  `UNIT_*` / `ENTRYPOINT_*` / `APPLICATION_*` variables.

## What it shows

- [`Dockerfile`](Dockerfile) — `FROM` the published base, install a pinned +
  SHA256-verified `supercronic`, `COPY` the shared app to `/www/`, the web
  config to `/docker-entrypoint.d/`, the crontab to `/etc/supercronic/`, and the
  one hook file to `/docker-entrypoint-hook.d/`.
- [`docker-compose.yml`](docker-compose.yml) — two services, one image: `web`
  uses the default command; `cron` overrides it with `supercronic`. Both run
  under the same hardening (`cap_drop: [ALL]`, `cap_add: [SETUID, SETGID]`,
  `no-new-privileges`) — even the cron role keeps `SETUID`/`SETGID` because it
  drops to the app user itself via `setpriv` (`exec_as_user`), just as the Unit
  master does for its workers.
- The cron role never starts Unit: the hook execs `supercronic` before the
  entrypoint reaches its first-run/`unitd` path, so `config.json` is simply
  unused there.

## Why a hook instead of a second image

You could maintain a separate cron image, but it would either duplicate the base
entrypoint (and drift from its fixes) or override it (and lose them). The hook
keeps `/docker-entrypoint.sh` authoritative: add one small file declaring a new
launch mode, and the base image's hardening — bounded daemon waits, validated
pidfile handling, privilege drop, hook vetting — applies to your companion
service for free.
