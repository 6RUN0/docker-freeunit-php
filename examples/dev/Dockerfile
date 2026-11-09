# Local-development image: iterate on PHP code without rebuilding. The app code
# is bind-mounted at run time (see docker-compose.yml), so this image only bakes
# the Unit config; editing www/*.php on the host is picked up live because Unit
# re-reads PHP files per request.
#
# The base image's PHP line is chosen at build time via PHP_VER, forwarded from
# the compose .env file. PHP_VER must match a published GHCR tag
# (ghcr.io/6run0/freeunit-php:trixie-php<PHP_VER>): 8.3, 8.4, or 8.5.
ARG PHP_VER=8.4
FROM ghcr.io/6run0/freeunit-php:trixie-php${PHP_VER}

# Only the Unit config is baked. The app code is NOT copied -- it is bind-mounted
# in docker-compose.yml so host edits are live. The entrypoint applies this
# config when the container starts with an empty state dir (/run/freeunit); see
# the README note on why config edits, unlike code edits, need a rebuild.
COPY config.json /docker-entrypoint.d/config.json

# The mount point of the `data` named volume, owned by the image user: a fresh
# named volume copies it, so the unprivileged worker can write there with no
# runtime chown and no CAP_CHOWN. Creating it needs root; the image user is
# restored right after.
USER 0:0
RUN install -d -o 65532 -g 65532 /data
USER 65532:65532
