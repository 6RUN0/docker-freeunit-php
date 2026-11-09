#!/usr/bin/env bash
#
# Host driver for the entrypoint-library unit checks: optionally build the
# image, then run test/entrypoint-lib-cases.sh INSIDE it under the image's
# /bin/sh (dash), the shell the entrypoint itself runs under, as the image user.
# The cases are POSIX sh like the library; this driver is bash because it shares
# the CLI parser and the build step with test/smoke.sh (test/lib.sh).
#
#   ./test/entrypoint-lib.sh freeunit-php:trixie-php8.4          # test a prebuilt image
#   ./test/entrypoint-lib.sh --build freeunit-php:trixie-php8.5  # build it first, then test
#   ./test/entrypoint-lib.sh --build --php 8.5 freeunit-php:dev  # build a chosen PHP line

set -euo pipefail

usage() {
    cat <<EOF
Usage: ${0##*/} [--build] [--php X.Y] <image-ref>

Run the docker-entrypoint-common.sh unit checks inside <image-ref>.

  <image-ref>   image to test, e.g. freeunit-php:trixie-php8.4
  --build       docker build <image-ref> from the repo root before testing
  --php X.Y     PHP line to build (--build only; --php=X.Y is also accepted);
                default: parsed from the ref's 'phpX.Y' tag, else the Dockerfile
                ARG default
  -h, --help    show this help and exit
EOF
}

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=test/lib.sh
. "$TEST_DIR/lib.sh"
parse_test_args "$@"
build_image "$REPO_ROOT"

# Mount the cases read-only and run them as the image user (no --user) under
# /bin/sh. --entrypoint sh bypasses docker-entrypoint.sh so its startup does not
# pollute the test output.
echo "==> running entrypoint-library checks in $TEST_IMAGE_REF"
if docker run --rm --entrypoint sh \
    -v "$TEST_DIR/entrypoint-lib-cases.sh:/entrypoint-lib-cases.sh:ro" \
    "$TEST_IMAGE_REF" /entrypoint-lib-cases.sh --in-container; then
    echo "PASS: entrypoint-library checks passed in $TEST_IMAGE_REF"
else
    echo "FAIL: entrypoint-library checks failed in $TEST_IMAGE_REF" >&2
    exit 1
fi
