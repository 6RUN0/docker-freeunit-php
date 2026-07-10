# Custom Docker image, based on Debian, for FreeUnit with PHP

[English](README.md) · [Русский](README.ru.md) — see [CHANGELOG.md](CHANGELOG.md)
for release history.

This repo builds Docker images that bundle the [FreeUnit][upstream] daemon (a
fork of NGINX Unit) with an embedded PHP module, installed from prebuilt Debian
packages.

- **Upstream FreeUnit:** <https://github.com/freeunitorg/freeunit>
- **Package builds for trixie:** <https://github.com/6RUN0/freeunit/releases> —
  a fork that organizes the `.deb` builds for Debian trixie this image installs.
- Distribution: Debian **trixie** (amd64 only — upstream ships amd64 `.deb`s).
- PHP versions: 8.3, 8.4, 8.5 (one embedded PHP per image — the embed SAPI
  allows only one).

A single parameterized `Dockerfile` covers the whole matrix via build args; the
`Makefile` builds every variant.

[upstream]: https://github.com/freeunitorg/freeunit

## Pull

Pre-built images are published to the GitHub Container Registry at
`ghcr.io/6run0/freeunit-php`. Each release pushes one image per PHP line
(8.3 / 8.4 / 8.5) under several tags, so you can pin as loosely or as tightly as
you need:

| Tag pattern | Example | Resolves to |
|-------------|---------|-------------|
| `latest` | `ghcr.io/6run0/freeunit-php` | newest release, default PHP (8.4) |
| `<version>` | `:0.0.8` | that repo release, default PHP |
| `<suite>-php<X.Y>` | `:trixie-php8.3` | newest release on a PHP line (moves forward) |
| `<version>-php<X.Y>` | `:0.0.8-php8.3` | a repo release on a PHP line |
| `<suite>-<freeunit-release>-php<X.Y>` | `:trixie-1.35.5-build4-php8.5` | a specific FreeUnit build on a PHP line |

```bash
docker pull ghcr.io/6run0/freeunit-php:trixie-php8.4
```

The `latest` and `<suite>-php<X.Y>` tags float — a later release re-points them.
The `<version>…` and `…-<freeunit-release>…` tags stay pinned to one release. For
a byte-stable deploy pin by digest (`…@sha256:…`) — that is also the form
`gh attestation verify` checks (see the Notes section).

## Build

```bash
# Default image (trixie, php8.4)
docker build -t freeunit-php .

# A specific PHP version
docker build --build-arg PHP_VER=8.3 -t freeunit-php:8.3 .

# Pin a different FreeUnit release
docker build \
  --build-arg FREEUNIT_VERSION=1.35.5-1 \
  --build-arg FREEUNIT_RELEASE=1.35.5-build4 \
  -t freeunit-php .
```

Or use the Makefile:

```bash
make            # build all PHP versions (8.3, 8.4, 8.5)
make php8.3     # build one variant
make latest     # build the default PHP (8.4) and tag it :latest
make test       # build the default PHP and run the integration smoke test
make lint       # run all installed linters (hadolint, shellcheck, rumdl, typos)
make scan       # CVE-scan the default image (trivy/grype, if installed)
```

The per-release defaults (`SUITE`, `PHP_VER`, `FREEUNIT_VERSION`,
`FREEUNIT_RELEASE`) live in the `Dockerfile` ARGs and the `Makefile` reads them
from there, so a version bump is a single edit in the `Dockerfile`. Override any
variable on the command line, e.g.
`make FREEUNIT_RELEASE=1.35.6-build1 FREEUNIT_VERSION=1.35.6-1`.

## Run

```bash
docker run -d --name app \
  -p 8080:8080 \
  -v "$PWD/www:/www:ro" \
  -v "$PWD/config.json:/docker-entrypoint.d/config.json:ro" \
  freeunit-php
```

On first start (when `/var/lib/freeunit` is empty) the entrypoint launches the
daemon against the control socket, applies everything in `/docker-entrypoint.d/`,
then restarts the daemon in the foreground. If that initial configuration fails,
the state directory is wiped so the next start retries cleanly.

Runnable examples are in [`examples/`](examples/), one per subdirectory:

- [`examples/basic/`](examples/basic/) — a self-contained, security-hardened
  deployment (a small `Dockerfile` bakes an app and its config onto the image):
  `cd examples/basic && docker compose up --build`.
- [`examples/cron-hook/`](examples/cron-hook/) — the entrypoint hook system: one
  image runs in two roles, the Unit web server and a long-lived `supercronic`
  cron runner, selected per container by the command, with no second image and
  no forked entrypoint.

### `/docker-entrypoint.d/` conventions

Files are applied in lexical order, by extension:

| Extension | Action |
|-----------|--------|
| `*.sh`    | Executed (as root). |
| `*.pem`   | Uploaded as a certificate bundle named after the file (minus `.pem`). |
| `*.json`  | `PUT` to the Unit `config` via the control socket. |

Other file types are logged and ignored.

> Multiple `*.json` are **not** merged: `PUT /config` replaces the whole
> configuration, so only the lexically-last file takes effect (the entrypoint
> warns when it sees more than one). Ship a single combined config file.

### Environment variables

These are the image's runtime API; they are read by the entrypoint.

| Variable | Default | Purpose |
|----------|---------|---------|
| `APPLICATION_USER`  | `freeunit` | App user. If it already exists, its UID is kept. |
| `APPLICATION_UID`   | `1000` | UID used only when the user is created. |
| `APPLICATION_GROUP` | `freeunit` | App group. If it already exists, its GID is kept. |
| `APPLICATION_GID`   | `1000` | GID used only when the group is created. |
| `APPLICATION_DIR`   | _unset_ | App home dir; created if missing. |
| `APPLICATION_CHOWN` | `yes`  | When `yes`, `chown` `APPLICATION_DIR` to the app user. |
| `UNIT_ENTRYPOINT_QUIET_LOGS` | _unset_ | When set, silence entrypoint logs. |

> `APPLICATION_DIR` must be a container-owned path. With `APPLICATION_CHOWN=yes`
> its ownership is rewritten, so pointing it at a host bind-mount rewrites the
> ownership of host files.

### Security posture

The Unit master process runs as root by design — it binds privileged ports and
spawns per-app workers. Drop privileges **for the application** with the
`user`/`group` keys in the Unit config (not by changing the container user), and
harden the container at run time:

```bash
docker run --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID \
  --security-opt=no-new-privileges ... freeunit-php
```

Treat `/docker-entrypoint.d/*.sh` as trusted input only — those scripts run as
root inside the container.

## Notes

- **amd64 only.** FreeUnit publishes amd64 `.deb`s; there is no `linux/arm64`
  build.
- **Floating substrate.** The image pins the FreeUnit release, but the Debian
  base and the PHP packages from deb.sury.org are rolling and `apt full-upgrade`
  runs at build time, so two builds of the same tag are not bit-reproducible.
- The `.deb` integrity check is a SHA256 match against the release's own
  `SHA256SUMS`, itself pinned in-repo by digest so a tampered release can't supply
  a matching checksum file (integrity, not upstream authenticity — there is no
  FreeUnit signature).
- **Published images carry attestations.** Each image pushed to GHCR by the
  release workflow records keyless build-provenance and an SPDX SBOM as Sigstore
  attestations. Verify a pulled image before trusting it:

  ```bash
  gh attestation verify \
    oci://ghcr.io/6run0/freeunit-php@<digest> --owner 6RUN0
  ```

## See also

- [Changelog](CHANGELOG.md)
- [FreeUnit (upstream)](https://github.com/freeunitorg/freeunit)
- [FreeUnit trixie package builds](https://github.com/6RUN0/freeunit/releases)
- [Unit in Docker at unit.nginx.org](https://unit.nginx.org/howto/docker/)
- [github.com/nginx/unit/tree/master/pkg/docker](https://github.com/nginx/unit/tree/master/pkg/docker)
