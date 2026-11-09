# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions here track the **packaging** (this repo), not the bundled software; each
release records the FreeUnit and PHP versions it ships.

## [Unreleased]

The image runs without root. Migration for a derived image or a deployment is
the numbered list below; the floating `trixie-php*` and `latest` tags point at
the non-root image from this release on.

### Removed

- (2) The `APPLICATION_USER/UID/GROUP/GID/DIR/CHOWN` variables: they are
  ignored, the entrypoint creates no user and changes no ownership at start.
  Bake the ownership of writable paths into the image (named volumes copy the
  mount point owner) or own the host dir by the process uid.
- (3) The library functions `setup_user` and `exec_as_user`, and
  `UNIT_LIB_NO_PROVISION`: a hook that calls them fails at start with "command
  not found". A hook runs as the container user already; it just `exec`s.
- The immutable tag without a version: `trixie-1.37.2-2-php*` stays the
  root-based 0.3.0 image.
- (12) bash in the entrypoint: `docker-entrypoint.sh`, the library and the
  healthcheck are portable POSIX sh (`/bin/sh`, dash in the image). A hook in
  `/docker-entrypoint-hook.d` is sourced by it, so a bash hook (`local`,
  `[[ ]]`, arrays, `declare -F`) stops working: rewrite it in POSIX sh,
  prefix its variables with `<cmd>_` (no `local`) and keep only `handle_<cmd>`
  functions, `<cmd>` of `[A-Za-z0-9_]`. The handler is looked up with
  `command -v`.

### Changed

- (1) The image starts as `nonroot` (uid:gid `65532:65532`, home
  `/home/nonroot`): tini, the entrypoint, the Unit master and the PHP workers
  run as that user and need no capability (`--cap-drop=ALL`, no `cap_add`). A
  derived `Dockerfile` needs `USER 0:0` before `RUN apt-get` and
  `USER 65532:65532` at the end. Any other non-root uid:gid works when its
  mounts are writable for it.
- (4) Do not set `applications.*.user` / `group` in the Unit config: an
  unprivileged Unit runs its workers as its own user (it logs a warning that it
  cannot use arbitrary user and group).
- (5) The Unit state dir is `/run/freeunit` (was the compiled
  `/var/lib/freeunit`); with a tmpfs at `/run` the configuration from
  `/docker-entrypoint.d` is applied on every container start. An explicit
  `freeunitd ...` / `freeunitd-debug ...` command gets the missing `--no-daemon`,
  `--control`, `--pid`, `--statedir` and `--tmpdir` flags; one of the last four
  with another value (e.g. `--statedir /var/lib/freeunit`) stops the start with
  an error. `--version` / `--help` / `-h` run as given, without initial
  configuration.
- (6) Unit buffers request bodies in `/tmp` (`--tmpdir /tmp`), where PHP keeps
  its uploads and temp files by default; `session.save_path` is `/tmp` for `cli`
  and `embed` (was the root-owned `/var/lib/php/sessions`). `/tmp` must be
  writable for the process uid; under `read_only` mount a host dir there
  (recommended) or a tmpfs with a `size`.
- (7) Every writable path is a mount the process uid can write: `/run` (tmpfs),
  `/tmp`, and the application's own bind mounts. The entrypoint checks
  `/var/run`, the state dir and `/tmp` before anything else and stops with a hint
  naming the missing mount. `HOME` (`/home/nonroot`, empty, 0755) may stay
  read-only; an application that writes there mounts it.
- (8) A listener below port 1024 needs `net.ipv4.ip_unprivileged_port_start=0`
  (the Docker default since Engine 20.10).
- (9) Started as root (`--user 0:0`): the entrypoint hands stdio to 65532 and
  re-execs itself as `65532:65532` with no supplementary groups and
  `no_new_privs`, logging a warning; tini (PID 1) stays root in that mode.
  It needs the default capabilities or at least
  `CAP_SETUID`/`CAP_SETGID`/`CAP_CHOWN`/`CAP_KILL`; without them the start stops
  with an error, as does a non-root uid with group 0. The healthcheck, run as
  root then, probes as the owner of the control socket.
- (10) The control socket, the state dir and the generated dir belong to the
  same uid as the PHP workers: code execution in PHP can reconfigure Unit until
  the container restarts. The unix socket rules out SSRF, not RCE.
- (11) The immutable tags carry the image version:
  `trixie-<freeunit-release>-v<version>-php<X.Y>` (e.g.
  `trixie-1.37.2-2-v0.4.0-php8.4`), `<version>-php<X.Y>` and `<version>`. The
  release workflow refuses to run when one of them exists and creates them
  last, from the attested digest, after the floating tags.
- The hook files in `/docker-entrypoint-hook.d` are sourced as the container
  user; they must still be root-owned and not group/world-writable.
- Examples: no `user`/`group` in the Unit configs, no `cap_add`; `dev` creates
  `/data` owned by 65532 in its `Dockerfile` instead of `APPLICATION_CHOWN`;
  `cron-hook` execs supercronic without a privilege drop; `web-app` renders its
  TLS bundle into `$ENTRYPOINT_GENERATED_DIR`.

### Added

- `ENTRYPOINT_GENERATED_DIR` (`/run/docker-entrypoint.d`, exported to the
  `/docker-entrypoint.d/*.sh` scripts): the `*.pem` and `*.json` a script renders
  there are applied after those of `/docker-entrypoint.d` (certificates of both
  dirs before any config, the generated config last); `*.sh` there are not
  executed.
- Library functions `drop_root_or_die`, `prepare_runtime_dirs`,
  `build_unit_launch_args` and the literals `UNIT_TMP_DIR`,
  `UNIT_NONROOT_UID/GID/HOME`.
- `test/smoke.sh` runs every launch mode: hardened (`--read-only
  --cap-drop=ALL`), plain, root drop (also under `-t`) and its refusals, an
  arbitrary uid, an explicit `freeunitd` command.

## [0.3.0] - 2026-11-09

### Changed

- Bumped the bundled FreeUnit to `1.37.2-2` (up from `1.37.1-1`) and recomputed
  the `FREEUNIT_SHA256SUMS_SHA256` trust anchor.
- From `1.37.2-2` upstream lists packages in `SHA256SUMS` as
  `<ver>.<suite>` instead of `<ver>~<suite>`. The build and the bump bot accept
  both forms, so a `FREEUNIT_RELEASE` override to an older release still builds;
  a package missing from `SHA256SUMS` in both forms fails the build.

## [0.2.0] - 2026-11-02

### Changed

- Bumped the bundled FreeUnit to `1.37.1` (`1.37.1-1`, up from `1.36.0-1`) and
  recomputed the `FREEUNIT_SHA256SUMS_SHA256` trust anchor. Upstream dropped the
  `-buildN` suffix from its release tags, so the immutable image tag of this
  release is `trixie-1.37.1-php<X.Y>`.
- `examples/cron-hook`: supercronic `v0.2.51` (up from `v0.2.46`).
- The FreeUnit bump bot (`check-upstream.yml`) no longer opens a PR when the
  release marked Latest upstream ships an older `.deb` version than the pinned
  one; an equal version (a rebuild under a new tag) is still bumped.

## [0.1.0] - 2026-07-17

### Changed

- Bumped the bundled FreeUnit to `1.36.0-build1` (`1.36.0-1`, up from `1.35.6-1`)
  and recomputed the `FREEUNIT_SHA256SUMS_SHA256` trust anchor. Unlike the last
  few refreshes, this is a real upstream version bump — the bundled FreeUnit
  moves from 1.35.6 to 1.36.0, not a rebuild of the same package.

## [0.0.9] - 2026-07-16

### Changed

- Bumped the bundled FreeUnit `.deb` release to `1.35.6-build5` and recomputed the
  `FREEUNIT_SHA256SUMS_SHA256` trust anchor. Upstream re-published the same
  `1.35.6-1` package under a new release tag, so the bundled FreeUnit and PHP
  versions are unchanged — this is a rebuild-only refresh.

## [0.0.8] - 2026-07-10

### Added

- `.trivyignore` listing the HIGH/CRITICAL CVEs in the Debian trixie base and the
  sury PHP / image-codec stack that have no upstream fix (none are in FreeUnit's
  own `.deb` packages, and none are resolvable by the `apt full-upgrade` the build
  already runs), so `make scan` and the CI scan surface only new, actionable
  findings instead of a permanent unfixable backlog.

### Changed

- Bumped the bundled FreeUnit `.deb` release to `1.35.6-build4` and recomputed the
  `FREEUNIT_SHA256SUMS_SHA256` trust anchor. Upstream re-published the same
  `1.35.6-1` package under a new release tag, so the bundled FreeUnit and PHP
  versions are unchanged — this is a rebuild-only refresh.

## [0.0.7] - 2026-06-28

### Changed

- Bumped the bundled FreeUnit `.deb` release to `1.35.6-build3` and recomputed the
  `FREEUNIT_SHA256SUMS_SHA256` trust anchor. Upstream re-published the same
  `1.35.6-1` package under a new release tag, so the bundled FreeUnit and PHP
  versions are unchanged — this is a rebuild-only refresh.

## [0.0.6] - 2026-06-17

### Changed

- **FreeUnit rebrand (breaking for downstream images).** Upstream renamed its
  Debian packages and on-disk identity from `unit*` to `freeunit*`, and the image
  follows suit: the daemon is `freeunitd`/`freeunitd-debug`, the state dir
  `/var/lib/freeunit`, the control socket `/var/run/control.freeunit.sock`, the log
  `/var/log/freeunit.log`, and the default application user/group `freeunit` (was
  `unit`). Downstream images must move any `config.json` `user`/`group` keys and
  any custom launch command from `unit`/`unitd` to `freeunit`/`freeunitd`; the
  reusable entrypoint library keeps its function names and `UNIT_*`/`APPLICATION_*`
  variable identifiers, so hooks that only call the documented API are unaffected.
- Bumped the bundled FreeUnit `.deb` release to `1.35.6-build2` (`1.35.6-1`) and
  recomputed the `FREEUNIT_SHA256SUMS_SHA256` trust anchor.
- The brand identity is single-sourced as Dockerfile `ARG`s mirroring the upstream
  packaging vocabulary (`BRAND`, `RUNTIME`, `RUNDIR`, `BRAND_TITLE`, `HOMEPAGE`,
  `DOCS_URL`). They default to `freeunit`/`/var/run` and the build now **asserts the
  installed binary's compiled paths match `RUNTIME`/`RUNDIR`**, so a future upstream
  identity change fails the build instead of shipping an image whose entrypoint
  manages paths the daemon does not use.
- The default launch command moved out of the Dockerfile `CMD` into the entrypoint,
  and the `HEALTHCHECK` is now a script (`/docker-healthcheck.sh`), so the binary
  name and control-socket path stay single-sourced from `docker-entrypoint-common.sh`
  instead of being duplicated in an exec-form instruction that cannot expand a
  build ARG.

## [0.0.5] - 2026-06-09

### Added

- `examples/` grew into a capability-coverage set: `dev` (a live-mounted
  development loop writing to a persistent state volume as the unprivileged app
  user), `routing` (multiple apps behind path routes, static-asset serving, and a
  per-app PHP `memory_limit`), and `web-app` (HTTPS from an entrypoint-generated
  self-signed certificate, with an HTTP-to-HTTPS redirect), alongside the existing
  `basic` and `cron-hook`. Each example is a self-contained subdirectory with its
  own README.
- `make test-examples`: an examples gate that statically lints every example's
  compose file for the capability-hardening block (`cap_drop`, `no-new-privileges`,
  `SETUID`, `SETGID`), then builds, runs, and asserts each example end to end
  against the just-built image.
- `make help`: a self-documenting target list parsed from the `##`-prefixed
  comment annotations on the targets themselves.

### Changed

- The `cron-hook` example fires its task every second using supercronic's
  seven-field (seconds) crontab syntax, so the example and its test no longer wait
  out a full minute for a tick.
- CI asserts the PHP build matrix is in sync across `ci.yml`, `release.yml`,
  `security-scan.yml`, and `check-upstream.yml`'s completeness gate against the
  Makefile's `PHP_VERSIONS`, failing the lint job on any drift.
- `release.yml` guards each Dockerfile-ARG extraction, failing loudly rather than
  pushing a malformed tag if an ARG line format ever drifts.
- Repository hygiene: added `.gitattributes`, tightened `.editorconfig`, and
  ignored the `docs/superpowers/` working notes.

### Fixed

- Documentation: corrected the deb.sury.org pin priority described in `CLAUDE.md`
  (990, not 1001 — below 1000 so a compromised mirror cannot force a downgrade) and
  the stale crontab field-count comments in the examples test, aligning the docs
  with the shipped `Dockerfile` and crontab.

## [0.0.4] - 2026-06-09

### Added

- Extensible entrypoint hook system: a child image adds a launch mode by dropping
  a `handle_<command>` hook into `/docker-entrypoint-hook.d/` (sourced and
  ownership-vetted as root before any privilege drop), and the entrypoint became a
  thin dispatcher over a reusable core library (`docker-entrypoint-common.sh`) of
  logging, daemon lifecycle, config appliers, privilege drop, and user
  provisioning. Downstream images inherit every base robustness/security fix
  without overwriting `/docker-entrypoint.sh`.
- `examples/cron-hook/`: an example of the hook system — one image runs in two
  roles, the Unit web server and a long-lived `supercronic` cron runner, selected
  per container by the command (`supercronic` is pinned and SHA256-verified).
- `test/entrypoint-lib.sh` gained checks for the hook dispatch contract
  (`dispatch_handler`), the `exec_as_user` privilege drop, `setup_user` id
  validation and idempotency, the `dir_has_content` empty/non-empty boundary, and
  newline-less / non-numeric pidfiles. The host-side CLI parser and image build
  shared by both test drivers were extracted into `test/lib.sh`.

### Changed

- `apply_config` now warns when more than one `*.json` is present in
  `/docker-entrypoint.d`, since `PUT /config` replaces the whole configuration and
  only the lexically-last file survives.
- `wait_for_control_socket` bounds each probe with `curl --max-time`, and
  `run_entrypoint_scripts` now reports which user script failed.
- `examples/` reorganised so each example is a self-contained subdirectory
  (`examples/basic/`, `examples/cron-hook/`) with an index `README.md`.
- CI pins ShellCheck to the version used locally — the runner's bundled one
  flagged false positives on the library's optional-argument and
  trap/dispatch-invoked functions — and now lints each example's `README.md`.

### Fixed

- A child-hook `handle_<cmd>` that exits non-zero no longer aborts the entrypoint
  silently under `set -e` before its diagnostic. Dispatch moved into
  `dispatch_handler`, which reports both a non-zero exit and a return-without-exec
  with an actionable message.
- `stop_unit` no longer skips `kill -TERM` when the pidfile has no trailing
  newline (`read` returns non-zero at EOF even after assigning the value). The new
  `read_pid` helper decouples the value from `read`'s exit status and ignores a
  non-numeric pid, so a corrupt pidfile cannot become a broad kill.
- `dir_has_content` treats an existing-but-unreadable directory as an error rather
  than "empty", so a transient `EACCES` on the state dir cannot trigger a
  re-initialisation over a populated state.

### Security

- `exec_as_user` now passes `setpriv --no-new-privs`, so a child-image hook's
  privilege drop is irreversible inside the image even if the operator omits
  `--security-opt=no-new-privileges`.
- The first-run failure wipe (`find … -delete`) gained `-xdev`, so it stops at
  filesystem boundaries and never deletes through a host volume bind-mounted
  inside `/var/lib/unit`.
- `apply_certificates` validates the bundle name to `[A-Za-z0-9._-]`, so a crafted
  `*.pem` filename cannot retarget the control-API `PUT` at another endpoint.

## [0.0.3] - 2026-06-08

### Added

- Supply-chain attestations on release: `release.yml` now generates an SPDX SBOM
  for each pushed image and records keyless (OIDC) build-provenance and SBOM
  attestations, pushed to GHCR as OCI referrers of the image manifest. Verify a
  pulled image with
  `gh attestation verify oci://ghcr.io/6run0/freeunit-php@<digest> --owner 6RUN0`.
- `.github/workflows/check-upstream.yml`: a weekly (and manually dispatchable)
  job that watches the FreeUnit package repo for a new release and opens a bump
  PR — it recomputes the pinned `FREEUNIT_SHA256SUMS_SHA256` trust anchor and
  refuses to bump unless every matrixed PHP line ships a module `.deb` in the new
  `SHA256SUMS`.
- `.github/dependabot.yml`: weekly grouped bump PRs for the SHA-pinned GitHub
  Actions.
- CI lint job gained workflow and markdown gates: actionlint, zizmor (workflow
  security audit), and rumdl.
- The CI trivy scan now emits SARIF and uploads it to GitHub code scanning, so
  CVEs surface in the Security tab and are tracked over time.
- `.github/workflows/security-scan.yml`: a weekly (and manually dispatchable)
  trivy re-scan of the *published* GHCR images per PHP line, so CVEs disclosed
  after a release surface without a new push.
- `examples/`: a self-contained, security-hardened deployment — a small
  `Dockerfile` bakes the app and its Unit config onto the published base image
  (config copied into `/docker-entrypoint.d`, no bind mounts), run with cap-drop
  and `no-new-privileges` hardening, with a worker that drops to the `unit` user.

### Changed

- CI build+smoke matrix now runs through Buildx with a per-PHP GitHub Actions
  layer cache (`type=gha`), so repeat runs reuse the apt/download layers instead
  of rebuilding from scratch; the trivy scan reuses the 8.4 image rather than its
  own build.
- The smoke test now runs the container under the documented hardening
  (`--cap-drop=ALL …`), so a regression that breaks cap-dropped startup (such as
  a non-root-owned state directory) is caught in CI; the `*.pem` upload it already
  asserts exercises the affected certs store.

### Fixed

- The container aborted on startup under the README's own hardening recipe
  (`--cap-drop=ALL …`): `/var/lib/unit` was owned by `unit:unit`, so the root
  `unitd` master — stripped of `CAP_DAC_OVERRIDE` by the dropped capabilities —
  could not create its `certs/` and `scripts/` stores (`mkdir … EACCES`) and
  failed to store the configuration. The state directory is now kept root-owned
  (the master is root by design), so cap-dropped startup works; the per-app
  worker still drops to `unit` via the Unit config.

## [0.0.2] - 2026-06-08

### Added

- `test/smoke.sh` gained a `--build` flag (with `--php X.Y`) so a single
  invocation covers the whole build -> run -> assert pipeline; the PHP line is
  taken from `--php`, else parsed from the image ref's `phpX.Y` tag, else the
  Dockerfile ARG default. Without `--build` the script still tests a prebuilt
  image, so `make test` and the CI build+smoke step are unchanged.

### Fixed

- `rootfs/docker-entrypoint.sh`: stop the post-configuration daemon with an
  explicit `if` instead of the `[ -f pid ] && kill … || true` one-liner, fixing
  a ShellCheck SC2015 failure on the CI runner's shellcheck and stating the
  intent more clearly.
- `test/smoke.sh`: poll the Unit control socket when verifying the uploaded
  certificate, fixing an intermittent CI failure where the controller had not
  finished restarting after initial configuration before the single probe ran.

## [0.0.1] - 2026-06-08

Initial public release. Bundles FreeUnit `1.35.5-build4` with PHP 8.3, 8.4, or
8.5 on Debian trixie (amd64).

### Added

- Single parameterized multi-stage `Dockerfile` (`base_image` → `php_image` →
  `final_image`) covering the whole PHP-version / suite / FreeUnit-release matrix
  via build args — no code generation, no per-variant directories.
- PHP **8.3 / 8.4 / 8.5** support, one embedded PHP per image, installed from the
  [deb.sury.org](https://deb.sury.org) repository with a standard extension set;
  fragile extensions (`imagick`, `uploadprogress`) installed best-effort so a new
  PHP line that lacks them still builds.
- FreeUnit core daemon and PHP module installed from prebuilt `.deb` packages
  pulled from the [GitHub release](https://github.com/6RUN0/freeunit/releases),
  not compiled from source.
- Supply-chain integrity for the `.deb` fetch: every package is verified against
  the release `SHA256SUMS`, both expected entries are asserted present (so
  `--ignore-missing` cannot pass vacuously), and `SHA256SUMS` itself is pinned in
  version control by its SHA256 to break the self-referential fetch.
- HTTPS-pinned fetches (`--proto-redir '=https'`) for the sury signing key and
  the release assets, so a redirect cannot downgrade a trust anchor to plaintext.
- deb.sury.org wired as a deb822 source with its signing key and an apt pin
  (priority 990: preferred for equal-or-newer, but unable to force a downgrade of
  a Debian package).
- `rootfs/` overlay with the entrypoint that, on first start, applies everything
  in `/docker-entrypoint.d/`: `*.sh` executed, `*.pem` uploaded as a certificate
  bundle, `*.json` `PUT` to the Unit config via the control socket.
- Runtime API via environment variables (`APPLICATION_USER` / `_UID` / `_GROUP` /
  `_GID` / `_DIR` / `_CHOWN`, `UNIT_ENTRYPOINT_QUIET_LOGS`) for app user/group and
  app-directory ownership.
- `HEALTHCHECK` probing the Unit control socket, so liveness works without a
  fixed app port and under `--cap-drop=ALL`.
- `Makefile` driving the matrix build with `all` / `php<X.Y>` / `latest` / `test`
  / `lint` / `scan` targets; per-release defaults are single-sourced from the
  `Dockerfile` ARGs.
- End-to-end smoke test (`test/smoke.sh`) that runs the image and asserts the
  entrypoint processed `*.json`, `*.sh`, and `*.pem`, with a runtime-generated
  throwaway certificate (no private key committed).
- CI workflow (`.github/workflows/ci.yml`): lint (hadolint / shellcheck / typos),
  the build + smoke matrix (8.3 / 8.4 / 8.5), and a report-only trivy scan.
- Tag-driven release workflow (`.github/workflows/release.yml`): on a `v*` tag,
  builds and smoke-tests the matrix, publishes the images to GHCR, and creates a
  GitHub Release with notes from the matching `CHANGELOG.md` section.
- Documentation: `README.md` / `README.ru.md` (runtime API, security posture,
  upstream/fork split) and `CLAUDE.md` for repo guidance.

[Unreleased]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.9...v0.1.0
[0.0.9]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.8...v0.0.9
[0.0.8]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/6RUN0/docker-freeunit-php/releases/tag/v0.0.1
