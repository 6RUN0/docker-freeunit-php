# Examples

Each subdirectory is a self-contained example built on the `freeunit-php` base
image. Pick one, `cd` into it, and `docker compose up --build`.

## Read in this order

Each example adds roughly one new idea on top of the previous, from the minimal
on-ramp to the densest:

1. [`basic/`](basic/) — **bake + harden.** A small `Dockerfile` bakes an app and
   its Unit config onto the base image, run with the recommended capability
   hardening. The minimal self-contained deployment. Start here.
2. [`dev/`](dev/) — **iterate without rebuilding.** Bind-mount the code so host
   edits are live, choose the PHP line with a build arg, and use the entrypoint
   env knobs (`UNIT_ENTRYPOINT_QUIET_LOGS`, `APPLICATION_DIR`/`CHOWN`).
3. [`routing/`](routing/) — **multiple apps and routing.** One image serves two
   PHP apps behind URI routing with a static-file `share`/`fallback`, plus per-app
   PHP config (`options.admin`/`user`/`file`) and the `environment` block.
4. [`web-app/`](web-app/) — **HTTPS via the applicator chain.** The entrypoint's
   `*.sh` → `*.pem` → `*.json` order, used to generate a cert, upload it as a TLS
   bundle, and declare a TLS listener — plus an HTTP→HTTPS redirect.
5. [`cron-hook/`](cron-hook/) — **a second launch mode.** The entrypoint hook
   system runs one image in two roles (Unit web server and a `supercronic` cron
   runner), and provisions a dedicated `worker` user for the cron role.

## Capability → example matrix

| Capability | Example |
| --- | --- |
| Bake app + config onto the base image | `basic` |
| Capability hardening (`cap_drop`/`no-new-privileges`) | all |
| App worker privilege drop (`user`/`group` in config) | `basic`, all |
| Bind-mounted code (live edits) | `dev` |
| PHP line selection via build arg | `dev` |
| `UNIT_ENTRYPOINT_QUIET_LOGS` | `dev` |
| `APPLICATION_DIR` + `APPLICATION_CHOWN` (writable volume) | `dev` |
| URI routing (`match` + `pass`) | `routing` |
| Static `share` with `fallback` to a front controller | `routing` |
| Multiple PHP applications in one image | `routing` |
| `options.admin` / `options.user` | `routing` |
| Per-app `options.file` (custom `php.ini`) | `routing` |
| `environment` block | `routing` |
| Loaded extension set (apcu/redis/gd/intl/mbstring) | `routing` |
| Applicator chain `*.sh` → `*.pem` → `*.json` | `web-app` |
| First-run `*.sh` applicator | `web-app` |
| `*.pem` applicator (`apply_certificates`) | `web-app` |
| TLS listener | `web-app` |
| `return` + `location` (HTTP→HTTPS redirect) | `web-app` |
| Entrypoint hook (`handle_<cmd>`, second launch mode) | `cron-hook` |
| Operator flag forwarding into a hook | `cron-hook` |
| `setup_user` (provision a new user from a hook) | `cron-hook` |
| `exec_as_user` (privilege drop in a hook) | `cron-hook` |

## Deliberately not covered

To keep the examples teachable rather than exhaustive, a few behaviors are left
out on purpose (each is documented in the base [README](../README.md) /
[`CLAUDE.md`](../CLAUDE.md)):

- the `apply_config` warning when more than one `*.json` is present (each example
  ships exactly one config);
- multiple certificate bundles and the `*.pem` basename validation (`web-app`
  uploads a single bundle);
- the `unitd-debug` launch command;
- the `SUPERCRONIC_CRONTAB` env override beyond the single flag-forwarding path
  shown in `cron-hook`.
