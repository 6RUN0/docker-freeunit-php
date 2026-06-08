# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions here track the **packaging** (this repo), not the bundled software; each
release records the FreeUnit and PHP versions it ships.

## [Unreleased]

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

[Unreleased]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/6RUN0/docker-freeunit-php/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/6RUN0/docker-freeunit-php/releases/tag/v0.0.1
