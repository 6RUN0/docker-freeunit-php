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
| `<version>` | `:0.4.0` | that repo release, default PHP |
| `<suite>-php<X.Y>` | `:trixie-php8.3` | newest release on a PHP line (moves forward) |
| `<version>-php<X.Y>` | `:0.4.0-php8.3` | a repo release on a PHP line |
| `<suite>-<freeunit-release>-php<X.Y>-v<version>` | `:trixie-1.37.2-2-php8.3-v0.4.0` | a FreeUnit build in a repo release on a PHP line |

```bash
docker pull ghcr.io/6run0/freeunit-php:trixie-php8.4
```

The `latest` and `<suite>-php<X.Y>` tags float - a later release re-points them;
from 0.4.0 they point at the non-root image (see [Run as non-root](#run-as-non-root)).
The `<version>...` tags stay pinned to one release: the release workflow refuses
to overwrite one that exists. Up to 0.3.0 the FreeUnit tag had no version
(`trixie-1.37.2-2-php8.3` is the root-based 0.3.0 image). For a byte-stable
deploy pin by digest (`...@sha256:...`) - that is also the form
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

When the state directory `/run/freeunit` is empty (a new container, or every
start with a tmpfs at `/run`) the entrypoint launches the daemon against the
control socket, applies everything in `/docker-entrypoint.d/`, then restarts the
daemon in the foreground. If that initial configuration fails, the state
directory is wiped so the next start retries cleanly.

Runnable examples are in [`examples/`](examples/), one per subdirectory:

- [`examples/basic/`](examples/basic/) - a self-contained, security-hardened
  deployment (a small `Dockerfile` bakes an app and its config onto the image):
  `cd examples/basic && docker compose up --build`.
- [`examples/cron-hook/`](examples/cron-hook/) - the entrypoint hook system: one
  image runs in two roles, the Unit web server and a long-lived `supercronic`
  cron runner, selected per container by the command, with no second image and
  no forked entrypoint.

### `/docker-entrypoint.d/` conventions

Files are applied in lexical order, by extension:

| Extension | Action |
|-----------|--------|
| `*.sh`    | Executed as the container user. |
| `*.pem`   | Uploaded as a certificate bundle named after the file (minus `.pem`). |
| `*.json`  | `PUT` to the Unit `config` via the control socket. |

Other file types are logged and ignored.

A script that renders configuration at start-up writes it to
`$ENTRYPOINT_GENERATED_DIR` (`/run/docker-entrypoint.d`), not into the read-only
image: after the `*.pem` and `*.json` of `/docker-entrypoint.d`, those of the
generated dir are applied (certificates of both dirs before any config, the
generated config last). A `*.sh` there is not executed.

> Multiple `*.json` are **not** merged: `PUT /config` replaces the whole
> configuration, so only the last file takes effect (the entrypoint warns when a
> dir holds more than one). Ship a single combined config file.

An explicit `freeunitd ...` / `freeunitd-debug ...` command gets the missing
`--no-daemon`, `--control`, `--pid`, `--statedir` and `--tmpdir` flags; one of
the last four with another value stops the start with an error, because the
initial configuration writes to the entrypoint's paths. `freeunitd --version` /
`--help` / `-h` run as given, without initial configuration.

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `UNIT_ENTRYPOINT_QUIET_LOGS` | _unset_ | When set, silence entrypoint logs. |
| `HOME` | `/home/nonroot` | May be read-only (ssh, composer and drush work); mount it when the application writes there. |

The `APPLICATION_USER/UID/GROUP/GID/DIR/CHOWN` variables of 0.3.x are gone: the
image creates no user at start and changes no ownership.

### Run as non-root

The image starts as `nonroot` (uid:gid `65532:65532`, home `/home/nonroot`):
`tini`, the entrypoint, the Unit master and the PHP workers all run as that
user, so the container needs no capability. A derived `Dockerfile` that installs
packages switches to `USER 0:0` before `RUN apt-get` and back to
`USER 65532:65532` at the end.

The hardened run - read-only root filesystem, no capabilities, every writable
path a mount owned by the process. The host dir for `/tmp` must belong to the
container uid (`sudo install -d -m 0700 -o 65532 -g 65532 tmp`); a missing one is
created by Docker as root and the start stops with the `/tmp` hint.

```bash
docker run -d --name app -p 8080:8080 \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /run:size=16m,uid=65532,gid=65532,mode=0700 \
  -v "$PWD/tmp:/tmp" \
  -v "$PWD/www:/www:ro" \
  -v "$PWD/config.json:/docker-entrypoint.d/config.json:ro" \
  freeunit-php
```

| Path | Holds | Size | Mount |
|------|-------|------|-------|
| `/run` | control socket, pid, state dir `/run/freeunit`, `/run/docker-entrypoint.d` | KiB | tmpfs |
| `/tmp` | Unit request-body buffers (`--tmpdir /tmp`), PHP uploads and temp files, sessions | up to `max_body_size` per request | bind mount on disk (recommended), or tmpfs with a `size` |

- **Any non-root uid:gid works** (`--user 1000:1000`): the tmpfs mounts take the
  same `uid=`/`gid=` and bind mounts must be writable for it. The entrypoint
  checks writability of `/var/run`, the state dir and `/tmp` before anything else
  and stops with a hint naming the missing mount. A uid without a passwd entry
  gets `HOME=/`; ssh refuses to run for it, so a site that uses ssh adds the
  entry in its image.
- **`HOME` may stay read-only** (`/home/nonroot`, empty, 0755): ssh, composer
  and drush work without writing there. An application that writes to `HOME`
  (`known_hosts`, a cache) mounts a tmpfs or a dir owned by the uid there.
- **`/tmp` must be writable for the process uid**: the large temporary files
  (request bodies, PHP uploads) go there. Under `read_only` mount a host dir
  owned by the uid there (recommended) or a tmpfs with a `size`. The image's
  `php.ini` (`cli` and `embed`) points `session.save_path` at `/tmp`; PHP keeps
  its other temp paths at their `/tmp` defaults.
- **Unit workers do not inherit the container environment:** set `HOME` in the
  application's `environment` block when PHP sends mail or runs ssh.
- **Do not set `user`/`group` in the Unit config:** an unprivileged Unit runs
  its workers as its own user.
- **Ports below 1024** need `net.ipv4.ip_unprivileged_port_start=0` (the Docker
  default since Engine 20.10; set it explicitly with `--sysctl` /
  `sysctls:` where unsure).
- **Started as root** (`--user 0:0`, `user: root`): before any write the
  entrypoint hands stdio to 65532 and re-execs itself as `65532:65532` with no
  supplementary groups and `no_new_privs`, logging a warning. That needs the
  default capabilities or at least `CAP_SETUID`, `CAP_SETGID`, `CAP_CHOWN` and
  `CAP_KILL` (tini forwards `docker stop` to the 65532 processes); without them
  the start stops with an error. `tini` (PID 1) stays root with the container's
  capabilities in that mode - a fallback, not a recommended setup. The
  healthcheck, run by Docker as root then, probes as the owner of the control
  socket. A non-root uid with group 0 among its groups is refused.
- **The control API is reachable by the application code.** The control socket
  (0600), the state dir and the generated dir belong to the same uid as the PHP
  workers: code execution in PHP can reconfigure Unit (routes, listeners,
  `share`, `environment`) until the container restarts. The unix socket rules
  out SSRF, not RCE; this is the price of a rootless Unit.
- `docker exec` runs as the container user. `docker exec -u 0` bypasses the
  guard: such a root creates root-owned files the process cannot rewrite later.

### Entrypoint hooks

A derived image adds a launch mode with one file in `/docker-entrypoint-hook.d/`
(see [`examples/cron-hook/`](examples/cron-hook/)). The entrypoint is POSIX sh
(`/bin/sh`, dash in the image) and sources (`.`) each `*.sh` there, so a hook is
POSIX sh too; a bash hook fails at start. A hook file:

- only defines functions `handle_<cmd>` (`<cmd>` of `[A-Za-z0-9_]`), with no
  top-level code; is root-owned and not group/world-writable;
- is selected when `command -v handle_<cmd>` prints that name (a shell
  function; an executable of that name in `PATH` does not count) and is called
  as `handle_<cmd> "$@"` with the full argv; it must `exec` the final process,
  and `set -e` is off inside it;
- prefixes every variable it sets with its own name (`<cmd>_`): POSIX sh has no
  `local`, and `UNIT_*`, `ENTRYPOINT_*`, `_ep_*` belong to the entrypoint.

### Security posture

Treat `/docker-entrypoint.d/*.sh` and `/docker-entrypoint-hook.d/*.sh` as trusted
input: they run as the container user with access to the control API. The
entrypoint refuses a hook file that is not root-owned or is group/world-writable,
so a compromised application cannot persist code into the next start.

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
