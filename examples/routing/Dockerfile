# One image serving TWO PHP applications behind URI routing, with a static-file
# share in front of a front controller. Everything is baked: the two apps under
# /www and the Unit config that wires the routes. No runtime mounts.
FROM ghcr.io/6run0/freeunit-php:trixie-php8.4

# Both apps plus the static asset and the per-app php.ini.
COPY www/ /www/

# The routing config, applied on first start by the base entrypoint.
COPY config.json /docker-entrypoint.d/config.json
