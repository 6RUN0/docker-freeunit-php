# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Tooling

`.mcp.json` stays tracked — keep it in git, do not gitignore it. It wires two
local MCP servers — use them:

- **codegraph** — a queryable knowledge graph of the codebase. Consult it
  before editing code (e.g. `codegraph_explore` for "how does X work", callers
  /callees, change impact) instead of grepping and re-reading files by hand.
- **agentmemory** (served via `local_1mcp` with the `agentmemory` tag) — the
  persistent project memory. Recall prior lessons/decisions before starting
  non-trivial work, and save durable findings (review outcomes, gotchas,
  release-bump steps) so they survive across sessions.

## What this repo is

A single parameterized `Dockerfile` that builds Docker images bundling
[FreeUnit](https://github.com/6RUN0/freeunit) (a fork of NGINX Unit) with an
embedded PHP language module on Debian **trixie** (amd64). The whole
php-version / suite / FreeUnit-release matrix is covered by build args — there
is no code generation and no committed per-variant directories.

FreeUnit ships **prebuilt `.deb` packages** (core `unit` + per-version
`unit-phpX.Y` modules) on its GitHub releases page, so the build installs them
directly — it does **not** compile Unit or the PHP module from source.

## Build matrix

The `Makefile` drives the matrix; each target is one `docker build` with
different `--build-arg`s against the same `Dockerfile`:

```bash
make            # all PHP versions (PHP_VERSIONS = 8.3 8.4 8.5)
make php8.3     # one variant
make latest     # build DEFAULT_PHP (8.4) and tag it :latest
docker build -t freeunit-php .                      # defaults: trixie, php8.4
docker build --build-arg PHP_VER=8.3 -t x .         # one-off without make
```

Key build args (defaults in the `Dockerfile`): `PHP_VER` (8.4), `SUITE` (trixie),
`IMAGE_SUFFIX` (-slim), `FREEUNIT_VERSION` (deb version base, e.g. `1.35.5-1`),
`FREEUNIT_RELEASE` (GitHub release tag, e.g. `1.35.5-build4`), and the
`DEBIAN_MIRROR` / `DEBIAN_SECURITY_MIRROR` / `SURY_MIRROR` mirror args (neutral
CDN defaults; sury is fetched over https because its signing key travels that
channel). The `Makefile` reads `SUITE` / `PHP_VER` / `FREEUNIT_VERSION` /
`FREEUNIT_RELEASE` defaults out of the `Dockerfile` ARGs via `sed`, so they are
**single-sourced**: bumping a FreeUnit release = edit `FREEUNIT_VERSION` +
`FREEUNIT_RELEASE` in the `Dockerfile` only (or pass on the command line).

The Makefile's immutable image tag is `$(SUITE)-$(FREEUNIT_RELEASE)-php$*` (the
release is the unique build id), plus the floating `$(SUITE)-php$*`.

## Dockerfile architecture (3 stages)

1. **base_image** — `FROM debian:${SUITE}${IMAGE_SUFFIX}`; rewrites apt sources to
   mirrors, runs `apt full-upgrade`, and adds the deb.sury.org PHP repo. The sury
   source is written in **deb822 format** (`*.sources`) and pinned at priority 1001.
2. **php_image** — installs `libphp${PHP_VER}-embed` (the embed SAPI the FreeUnit
   module needs) plus the project's standard PHP extension set, all from sury.
3. **php_image** also installs the fragile extensions (`imagick`,
   `uploadprogress`) in a **best-effort** loop (`apt-get install … || echo
   WARNING`), so a missing extension on a newer PHP line does not fail the build.
4. **final_image** — downloads `unit_*` and `unit-php${PHP_VER}_*` `.deb`s from the
   FreeUnit GitHub release, verifies `SHA256SUMS` itself against the pinned
   `FREEUNIT_SHA256SUMS_SHA256` trust anchor (see below), then verifies the `.deb`s
   against it (asserting both expected entries are present with `grep -qF`, so
   `--ignore-missing` cannot pass vacuously), and `apt-get install`s the two local
   files (apt pulls
   `libphp${PHP_VER}-embed` already present and the virtual `unit-rX.Y.Z` provided
   by the core package). Then it prepares `/var/lib/unit` + `/docker-entrypoint.d`,
   symlinks `unit.log` to stdout, `COPY rootfs/ /`, sets OCI `LABEL`s, and sets the
   `tini` entrypoint + `unitd --no-daemon`.

`SUITE` and `IMAGE_SUFFIX` are declared **before the first `FROM`** so they reach
the `FROM` line; they are re-declared inside stages that use them in `RUN`.

### Critical packaging detail (asset name vs deb version)

GitHub renames the `~` in deb version strings to `.` in asset file names, so the
**same** package is downloaded as `unit_1.35.5-1.trixie_amd64.deb` but its real
version (and its `SHA256SUMS` entry) is `1.35.5-1~trixie`. The Dockerfile downloads
with `curl -o` into the **`~` name** so `sha256sum -c --ignore-missing` actually
matches the file. Saving under the `.` name would make the checksum check pass
**vacuously** (no matching filename → entry skipped) — a silent integrity hole.
In the `RUN`: `deb_ver=${FREEUNIT_VERSION}~${SUITE}`, `asset_ver=${FREEUNIT_VERSION}.${SUITE}`.

`SHA256SUMS` is fetched from the same release it vouches for, so on its own it
proves nothing — a tampered release could ship a matching `SHA256SUMS`. The
`FREEUNIT_SHA256SUMS_SHA256` ARG breaks that loop: it pins the SHA256 of the
trusted `SHA256SUMS` **in version control**, and the build aborts unless the
fetched file hashes to it. Bumping FreeUnit therefore means recomputing this
digest too — which is exactly what `check-upstream.yml` automates.

The core `unit` package's `postinst` creates the `unit:unit` system user/group,
so the Dockerfile does not create it manually.

## rootfs overlay

`rootfs/` mirrors the container filesystem and is copied wholesale with
`COPY rootfs/ /`. Anything baked into the image (entrypoint scripts, configs)
lives there at its target path:

- `rootfs/docker-entrypoint.sh` — a thin dispatcher. It sources every `*.sh` in
  the **hook dir** (see below), then calls `dispatch_handler` (in the core
  library): if a sourced file defined a shell function `handle_<cmd>` matching
  `$1`, that handler owns the launch (it must `exec`, and a return or a non-zero
  exit is a fatal contract violation);
  otherwise, for `unitd`/`unitd-debug` it runs the standard first-run routine
  (`unit_initial_configuration`) and `exec`s the command. The first-run routine
  only fires when `/var/lib/unit` is empty: it launches unitd against the control
  socket and applies everything in `/docker-entrypoint.d/` (`*.sh` executed,
  `*.pem` uploaded as certificate bundles, `*.json` PUT to `config`), then stops
  unitd so the real start boots a populated state.
- `rootfs/docker-entrypoint-common.sh` — the reusable **core library** sourced by
  the entrypoint (and available to child hooks). Every function takes its target
  as an argument, defaulting to the `UNIT_*` / `ENTRYPOINT_*` constants, so a
  child can retarget it. Groups:
  - logging: `log` (takes a level token) + `log_info`/`log_notice`/`log_warn`;
    `die` logs at err level and exits.
  - control API: `curl_put <file> <endpoint> [socket]`.
  - fs helpers: `dir_has_content <dir>`, `is_first_run [statedir]`.
  - daemon lifecycle: `start_unit <binary> [socket] [pidfile]`,
    `wait_for_control_socket [socket]`, `stop_unit [pidfile] [socket]`;
    `read_pid <pidfile>` yields a single, validated numeric pid (decoupled from
    `read`'s exit status, so a newline-less pidfile still works; non-numeric is
    ignored).
  - `/docker-entrypoint.d` appliers: `run_entrypoint_scripts [dir]` (*.sh, no
    daemon needed), `apply_certificates [dir]` (*.pem; basename validated to
    `[A-Za-z0-9._-]` before it becomes a control-API path segment),
    `apply_config [dir]` (*.json; warns when >1 file, since `PUT /config`
    replaces the whole config so only the last wins) — the last two need a ready
    daemon.
  - command dispatch: `dispatch_handler <cmd> [args…]` runs a hook's
    `handle_<cmd>` (which must `exec`); it `die`s if the handler returns or exits
    non-zero without exec'ing, and is a no-op when no handler matches.
  - privilege drop: `exec_as_user <user> <group> <cmd…>` via `setpriv`
    (`--init-groups --no-new-privs`; gosu/su-exec are intentionally absent).
  - user provisioning: `setup_user <user> <uid> <group> <gid> [dir] [chown]` —
    idempotent; a child hook calls it to create a *different* app user.
  - `unit_initial_configuration <binary>` is the full first-run routine composed
    from the above, guarded by its `unit_config_failed` EXIT trap.
  On source it provisions the default app user from `APPLICATION_USER/UID/GROUP/
  GID/DIR/CHOWN` by calling `setup_user` with them.

`/docker-entrypoint.d` itself is created by the `RUN` (empty dirs are not tracked
in git); users mount or add config snippets into it at runtime.

### Entrypoint extension contract (hook dir)

`/docker-entrypoint-hook.d/` is the **entrypoint extension** dir, created by the
same `RUN` and kept separate from the runtime-config `/docker-entrypoint.d/`. A
downstream image adds a launch mode by `COPY`ing one `*.sh` file there that
defines `handle_<cmd>` — e.g. a `handle_supercronic` that runs
`run_entrypoint_scripts` then `exec`s a cron runner. Child images do **not**
overwrite `/docker-entrypoint.sh`, so every robustness/security fix to the base
entrypoint reaches them automatically.

The entrypoint **sources** each hook into its own shell, so authors must respect
the contract (the entrypoint enforces the first two):

- A hook file must **only define `handle_*` functions** — no top-level side
  effects. Top-level code runs as root before dispatch; a non-zero last command
  aborts startup (the loop reports which hook with `die`).
- A `handle_<cmd>` **must `exec`** the final process. Returning (or exiting
  non-zero) is a fatal contract violation — `dispatch_handler` errors out rather
  than silently re-running the raw command.
- Hooks share scope with the base: do **not** set a bare `trap` (it collides
  with the first-run EXIT trap) and do **not** shadow the core library function
  names (listed above) or the `UNIT_*` / `ENTRYPOINT_*` / `APPLICATION_*`
  variables; prefix private helpers/vars. The hook dir path is a
  build-time constant (not env-overridable), since the loop sources as root.

The two reusable routines above are the public surface handlers build on.

## Verification

- **Build** — the `final_image` stage runs `unitd --version` and `php -v`, so a
  successful build proves the daemon and module load.
- **Smoke test** — `test/smoke.sh <image-ref>` runs the image with the
  `test/fixtures/` PHP app mounted (config into `/docker-entrypoint.d`, code into
  `/www`) and asserts a request is served by PHP — the entrypoint's happy path.
- **Entrypoint-library unit checks** — `test/entrypoint-lib.sh <image-ref>` covers
  the paths of `docker-entrypoint-common.sh` the smoke test cannot reach: a
  non-executable `*.sh` dies actionably; `read_pid`/`stop_unit` handle empty,
  multi-line, newline-less and non-numeric pidfiles; `wait_for_control_socket`
  bounds its wait; `stop_unit` escalates to SIGKILL; `dispatch_handler` enforces
  the hook exec-contract; `exec_as_user` drops privileges; `setup_user` validates
  ids and is idempotent; `dir_has_content` gets the empty/non-empty boundary
  right. It is a pytest-style shell suite (auto-discovered `test_*` functions,
  `assert_*` helpers, per-test process isolation) that re-execs itself inside the
  image so the real library is sourced as shipped. The host-side CLI parser and
  image build it shares with `test/smoke.sh` live in `test/lib.sh`. `make test`
  builds the default variant and runs both; `make test-entrypoint` runs only this
  suite against an already-built image.
- **CI** — `.github/workflows/ci.yml` runs lint (hadolint, shellcheck, typos,
  plus actionlint + zizmor for the workflows and rumdl for the markdown), the
  build+test matrix (8.3/8.4/8.5, via `make test` so smoke + entrypoint checks
  run on every PHP line) on Buildx with a per-PHP `type=gha` layer cache, and a
  report-only trivy scan on the 8.4 leg.
- **Release** — `.github/workflows/release.yml` (on a `v*` tag) builds + tests
  the matrix (`make test`, so both suites run), pushes the images to GHCR, and
  records keyless (OIDC)
  build-provenance + SPDX-SBOM attestations against each image digest (pushed to
  GHCR as OCI referrers; verify with `gh attestation verify`).
- `make lint` (hadolint, shellcheck, rumdl, typos) and `make scan` (trivy/grype,
  best-effort) are available locally — note actionlint/zizmor run in CI only.

## Automation

- `.github/workflows/check-upstream.yml` — weekly cron (+ `workflow_dispatch`)
  that watches `6RUN0/freeunit` for a newer release and opens a `chore/freeunit-*`
  bump PR: it patches `FREEUNIT_VERSION` / `FREEUNIT_RELEASE` and **recomputes the
  `FREEUNIT_SHA256SUMS_SHA256` trust anchor**, refusing to bump unless every
  matrixed PHP line (`PHP_LINES`) has a module `.deb` in the new `SHA256SUMS`. The
  PR is opened with `GITHUB_TOKEN`, whose events do not trigger other workflows, so
  CI does **not** run on it automatically — close/reopen the PR (or push an empty
  commit) to kick the build + checksum-verify matrix.
- `.github/dependabot.yml` — weekly grouped bumps for the SHA-pinned GitHub
  Actions only (the docker manager can't parse the ARG-interpolated `FROM`, and
  the FreeUnit `.deb` bump is `check-upstream.yml`'s job).

## Gotchas

- FreeUnit only ships prebuilt modules for php **8.3/8.4/8.5** (and python3.13);
  there is nothing to install for older PHP lines.
- PHP **8.5** extensions on sury may lag; `imagick`/`uploadprogress` are installed
  best-effort (skipped with a warning if absent), so the build stays green. Other
  extensions are in the mandatory list — if one of those is missing on 8.5, trim
  it in `php_image`.
- The PHP extension list lives only in the `Dockerfile`'s `php_image` stage.
- `.dockerignore` is an allowlist (`*` then `!rootfs/`) — only `rootfs/` enters
  the build context.
- The entrypoint uses bash globs (`shopt -s nullglob globstar`) over
  `/docker-entrypoint.d`, not `for f in $(find …)`; it passes `--pid` explicitly
  and wipes `/var/lib/unit` if first-run config fails (retry on next start).
