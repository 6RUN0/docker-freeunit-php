#!/usr/bin/env bash
#
# Shared helpers for the host-side test drivers (smoke.sh, entrypoint-lib.sh):
# the common `[--build] [--php X.Y] <image-ref>` CLI parser and the optional
# image build, single-sourced so a fix (or a new build-arg like --suite) lands in
# one place. Each script defines its own usage() and then calls parse_test_args
# followed by build_image. Not meant to run standalone.

# Parse the shared CLI. The caller must have defined a usage() function. Sets the
# globals TEST_IMAGE_REF, TEST_PHP_VER and TEST_SHOULD_BUILD. Args: "$@"
parse_test_args() {
    TEST_SHOULD_BUILD=
    TEST_PHP_VER=
    local positional_args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h | --help) usage; exit 0 ;;
            --build) TEST_SHOULD_BUILD=1; shift ;;
            --php) TEST_PHP_VER="${2:?--php requires a value}"; shift 2 ;;
            --php=*) TEST_PHP_VER="${1#*=}"; shift ;;
            --) shift; positional_args+=("$@"); break ;;
            -*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
            *) positional_args+=("$1"); shift ;;
        esac
    done
    if [ "${#positional_args[@]}" -lt 1 ]; then
        usage >&2
        exit 1
    fi
    TEST_IMAGE_REF=${positional_args[0]}
}

# Build TEST_IMAGE_REF if --build was given, else no-op. The PHP line comes from --php,
# else the ref's 'phpX.Y' tag, else the Dockerfile ARG default (PHP_VER unset, so
# SUITE / FREEUNIT_* also fall back to their ARG defaults). Args: <repo-root>
build_image() {
    local repo_root=$1
    [ -n "$TEST_SHOULD_BUILD" ] || return 0
    if [ -z "$TEST_PHP_VER" ] && [[ "$TEST_IMAGE_REF" =~ php([0-9]+\.[0-9]+) ]]; then
        TEST_PHP_VER="${BASH_REMATCH[1]}"
    fi
    local build_args=()
    if [ -n "$TEST_PHP_VER" ]; then
        build_args+=(--build-arg "PHP_VER=$TEST_PHP_VER")
    fi
    echo "==> building $TEST_IMAGE_REF${TEST_PHP_VER:+ (PHP $TEST_PHP_VER)}"
    docker build "${build_args[@]}" -t "$TEST_IMAGE_REF" "$repo_root"
}
