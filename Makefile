# Build the FreeUnit + PHP image matrix from a single Dockerfile.
#
#   make help         # list the available targets
#   make              # build all PHP versions
#   make php8.3       # build one variant
#   make latest       # build the default PHP and tag it :latest
#   make test         # build the default PHP and run the smoke + entrypoint tests
#   make test-entrypoint  # run the entrypoint-library unit checks (image must exist)
#   make test-examples    # build the default PHP and verify every examples/ example
#   make lint         # run all installed linters
#   make scan         # CVE-scan the default image (trivy/grype if installed)
#
# Override any variable on the command line. A one-off build of a different
# FreeUnit release needs all three together (the pinned manifest digest must
# match the fetched SHA256SUMS), e.g.
#   make FREEUNIT_RELEASE=1.35.6-build1 FREEUNIT_VERSION=1.35.6-1 \
#        FREEUNIT_SHA256SUMS_SHA256=<sha256 of that release's SHA256SUMS> php8.4

IMAGE        ?= freeunit-php
PHP_VERSIONS ?= 8.3 8.4 8.5

# Single source of truth: the per-release defaults live in the Dockerfile ARGs
# and are read from there, so a version bump is one edit (in the Dockerfile).
# Override any of them on the command line. The $(or ...,$(error ...)) makes a
# failed extraction loud: if an ARG line format drifts (quotes, inline comment,
# spaces around =) the build aborts instead of silently using an empty value.
SUITE            ?= $(or $(shell sed -n 's/^ARG SUITE=//p' Dockerfile),$(error could not read ARG SUITE from Dockerfile))
DEFAULT_PHP      ?= $(or $(shell sed -n 's/^ARG PHP_VER=//p' Dockerfile),$(error could not read ARG PHP_VER from Dockerfile))
FREEUNIT_VERSION ?= $(or $(shell sed -n 's/^ARG FREEUNIT_VERSION=//p' Dockerfile),$(error could not read ARG FREEUNIT_VERSION from Dockerfile))
FREEUNIT_RELEASE ?= $(or $(shell sed -n 's/^ARG FREEUNIT_RELEASE=//p' Dockerfile),$(error could not read ARG FREEUNIT_RELEASE from Dockerfile))
FREEUNIT_SHA256SUMS_SHA256 ?= $(or $(shell sed -n 's/^ARG FREEUNIT_SHA256SUMS_SHA256=//p' Dockerfile),$(error could not read ARG FREEUNIT_SHA256SUMS_SHA256 from Dockerfile))

# Extra flags forwarded to every `docker build` (empty by default). CI sets this
# to wire buildx layer caching, e.g. DOCKER_BUILD_EXTRA="--cache-from type=gha ..."
DOCKER_BUILD_EXTRA ?=

TARGETS := $(addprefix php,$(PHP_VERSIONS))

SHELL_SCRIPTS := $(shell find rootfs test -type f -name '*.sh' 2>/dev/null)

DEFAULT_IMAGE := $(IMAGE):$(SUITE)-php$(DEFAULT_PHP)

.PHONY: help all latest test test-entrypoint test-examples scan lint lint-dockerfile lint-shell lint-md lint-typos $(TARGETS)

# Keep bare `make` building the whole matrix even though `help` is defined first
# (a target ahead of `all` would otherwise become the default goal).
.DEFAULT_GOAL := all

# Self-documenting help: lists every target annotated with a `## ` comment, so
# the description lives on the target line (single source of truth) rather than
# in a separate hand-synced list. Run `make help` for the menu.
help: ## list the available targets
	@echo 'FreeUnit + PHP image matrix. Targets:'
	@echo
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_.-]+:.*## /{printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo 'Plus one target per PHP version: $(TARGETS)'
	@echo 'Override defaults on the command line, e.g. make PHP_VERSIONS=8.4 or make SUITE=bookworm.'

all: $(TARGETS) ## build every PHP version (the default target)

# The immutable tag carries FREEUNIT_RELEASE (the unique build id) so rebuilding
# a different build of the same version does not overwrite an existing tag; the
# $(SUITE)-php$* tag floats to the latest build.
$(TARGETS): php%:
	docker build $(DOCKER_BUILD_EXTRA) \
	  --build-arg SUITE=$(SUITE) \
	  --build-arg PHP_VER=$* \
	  --build-arg FREEUNIT_VERSION=$(FREEUNIT_VERSION) \
	  --build-arg FREEUNIT_RELEASE=$(FREEUNIT_RELEASE) \
	  --build-arg FREEUNIT_SHA256SUMS_SHA256=$(FREEUNIT_SHA256SUMS_SHA256) \
	  -t $(IMAGE):$(SUITE)-$(FREEUNIT_RELEASE)-php$* \
	  -t $(IMAGE):$(SUITE)-php$* \
	  .

latest: php$(DEFAULT_PHP) ## build the default PHP and tag it :latest
	docker tag $(DEFAULT_IMAGE) $(IMAGE):latest

# Build the default variant and run the integration tests against it: the
# end-to-end smoke test (happy path) plus the entrypoint-library unit checks
# (error/timeout paths the smoke test cannot reach).
test: php$(DEFAULT_PHP) ## build the default PHP and run smoke + entrypoint tests
	./test/smoke.sh $(DEFAULT_IMAGE)
	./test/entrypoint-lib.sh $(DEFAULT_IMAGE)

# Run just the entrypoint-library unit checks against an already-built image.
test-entrypoint: ## run entrypoint-library unit checks (image must exist)
	./test/entrypoint-lib.sh $(DEFAULT_IMAGE)

# Build the default variant and verify every examples/ example end to end: a
# static hardening lint over the compose files plus a live build+run+assert of
# each example. The just-built default image is passed as the base the examples
# FROM, so this runs without pulling from GHCR. NOT wired into CI (it is a heavier
# gate); run it locally before touching examples/. Lint only: EXAMPLES_LINT_ONLY=1.
test-examples: php$(DEFAULT_PHP) ## build the default PHP and verify every examples/ example
	EXAMPLES_BASE_IMAGE=$(DEFAULT_IMAGE) ./test/examples.sh

# CVE-scan the default image. Skipped (not failed) if no scanner is installed.
scan: ## CVE-scan the default image (trivy/grype if installed)
	@if command -v trivy >/dev/null 2>&1; then \
	  echo "trivy image $(DEFAULT_IMAGE)"; \
	  trivy image --severity HIGH,CRITICAL --exit-code 1 $(DEFAULT_IMAGE); \
	elif command -v grype >/dev/null 2>&1; then \
	  echo "grype $(DEFAULT_IMAGE)"; \
	  grype --fail-on high $(DEFAULT_IMAGE); \
	else echo "neither trivy nor grype installed, skipping CVE scan"; fi

# Run every linter that is installed (a missing tool is skipped, not an error;
# an installed tool that reports problems fails the target).
lint: lint-dockerfile lint-shell lint-md lint-typos ## run all installed linters

lint-dockerfile:
	@if command -v hadolint >/dev/null 2>&1; then \
	  echo "hadolint Dockerfile"; hadolint Dockerfile; \
	else echo "hadolint not installed, skipping Dockerfile lint"; fi

lint-shell:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "shellcheck $(SHELL_SCRIPTS)"; shellcheck $(SHELL_SCRIPTS); \
	else echo "shellcheck not installed, skipping shell lint"; fi

lint-md:
	@if command -v rumdl >/dev/null 2>&1; then \
	  echo "rumdl check *.md"; rumdl check *.md; \
	else echo "rumdl not installed, skipping markdown lint"; fi

lint-typos:
	@if command -v typos >/dev/null 2>&1; then \
	  echo "typos"; typos; \
	else echo "typos not installed, skipping spell check"; fi
