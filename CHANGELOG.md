# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions here track the **packaging** (this repo), not the bundled software; each
release records the FreeUnit and PHP versions it ships.

## [Unreleased]

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

[Unreleased]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.4...HEAD
[0.0.4]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/6RUN0/docker-freeunit-php/releases/tag/v0.0.1
