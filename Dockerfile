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
    # The container runs read_only as a non-root user with /tmp as its only
    # writable temp dir (a mount owned by the process), where PHP and its
    # extensions put temp files by default. Sessions default to the root-owned
    # /var/lib/php/sessions instead: point both SAPIs there too, cli (drush,
    # cron) and embed (the Unit module).
    for sapi in cli embed; do \
    echo 'session.save_path = /tmp' > "/etc/php/${php_ver}/${sapi}/conf.d/90-nonroot-session.ini"; \
    done; \
    rm -rf /var/lib/apt/lists/*;


# FreeUnit core daemon + php module from prebuilt .deb
#
# GitHub renames the '~' in asset file names to '.', so the download URL is
# always  ${BRAND}_<ver>.<suite>_amd64.deb, while SHA256SUMS lists either
# <ver>~<suite> (releases up to 1.37.1) or <ver>.<suite> (from 1.37.2-2). Each
# file is saved under the name SHA256SUMS lists, so `sha256sum -c` matches it
# (under any other name the entry is skipped and the check passes vacuously).
FROM php_image AS final_image
ARG DEBIAN_FRONTEND=noninteractive
ARG SUITE
ARG PHP_VER
ARG FREEUNIT_VERSION=1.37.2-2
ARG FREEUNIT_RELEASE=1.37.2-2
# SHA256 of the release's SHA256SUMS file, pinned in version control as a trust
# anchor. The .deb integrity check below verifies each package against
# SHA256SUMS, but that file is fetched from the same release, so a release
# compromise could replace both the .debs and their checksums. Pinning the
# manifest digest here breaks that self-reference: tampering no longer passes,
# because the expected value lives in this repo. Bump it with FREEUNIT_RELEASE.
ARG FREEUNIT_SHA256SUMS_SHA256=ef2eeb5267fcd2316b9aea7aafd5ea22270bf743db0cfe0daa131677973890ec
ARG FREEUNIT_BASE_URL="https://github.com/6RUN0/freeunit/releases/download"
# Brand identity, mirroring the upstream freeunit packaging vocabulary
# (freeunit/pkg/deb/Makefile): BRAND is the dpkg/apt identity (asset/package
# names we download), RUNTIME is the on-disk identity the package compiled into
# the binary (daemon ${RUNTIME}d, /var/lib/${RUNTIME}, control.${RUNTIME}.sock,
# /var/log/${RUNTIME}.log, the ${RUNTIME}:${RUNTIME} user/group), and RUNDIR is
# where the socket + pid live. We INSTALL prebuilt .debs, so these are NOT free
# knobs: only the published identity exists. They are single-sourced here for
# the RUN (asset names + on-disk paths) and the OCI LABELs, and the RUN asserts
# the installed binary was compiled with exactly these paths — a future upstream
# identity change then fails the build loudly instead of shipping an image whose
# entrypoint manages paths the daemon does not use.
ARG BRAND=freeunit
ARG RUNTIME=freeunit
ARG RUNDIR=/var/run
ARG BRAND_TITLE=FreeUnit
ARG HOMEPAGE=https://freeunit.org
ARG DOCS_URL=https://docs.freeunit.org
# The image user; must equal UNIT_NONROOT_UID/GID in
# rootfs/docker-entrypoint-common.sh, which the build asserts after COPY rootfs/.
ARG NONROOT_UID=65532
ARG NONROOT_GID=65532
# DL3003: the work dir is created at build time with `mktemp -d`, so its path is
# dynamic and cannot be expressed with WORKDIR — `cd` into it is intentional.
# DL3008: "$@" holds the two local .deb paths, pinned by SHA256SUMS, not repo names.
# hadolint ignore=DL3003,DL3008
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
    # Pick each package's local name from SHA256SUMS. A missing entry fails
    # here: `--ignore-missing` below would otherwise pass vacuously and an
    # unverified .deb would be installed silently.
    set --; \
    for pkg in "${BRAND}" "${BRAND}-php${php_ver}"; do \
    if grep -qF "${pkg}_${deb_ver}_amd64.deb" SHA256SUMS; then name="${pkg}_${deb_ver}_amd64.deb"; \
    elif grep -qF "${pkg}_${asset_ver}_amd64.deb" SHA256SUMS; then name="${pkg}_${asset_ver}_amd64.deb"; \
    else echo "ERROR: no SHA256SUMS entry for ${pkg}_${deb_ver}_amd64.deb or ${pkg}_${asset_ver}_amd64.deb"; exit 1; \
    fi; \
    curl -fsSL --retry 3 --retry-connrefused --proto-redir '=https' -o "$name" "${url}/${pkg}_${asset_ver}_amd64.deb"; \
    set -- "$@" "./$name"; \
    done; \
    sha256sum -c --ignore-missing SHA256SUMS; \
    apt-get update; \
    # apt resolves libphp${php_ver}-embed (already present) and the virtual
    # ${RUNTIME}-rX.Y.Z provided by the core ${BRAND} package from the two local files
    apt-get install -y --no-install-recommends "$@"; \
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
    # The image user (distroless 'nonroot'); the whole daemon runs as it, so the
    # package's ${RUNTIME}:${RUNTIME} system user and /var/lib/${RUNTIME} stay
    # unused. -l: no lastlog/faillog entry, which for a high uid is a large file.
    # The home dir is empty and 0755, so any other uid given HOME=/home/nonroot
    # reads it as an empty read-only HOME instead of failing with EACCES.
    groupadd -g "${NONROOT_GID}" nonroot; \
    useradd -l -u "${NONROOT_UID}" -g "${NONROOT_GID}" -M -d /home/nonroot -s /usr/sbin/nologin nonroot; \
    install -d -m 0755 -o "${NONROOT_UID}" -g "${NONROOT_GID}" /home/nonroot; \
    # /run holds the control socket, pid, state and generated dirs (a tmpfs owned
    # by the process under read_only); owned by the image user so that a run
    # without read_only and tmpfs works the same way.
    chown "${NONROOT_UID}:${NONROOT_GID}" /run; \
    # preparing init dir
    mkdir -p /docker-entrypoint.d; \
    # entrypoint extension dir: child images drop *.sh handlers here (see
    # rootfs/docker-entrypoint.sh); kept separate from the runtime-config dir above
    mkdir -p /docker-entrypoint-hook.d; \
    # log to stdout
    ln -sf /dev/stdout "/var/log/${RUNTIME}.log"; \
    # Assert the prebuilt binary's compiled identity matches RUNTIME/RUNDIR. We
    # only INSTALL .debs, so the log symlink created above and the socket/pid
    # paths the entrypoint and the healthcheck use are correct ONLY if the daemon
    # was compiled with the same. `--version` prints the configure line; a mismatch
    # means upstream changed its on-disk identity — fail now, not at runtime.
    ver="$("${RUNTIME}d" --version 2>&1)"; \
    echo "$ver"; \
    for expect in \
    "--statedir=/var/lib/${RUNTIME}" \
    "--control=unix:${RUNDIR}/control.${RUNTIME}.sock" \
    "--pid=${RUNDIR}/${RUNTIME}.pid" \
    "--log=/var/log/${RUNTIME}.log" \
    "--user=${RUNTIME}" \
    "--group=${RUNTIME}"; do \
    case "$ver" in \
    *"$expect"*) ;; \
    *) echo "ERROR: ${RUNTIME}d was not compiled with '$expect' (upstream on-disk identity changed? update BRAND/RUNTIME/RUNDIR)"; exit 1 ;; \
    esac; \
    done; \
    php -v;
WORKDIR /
# rootfs/ mirrors the container filesystem (entrypoint scripts, configs, ...)
COPY rootfs/ /
# The root guard of the entrypoint drops to the library literals and the default
# USER below is this ARG pair: assert both name the passwd entry created above.
RUN \
    set -eu; \
    lib=/docker-entrypoint-common.sh; \
    uid="$(sed -n 's/^readonly UNIT_NONROOT_UID=//p' "$lib")"; \
    gid="$(sed -n 's/^readonly UNIT_NONROOT_GID=//p' "$lib")"; \
    home="$(sed -n 's/^readonly UNIT_NONROOT_HOME=//p' "$lib")"; \
    want="nonroot:x:${uid}:${gid}::${home}:/usr/sbin/nologin"; \
    got="$(getent passwd nonroot)"; \
    [ "$got" = "$want" ] && [ "$uid:$gid" = "${NONROOT_UID}:${NONROOT_GID}" ] \
    || { echo "ERROR: passwd entry '$got' or ARG NONROOT_UID/GID ${NONROOT_UID}:${NONROOT_GID} does not match the library literals '$want'"; exit 1; }
LABEL org.opencontainers.image.title="${BRAND}-php" \
      org.opencontainers.image.description="${BRAND_TITLE} (NGINX Unit fork) with an embedded PHP ${PHP_VER} module on Debian ${SUITE}" \
      org.opencontainers.image.source="https://github.com/6RUN0/docker-freeunit-php" \
      org.opencontainers.image.url="${HOMEPAGE}" \
      org.opencontainers.image.documentation="${DOCS_URL}" \
      org.opencontainers.image.licenses="BSD-3-Clause" \
      org.opencontainers.image.version="${FREEUNIT_VERSION}"
# Liveness via the Unit control socket: app listener ports are configured at
# runtime (so no fixed port to probe), but a responsive control API proves the
# daemon and the embedded PHP module are up. The probe is a script so the socket
# path stays single-sourced from docker-entrypoint-common.sh (UNIT_CONTROL_SOCKET)
# rather than duplicated here - an exec-form CMD cannot expand a build ARG/ENV.
# It runs as the container user, which owns the 0600 socket together with the
# daemon.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/docker-healthcheck.sh"]
# No CMD: docker-entrypoint.sh supplies the default launch (${RUNTIME}d against
# the control socket) from the same UNIT_* single source, so the binary name and
# socket path are not duplicated in an exec-form CMD that cannot take a build ARG.
ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
# Non-root from the first instruction. A derived image needs USER 0:0 before
# its own RUN apt-get and USER 65532:65532 again at the end.
USER ${NONROOT_UID}:${NONROOT_GID}
