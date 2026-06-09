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
- Cron: watch the scheduled task fire (every second) with

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
    shift                                        # drop the command word; "$@" = operator flags
    local crontab="${SUPERCRONIC_CRONTAB:-/etc/supercronic/crontab}"
    local -a default_opts=()                     # baked-in defaults (array: space-safe)
    run_entrypoint_scripts                       # reuse a public core-library routine
    local cron_user="worker"
    setup_user "$cron_user" 1500 "$cron_user" 1500   # provision a dedicated user
    log_notice "starting supercronic cron runner ($crontab) as $cron_user"
    exec_as_user "$cron_user" "$cron_user" \
        supercronic "${default_opts[@]}" "$@" "$crontab"   # drop root -> worker, then exec
}
```

Starting the container with `command: ["supercronic"]` (see
[`docker-compose.yml`](docker-compose.yml)) makes the dispatcher call
`handle_supercronic`. It reuses the base library's public functions
(`run_entrypoint_scripts`, `exec_as_user`, `log_notice`) and **execs** the cron
runner, which then becomes the container's main process.

The hook is written as a reusable template rather than a one-off. Because the
dispatcher invokes `handle_<cmd> "$@"` with the full argv, `$1` is always the
command word: `shift` it off and `"$@"` holds exactly the flags the operator
appended. So `command: ["supercronic", "-debug", "-split-logs"]` (or
`docker run IMG supercronic -debug`) forwards those flags straight to the
runner. Defaults live in a `default_opts` array (space-safe, and operator flags
that follow can override them), the crontab path is an env-overridable
`SUPERCRONIC_CRONTAB`, and the positional crontab stays last where supercronic
expects it — patterns that carry over to any companion command.

The contract the hook follows (enforced by the entrypoint):

- The file only **defines** `handle_*` functions — no top-level side effects (it
  is sourced as root before any privilege drop).
- The handler **execs** the final process; returning or exiting is a fatal
  contract violation.
- It does not shadow the core library's function names or the
  `UNIT_*` / `ENTRYPOINT_*` / `APPLICATION_*` variables.

## A dedicated user for the cron role

Rather than reuse the base `unit` user, the hook provisions its own `worker`
user (uid/gid 1500) with the public `setup_user` routine and drops to it — so the
cron jobs run under their own least-privilege identity. Two details worth noting:

- **A new name is required for a custom uid.** `setup_user` keeps the existing
  id of a user that already exists, and the base `unit` user is created by the
  core package's postinst with a system-range UID. So passing `1500` to a
  re-provisioned `unit` would be ignored (and logged). Using a fresh name
  (`worker`) is what makes the custom uid take effect.
- **The uid/gid must be free.** `setup_user` dies with an actionable message if
  `1500` is already taken — pick another free id or pre-create the user.

`worker` is created with no app directory and is not granted write access to
anything; the demo task only reads `/www` (root-owned, world-readable) and prints
its identity. `cron-task.php` prints `uid=…(…) gid=…(…)`, so the logs show the
jobs running as `uid=1500(worker)`, not as `unit`.

## What it shows

- [`Dockerfile`](Dockerfile) — `FROM` the published base, install a pinned +
  SHA256-verified `supercronic`, `COPY` the shared app to `/www/`, the web
  config to `/docker-entrypoint.d/`, the crontab to `/etc/supercronic/`, and the
  one hook file to `/docker-entrypoint-hook.d/`.
- [`docker-compose.yml`](docker-compose.yml) — two services, one image: `web`
  uses the default command; `cron` overrides it with `supercronic`. Both run
  under the same hardening (`cap_drop: [ALL]`, `cap_add: [SETUID, SETGID]`,
  `no-new-privileges`) — even the cron role keeps `SETUID`/`SETGID` because it
  drops to the `worker` user itself via `setpriv` (`exec_as_user`), just as the
  Unit master does for its workers.
- The cron role never starts Unit: the hook execs `supercronic` before the
  entrypoint reaches its first-run/`unitd` path, so `config.json` is simply
  unused there. Because nothing listens on the control socket, the cron service
  also **disables the image `HEALTHCHECK`** (which probes that socket) — otherwise
  the container would report unhealthy forever.

## Verify

```bash
docker compose up --build -d
curl -s http://localhost:8080/ | grep 'web role'           # web role serves
sleep 3                                                     # the crontab fires every second
docker compose logs cron | grep 'uid=1500(worker)'         # cron runs as worker, not unit
docker compose down -v
```

## Why a hook instead of a second image

You could maintain a separate cron image, but it would either duplicate the base
entrypoint (and drift from its fixes) or override it (and lose them). The hook
keeps `/docker-entrypoint.sh` authoritative: add one small file declaring a new
launch mode, and the base image's hardening — bounded daemon waits, validated
pidfile handling, privilege drop, hook vetting — applies to your companion
service for free.
