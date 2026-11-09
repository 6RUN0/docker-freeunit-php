# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Tooling

`.mcp.json` is local and untracked (`.gitignore` is an allowlist). It wires
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

FreeUnit ships **prebuilt `.deb` packages** (core `freeunit` + per-version
`freeunit-phpX.Y` modules) on its GitHub releases page, so the build installs them
directly — it does **not** compile Unit or the PHP module from source.

Upstream rebranded its packages and on-disk identity from `unit*` to `freeunit*`
(daemon `freeunitd`, `/var/lib/freeunit`, `control.freeunit.sock`, the
`freeunit:freeunit` user/group). Because this image only *installs* the prebuilt
`.deb`s, that identity is fixed by the artifact, not chosen here — see the brand
ARGs and the build-time guard below.

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
`IMAGE_SUFFIX` (-slim), `FREEUNIT_VERSION` (deb version base, e.g. `1.35.6-1`),
`FREEUNIT_RELEASE` (GitHub release tag, e.g. `1.35.6-build2`), and the
`DEBIAN_MIRROR` / `DEBIAN_SECURITY_MIRROR` / `SURY_MIRROR` mirror args (neutral
CDN defaults; sury is fetched over https because its signing key travels that
channel). The `Makefile` reads `SUITE` / `PHP_VER` / `FREEUNIT_VERSION` /
`FREEUNIT_RELEASE` defaults out of the `Dockerfile` ARGs via `sed`, so they are
**single-sourced**: bumping a FreeUnit release = edit `FREEUNIT_VERSION` +
`FREEUNIT_RELEASE` in the `Dockerfile` only (or pass on the command line).

A second ARG group single-sources the **brand identity**, mirroring the upstream
packaging vocabulary (`freeunit/pkg/deb/Makefile`): `BRAND` (dpkg/apt asset and
package names we download), `RUNTIME` (the on-disk identity compiled into the
package — binary `${RUNTIME}d`, `/var/lib/${RUNTIME}`, `control.${RUNTIME}.sock`,
`/var/log/${RUNTIME}.log`, the `${RUNTIME}:${RUNTIME}` user/group), `RUNDIR` (the
socket + pid dir), plus `BRAND_TITLE` / `HOMEPAGE` / `DOCS_URL` for the OCI labels.
All default to `freeunit` / `/var/run`. These are **not** free knobs (the prebuilt
`.deb`s carry one fixed identity); they document intent and are asserted against
the installed binary at build time (see below).

The Makefile tags `$(SUITE)-$(FREEUNIT_RELEASE)-php$*` and the floating
`$(SUITE)-php$*` locally; neither is immutable. The published immutable tags
carry the image version and exist only in `release.yml`:
`$(SUITE)-$(FREEUNIT_RELEASE)-v<version>-php<X.Y>`, `<version>-php<X.Y>` and the
bare `<version>` (see Verification - Release). Up to v0.3.0 the FreeUnit tag had
no version (`trixie-1.37.2-2-php*` stays the root-based 0.3.0 image).

## Dockerfile architecture (3 stages)

1. **base_image** — `FROM debian:${SUITE}${IMAGE_SUFFIX}`; rewrites apt sources to
   mirrors, runs `apt full-upgrade`, and adds the deb.sury.org PHP repo. The sury
   source is written in **deb822 format** (`*.sources`) and pinned at priority 990
   (below 1000, so a compromised sury mirror cannot force-downgrade a Debian
   package).
2. **php_image** — installs `libphp${PHP_VER}-embed` (the embed SAPI the FreeUnit
   module needs) plus the project's standard PHP extension set, all from sury.
3. **php_image** also installs the fragile extensions (`imagick`,
   `uploadprogress`) in a **best-effort** loop (`apt-get install … || echo
   WARNING`), so a missing extension on a newer PHP line does not fail the build.
4. **final_image** — downloads `${BRAND}_*` and `${BRAND}-php${PHP_VER}_*` `.deb`s
   from the FreeUnit GitHub release, verifies `SHA256SUMS` itself against the pinned
   `FREEUNIT_SHA256SUMS_SHA256` trust anchor (see below), then verifies the `.deb`s
   against it (asserting both expected entries are present with `grep -qF`, so
   `--ignore-missing` cannot pass vacuously), and `apt-get install`s the two local
   files (apt pulls
   `libphp${PHP_VER}-embed` already present and the virtual `${RUNTIME}-rX.Y.Z`
   provided by the core package). Then it creates the image user `nonroot`
   (`NONROOT_UID`/`NONROOT_GID`, 65532, home `/home/nonroot` 0755, empty), hands `/run`
   to it, prepares `/docker-entrypoint.d`, symlinks `/var/log/${RUNTIME}.log` to
   stdout, **asserts
   the installed `${RUNTIME}d`'s compiled paths (`--statedir`/`--control`/`--pid`/
   `--log`/`--user`/`--group` from its `--version` configure line) match
   `RUNTIME`/`RUNDIR`** — so a future upstream identity change fails the build
   instead of shipping an image whose entrypoint manages the wrong paths — then
   `COPY rootfs/ /`, asserts the `nonroot` passwd entry equals the library
   literals `UNIT_NONROOT_UID/GID/HOME`, sets OCI `LABEL`s, and ends with
   `USER ${NONROOT_UID}:${NONROOT_GID}`. There is **no `CMD`**: the default launch
   (`${RUNTIME}d --no-daemon --control …`) lives in the entrypoint and the
   `HEALTHCHECK` is a script (`/docker-healthcheck.sh`), so the binary name and
   socket path stay single-sourced from `docker-entrypoint-common.sh` rather than
   duplicated in an exec-form instruction (which cannot expand a build ARG/ENV).
   `tini` is the entrypoint wrapper. The `php_image` stage writes
   `90-nonroot-session.ini` for `cli` and `embed` (`session.save_path = /tmp`;
   the default `/var/lib/php/sessions` is root-owned). All other PHP temp paths
   stay at their `/tmp` defaults: `/tmp` is the writable temp dir at run time.

`SUITE` and `IMAGE_SUFFIX` are declared **before the first `FROM`** so they reach
the `FROM` line; they are re-declared inside stages that use them in `RUN`.

### Critical packaging detail (asset name vs deb version)

GitHub renames the `~` in deb version strings to `.` in asset file names, so a
package is always downloaded as `freeunit_<ver>.trixie_amd64.deb`. Its
`SHA256SUMS` entry has one of two forms: `freeunit_<ver>~trixie_amd64.deb`
(releases up to `1.37.1`) or `freeunit_<ver>.trixie_amd64.deb` (from
`1.37.2-2`). The Dockerfile looks up which form `SHA256SUMS` lists and saves the
file under **that exact name** with `curl -o`, so `sha256sum -c --ignore-missing`
actually matches it. If the name differs, the entry is skipped and the check
passes **vacuously**, which is a silent integrity hole. A package missing from
`SHA256SUMS` in both forms fails the build. In the `RUN`:
`deb_ver=${FREEUNIT_VERSION}~${SUITE}`, `asset_ver=${FREEUNIT_VERSION}.${SUITE}`.
`check-upstream.yml` parses both forms too.

`SHA256SUMS` is fetched from the same release it vouches for, so on its own it
proves nothing — a tampered release could ship a matching `SHA256SUMS`. The
`FREEUNIT_SHA256SUMS_SHA256` ARG breaks that loop: it pins the SHA256 of the
trusted `SHA256SUMS` **in version control**, and the build aborts unless the
fetched file hashes to it. Bumping FreeUnit therefore means recomputing this
digest too — which is exactly what `check-upstream.yml` automates.

The core `freeunit` package's `postinst` creates the `freeunit:freeunit` system
user/group; it stays unused, as does the compiled statedir `/var/lib/freeunit`:
the whole daemon runs as the image user.

## rootfs overlay

`rootfs/` mirrors the container filesystem and is copied wholesale with
`COPY rootfs/ /`. Anything baked into the image (entrypoint scripts, configs)
lives there at its target path. Every script that runs in the image (the three
below, `test/entrypoint-lib-cases.sh`, the example hooks) is portable POSIX sh
(`#!/bin/sh`, dash in the image): no `local`, `[[ ]]`, arrays, `declare`,
`pipefail`, `${var//}`, `$'..'`, `<<<`, `((..))`, `BASH_*`, no GNU-only options.
Library functions name their variables `_ep_<function>_*` instead of `local`.
`make lint` runs `shellcheck` (dialect from the shebang) and `dash -n` /
`busybox sh -n` where installed; CI runs both.

- `rootfs/docker-entrypoint.sh` — a thin dispatcher. It sources every `*.sh` in
  the **hook dir** (see below), then calls `dispatch_handler` (in the core
  library): if a sourced file defined a shell function `handle_<cmd>` matching
  `$1`, that handler owns the launch (it must `exec`, and a return or a non-zero
  exit is a fatal contract violation);
  otherwise, for `freeunitd`/`freeunitd-debug` it completes the command line
  with the missing `--no-daemon --control --pid --statedir --tmpdir`
  (`build_unit_launch_args`; a conflicting path dies), runs the standard
  first-run routine (`unit_initial_configuration`) and `exec`s the command;
  with `--version`/`--help`/`-h` it execs the command as given. (When invoked with no
  command at all, the dispatcher first supplies the default launch -
  `${UNIT_BINARY} --no-daemon` - so the image needs no `CMD`.) Before the hooks
  are sourced it calls `drop_root_or_die "$0" "$@"` and `prepare_runtime_dirs`.
  The first-run routine only fires when the state dir `/run/freeunit` is empty
  (every start with a tmpfs at `/run`): it launches freeunitd against the control
  socket, runs the `*.sh` of `/docker-entrypoint.d/`, uploads the `*.pem` and
  PUTs the `*.json` of `/docker-entrypoint.d/` and then of the generated dir
  `/run/docker-entrypoint.d` (certificates of both before any config), then stops
  freeunitd so the real start boots a populated state.
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
  - root guard: `drop_root_or_die <entrypoint> [args...]` - uid 0 hands stdio
    to 65532 (`chown_stdio_to_nonroot`) and re-execs via `setpriv --reuid
    --regid --clear-groups --no-new-privs` with `HOME=/home/nonroot`; without
    CAP_SETUID/CAP_SETGID/CAP_CHOWN/CAP_KILL (`has_effective_cap`, CapEff) it
    dies; group 0 at a non-zero uid dies. tini stays root in that mode and needs
    CAP_KILL to forward `docker stop`; the healthcheck run as root probes via
    `setpriv` as the owner of the socket (`stat -c %u:%g`; no CAP_DAC_OVERRIDE
    needed). gosu/su-exec are
    intentionally absent.
  - `prepare_runtime_dirs` - creates the state and generated dirs and dies with
    a mount hint unless `/var/run`, both dirs and `/tmp` are writable
    (writability, not a uid: any non-root uid works). `HOME` is not checked: it
    may be read-only.
  - `build_unit_launch_args <binary> [args...]` - fills the global array
    `UNIT_LAUNCH_ARGS`.
  - `unit_initial_configuration <binary>` is the full first-run routine composed
    from the above, guarded by its `unit_config_failed` EXIT trap (wipes the
    state and generated dirs).
  Sourcing the library has no side effects (the healthcheck sources it for
  `UNIT_CONTROL_SOCKET`). The path constants are readonly literals -
  deliberately not env-derived - so the state-dir wipe target and control paths
  cannot be redirected at runtime: `UNIT_STATE_DIR=/run/freeunit`,
  `UNIT_TMP_DIR=/tmp`, `ENTRYPOINT_GENERATED_DIR=/run/docker-entrypoint.d`
  (exported for the scripts), `UNIT_NONROOT_UID/GID/HOME`; socket and pid stay
  under `UNIT_RUNDIR` (`/var/run`, a symlink to `/run`).

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

The entrypoint **sources** (`.`) each hook into its own POSIX sh, as the
container user after the root guard, so authors must respect the contract (the
entrypoint enforces the exec rule and the file ownership):

- A hook file is **POSIX sh** (it is parsed by dash; bash syntax is a syntax
  error at start) and must **only define `handle_<cmd>` functions**, `<cmd>`
  made of `[A-Za-z0-9_]` - no top-level side effects. Top-level code runs before
  dispatch; a non-zero last command aborts startup (the loop reports which hook
  with `die`).
- Handler lookup is `has_handler`: `command -v handle_<cmd>` must print exactly
  `handle_<cmd>` (a function; an executable of that name in `PATH` prints a
  path and does not count). A command word with other characters (`-`, `/`,
  `.`) never selects a handler. The handler is called as `handle_<cmd> "$@"`
  (command word first) on the left of `||`, so `set -e` is off inside it.
- POSIX sh has no `local`: every variable a hook sets carries its own prefix
  (`<cmd>_`, e.g. `supercronic_crontab`); `UNIT_*`, `ENTRYPOINT_*` and `_ep_*`
  belong to the entrypoint. The positional parameters are the one per-call,
  space-safe list (`set -- -flag "$@"` for default flags).
- A `handle_<cmd>` **must `exec`** the final process. Returning (or exiting
  non-zero) is a fatal contract violation — `dispatch_handler` errors out rather
  than silently re-running the raw command.
- Hooks share scope with the base: do **not** set a bare `trap` (it collides
  with the first-run EXIT trap) and do **not** redefine the core library
  functions (listed above); prefix private helper functions too. The hook dir
  path is a build-time constant (not env-overridable), and each hook file must
  be root-owned and not
  group/world-writable (`assert_safe_root_file`), so the unprivileged process
  cannot rewrite it. The library has no `setup_user`/`exec_as_user`; a hook
  calling them dies with "command not found".

The two reusable routines above are the public surface handlers build on.

## Verification

- **Build** — the `final_image` stage runs `freeunitd --version` (also asserting
  its compiled paths match `RUNTIME`/`RUNDIR`) and `php -v`, so a successful build
  proves the daemon and module load and the image's paths match the binary.
- **Smoke test** — `test/smoke.sh <image-ref>` runs the image with the
  `test/fixtures/` PHP app mounted (config into `/docker-entrypoint.d`, code into
  `/www`) and asserts a request is served by PHP in each launch mode: hardened
  (`--read-only --cap-drop=ALL`, tmpfs mounts; also a 1 MiB upload into `/tmp`,
  every process uid 65532, no EROFS/EPERM/EACCES in the logs), plain,
  `--user 0:0` (drop, also under `-t`; /dev/stderr reopenable from a shell and
  from a `*.sh`; with exactly SETUID/SETGID/CHOWN/KILL a healthy probe as root
  and a clean `docker stop`; refusal without CAP_CHOWN, without CAP_KILL, with
  group 0 or `--group-add 0`), an arbitrary uid, and an explicit `freeunitd`
  command (flags added; a conflicting `--statedir` dies).
- **Entrypoint-library unit checks** - `test/entrypoint-lib.sh <image-ref>` (a
  bash host driver) runs `test/entrypoint-lib-cases.sh` (POSIX sh) in the image
  under `/bin/sh` (dash), as the image user. Tests that need another literal
  (a short tick budget, a temp path) source a `sed`-patched copy of the
  library: pre-binding a `readonly` variable aborts dash at the library's own
  `readonly`. It covers the paths of `docker-entrypoint-common.sh` the smoke
  test cannot reach: a
  non-executable `*.sh` dies actionably; `read_pid`/`stop_unit` handle empty,
  multi-line, newline-less and non-numeric pidfiles; `wait_for_control_socket`
  bounds its wait; `stop_unit` escalates to SIGKILL; `dispatch_handler` enforces
  the hook exec-contract; `prepare_runtime_dirs` dies with a hint on a
  non-writable dir and accepts a read-only `HOME`; `build_unit_launch_args`
  completes and refuses;
  `unit_initial_configuration` applies the generated dir last and runs no
  `*.sh` from it and a failure wipes state and generated dirs; the appliers keep
  byte order, recursion, names with spaces and skip hidden entries;
  `has_handler` finds only functions; the `nonroot` literals match passwd;
  `/bin/sh` is dash; `session.save_path` is
  `/tmp`; `assert_safe_root_file` accepts an image file and refuses a
  process-owned one; `dir_has_content` gets the empty/non-empty boundary right.
  The suite runs as the image user. It is a pytest-style shell suite (auto-discovered `test_*` functions,
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
  the matrix (`make test`, so both suites run), refuses to run if any immutable
  tag of the leg already exists, pushes the floating tags, records keyless (OIDC)
  build-provenance + SPDX-SBOM attestations against that digest (pushed to GHCR
  as OCI referrers; verify with `gh attestation verify`), and creates the
  immutable tags last from the same digest (`imagetools create
  --prefer-index=false`; without the flag buildx wraps the manifest in a new
  index with another digest). A leg that failed after some immutable tags were
  created is finished by hand (comment on that step).
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
- Both bots open their PRs against `develop` (`target-branch` /
  `BUMP_BASE`). Dependabot reads its config only from the default branch
  (`main`), so a change to `dependabot.yml` takes effect once it reaches `main`;
  security updates ignore `target-branch` and still target `main`.

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
- The appliers list `/docker-entrypoint.d` with `find` (recursive, hidden
  entries pruned, `LC_ALL=C sort`) and read the list from fd 4 (a
  here-document), so the loop runs in the current shell (a `die` ends the
  entrypoint) and scripts keep the container's stdin; a newline in a file name
  is not supported. Never redirect stdio around `chown_stdio_to_nonroot`: under
  dash a `2>/dev/null` on its `chown` chowned /dev/null instead of stderr. The
  entrypoint passes `--pid`,
  `--statedir` and `--tmpdir` explicitly and wipes `/run/freeunit` (and the
  generated dir) if first-run config fails (retry on next start).
- `/var/lib/freeunit` is **not** the statedir: it is the compiled default, left
  root-owned by the package; the build asserts `--statedir=/var/lib/freeunit` in
  the configure line only to detect an upstream identity change.
- The image starts as `65532:65532`. A derived image needs `USER 0:0` before
  `RUN apt-get` and `USER 65532:65532` at the end; `COPY` files are root-owned
  whatever the USER.
- `test/examples.sh` retags `EXAMPLES_BASE_IMAGE` as
  `ghcr.io/6run0/freeunit-php:trixie-php8.4` and rebuilds the `freeunit-ex-*` /
  `freeunit-php-cron-example` images, overwriting local tags of those names.
