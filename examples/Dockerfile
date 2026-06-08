# Bake a small app and its Unit config onto the freeunit-php base image, so the
# running container is self-contained — no bind mounts. The entrypoint applies
# /docker-entrypoint.d/config.json on first start, exactly as it would for a
# mounted file.
FROM ghcr.io/6run0/freeunit-php:trixie-php8.4

COPY www/ /www/
COPY config.json /docker-entrypoint.d/config.json
