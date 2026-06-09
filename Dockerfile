# FreeUnit (NGINX Unit fork) + PHP on Debian.
# Prebuilt .deb packages: https://github.com/6RUN0/freeunit/releases
#
# The whole php-version / suite / release matrix is covered by build args;
# see the Makefile for the matrix build.
#
#   docker build -t freeunit-php .                       # defaults: trixie, php8.4
#   docker build --build-arg PHP_VER=8.3 -t freeunit-php:8.3 .

# Global build args (available to FROM and, when re-declared, inside stages)
ARG SUITE=trixie
ARG IMAGE_SUFFIX=-slim

# Base image with package updates and package mirror change
FROM debian:${SUITE}${IMAGE_SUFFIX} AS base_image
ARG DEBIAN_FRONTEND=noninteractive
ARG SUITE
# Neutral CDN defaults; override with a regional mirror for speed, e.g.
#   --build-arg DEBIAN_MIRROR=http://mirror.selectel.ru/debian
# Debian over http is fine: apt verifies detached signatures of the metadata.
ARG DEBIAN_MIRROR="http://deb.debian.org/debian"
ARG DEBIAN_SECURITY_MIRROR="http://deb.debian.org/debian-security"
# packages.sury.org over https — the signing key is fetched from here (below),
# and a trust anchor must not travel over plaintext. Alternative mirrors:
#  - http://debian.octopuce.fr/sury-php/
#  - https://mirrors.sunsite.dk/deb.sury.org/php/
ARG SURY_MIRROR="https://packages.sury.org/php/"
# rolling sury/debian repos: pinning every package version is impractical here
# hadolint ignore=DL3008
RUN \
    set -eux; \
    apt_mirror() { \
    sed -i \
    -e "s|http://deb\.debian\.org/debian-security|$3|g" \
    -e "s|http://deb\.debian\.org/debian|$2|g" \
    "$1"; \
    }; \
    [ -w "/etc/apt/sources.list.d/debian.sources" ] && \
    apt_mirror "/etc/apt/sources.list.d/debian.sources" "${DEBIAN_MIRROR}" "${DEBIAN_SECURITY_MIRROR}"; \
    [ -w "/etc/apt/sources.list" ] && \
    apt_mirror "/etc/apt/sources.list" "${DEBIAN_MIRROR}" "${DEBIAN_SECURITY_MIRROR}"; \
    apt-get update; \
    apt-get full-upgrade -y; \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    tini \
    ; \
    # PHP embed SAPI and extensions come from deb.sury.org (deb822 source format).
    # --proto-redir '=https' keeps the trust-anchor (signing key) fetch on https
    # even across redirects, so a MITM cannot 302 it down to plaintext; the key
    # itself is unverified once fetched, so the transport must stay trusted.
    curl -fsSL --retry 3 --retry-connrefused --proto-redir '=https' -o /usr/share/keyrings/org.sury.packages.php.gpg "${SURY_MIRROR}apt.gpg"; \
    { \
    echo "Types: deb"; \
    echo "URIs: ${SURY_MIRROR}"; \
    echo "Suites: ${SUITE}"; \
    echo "Components: main"; \
    echo "Signed-By: /usr/share/keyrings/org.sury.packages.php.gpg"; \
    } > /etc/apt/sources.list.d/org.sury.packages.php.sources; \
    # Priority 990 (> Debian's default 500) makes sury preferred for equal or
    # newer versions, while staying < 1000 so a compromised sury cannot force a
    # *downgrade* of a Debian package to a vulnerable version. Kept archive-wide
    # (Package: *) on purpose: scoping it to php* risks a mixed sury/Debian
    # shared-library set ("package soup").
    { \
    echo "Package: *"; \
    echo "Pin: release o=deb.sury.org"; \
    echo "Pin-Priority: 990"; \
    } > /etc/apt/preferences.d/org-sury-packages-php; \
    rm -rf /var/lib/apt/lists/*;


# php embed SAPI (required by the FreeUnit module) + extensions
FROM base_image AS php_image
ARG DEBIAN_FRONTEND=noninteractive
ARG PHP_VER=8.4
# rolling sury repo: pinning every php extension version is impractical here
# hadolint ignore=DL3008
RUN \
    set -eux; \
    php_ver="${PHP_VER}"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    libphp${php_ver}-embed \
    php${php_ver}-apcu \
    php${php_ver}-bcmath \
    php${php_ver}-bz2 \
    php${php_ver}-cli \
    php${php_ver}-curl \
    php${php_ver}-gd \
    php${php_ver}-intl \
    php${php_ver}-mbstring \
    php${php_ver}-mysql \
    php${php_ver}-readline \
    php${php_ver}-redis \
    php${php_ver}-tidy \
    php${php_ver}-xml \
    php${php_ver}-xmlrpc \
    php${php_ver}-yaml \
    php${php_ver}-zip \
    ; \
    # Extensions that may lag behind a new PHP line on sury (notably 8.5):
    # install best-effort so a plain `make` does not fail when they are absent.
    # Distinguish "absent from the index" (skip intentionally) from "install
    # failed" (corrupt download, dependency conflict, GPG error) — the latter
    # must fail the build under `set -eux`, not be masked into a green build
    # with a silently missing or half-installed extension.
    for ext in imagick uploadprogress; do \
    pkg="php${php_ver}-${ext}"; \
    if apt-cache show "$pkg" >/dev/null 2>&1; then \
    apt-get install -y --no-install-recommends "$pkg"; \
    else \
    echo "WARNING: $pkg not in index on sury, skipping"; \
    fi; \
    done; \
    rm -rf /var/lib/apt/lists/*;


# FreeUnit core daemon + php module from prebuilt .deb
#
# GitHub renames the '~' in asset file names to '.', so the same package
# is published as  unit_<ver>.<suite>_amd64.deb  (download URL) while its
# real version / SHA256SUMS entry is  <ver>~<suite>. Files are saved under
# the '~' name so `sha256sum -c` actually matches (with the '.' name the
# entries are skipped and the check passes vacuously).
FROM php_image AS final_image
ARG DEBIAN_FRONTEND=noninteractive
ARG SUITE
ARG PHP_VER
ARG FREEUNIT_VERSION=1.35.5-1
ARG FREEUNIT_RELEASE=1.35.5-build4
# SHA256 of the release's SHA256SUMS file, pinned in version control as a trust
# anchor. The .deb integrity check below verifies each package against
# SHA256SUMS, but that file is fetched from the same release, so a release
# compromise could replace both the .debs and their checksums. Pinning the
# manifest digest here breaks that self-reference: tampering no longer passes,
# because the expected value lives in this repo. Bump it with FREEUNIT_RELEASE.
ARG FREEUNIT_SHA256SUMS_SHA256=0db5491eca299286b6e6257305d369fe0f057be049a5a898774b0d48b6de06ab
ARG FREEUNIT_BASE_URL="https://github.com/6RUN0/freeunit/releases/download"
# DL3003: the work dir is created at build time with `mktemp -d`, so its path is
# dynamic and cannot be expressed with WORKDIR — `cd` into it is intentional.
# hadolint ignore=DL3003
RUN \
    set -eux; \
    php_ver="${PHP_VER}"; \
    deb_ver="${FREEUNIT_VERSION}~${SUITE}"; \
    asset_ver="${FREEUNIT_VERSION}.${SUITE}"; \
    url="${FREEUNIT_BASE_URL}/${FREEUNIT_RELEASE}"; \
    # Download + verify in a throwaway dir so cleanup is a single, name-agnostic
    # `rm -rf` (no per-file list to keep in sync when assets are added/renamed).
    work="$(mktemp -d)"; \
    cd "$work"; \
    curl -fsSL --retry 3 --retry-connrefused --proto-redir '=https' -o SHA256SUMS "${url}/SHA256SUMS"; \
    # Verify the integrity manifest against the in-repo pinned digest before
    # trusting any entry in it (breaks the self-referential fetch). Compared with
    # a string test rather than a pipe into `sha256sum -c` to keep the RUN free
    # of pipes (hadolint DL4006) — `sha256sum FILE` prints "<hash>  FILE".
    [ "$(sha256sum SHA256SUMS)" = "${FREEUNIT_SHA256SUMS_SHA256}  SHA256SUMS" ] \
    || { echo "ERROR: SHA256SUMS digest does not match the pinned FREEUNIT_SHA256SUMS_SHA256"; exit 1; }; \
    curl -fsSL --retry 3 --retry-connrefused --proto-redir '=https' -o "unit_${deb_ver}_amd64.deb" "${url}/unit_${asset_ver}_amd64.deb"; \
    curl -fsSL --retry 3 --retry-connrefused --proto-redir '=https' -o "unit-php${php_ver}_${deb_ver}_amd64.deb" "${url}/unit-php${php_ver}_${asset_ver}_amd64.deb"; \
    sha256sum -c --ignore-missing SHA256SUMS; \
    # --ignore-missing passes vacuously if an expected name is absent from
    # SHA256SUMS (e.g. upstream asset rename), so assert both entries exist —
    # otherwise an unverified .deb would be installed silently.
    grep -qF "unit_${deb_ver}_amd64.deb" SHA256SUMS \
    || { echo "ERROR: no SHA256SUMS entry for unit_${deb_ver}_amd64.deb"; exit 1; }; \
    grep -qF "unit-php${php_ver}_${deb_ver}_amd64.deb" SHA256SUMS \
    || { echo "ERROR: no SHA256SUMS entry for unit-php${php_ver}_${deb_ver}_amd64.deb"; exit 1; }; \
    apt-get update; \
    # apt resolves libphp${php_ver}-embed (already present) and the virtual
    # unit-rX.Y.Z provided by the core unit package from the two local files
    apt-get install -y --no-install-recommends \
    "./unit_${deb_ver}_amd64.deb" \
    "./unit-php${php_ver}_${deb_ver}_amd64.deb" \
    ; \
    cd /; \
    rm -rf "$work"; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    apt-get clean; \
    rm -rf \
    /var/cache/apt/archives/* \
    /var/lib/apt/lists/* \
    /var/log/alternatives.log \
    /var/log/apt* \
    /var/log/dpkg.log \
    ; \
    # the unit package postinst creates the unit:unit system user/group
    # State directory: kept root-owned so the root unitd master can create its
    # certs/ and scripts/ stores even under --cap-drop=ALL, which strips
    # CAP_DAC_OVERRIDE (a unit-owned statedir would make those mkdirs fail with
    # EACCES, breaking startup). The per-app worker drops to 'unit' via the Unit
    # config's user/group keys, not via statedir ownership.
    rm -rf /var/lib/unit; \
    mkdir -p /var/lib/unit; \
    # preparing init dir
    mkdir -p /docker-entrypoint.d; \
    # entrypoint extension dir: child images drop *.sh handlers here (see
    # rootfs/docker-entrypoint.sh); kept separate from the runtime-config dir above
    mkdir -p /docker-entrypoint-hook.d; \
    # log to stdout
    ln -sf /dev/stdout /var/log/unit.log; \
    unitd --version; \
    php -v;
WORKDIR /
# rootfs/ mirrors the container filesystem (entrypoint scripts, configs, ...)
COPY rootfs/ /
LABEL org.opencontainers.image.title="freeunit-php" \
      org.opencontainers.image.description="FreeUnit (NGINX Unit fork) with an embedded PHP ${PHP_VER} module on Debian ${SUITE}" \
      org.opencontainers.image.source="https://github.com/6RUN0/docker-freeunit-php" \
      org.opencontainers.image.url="https://github.com/6RUN0/docker-freeunit-php" \
      org.opencontainers.image.licenses="BSD-3-Clause" \
      org.opencontainers.image.version="${FREEUNIT_VERSION}"
# Liveness via the Unit control socket: app listener ports are configured at
# runtime (so no fixed port to probe), but a responsive control API proves the
# daemon and the embedded PHP module are up. Runs as root (image default), which
# owns the 0600 socket, so it works even under --cap-drop=ALL.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS -o /dev/null --unix-socket /var/run/control.unit.sock http://localhost/ || exit 1
ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
CMD ["unitd", "--no-daemon", "--control", "unix:/var/run/control.unit.sock"]
