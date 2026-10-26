###############################################
#
# Makefile — Zig Build Extensions
#
# `make validate` is the gate; `make` is the inner loop. format, lint and
# validate come from ../styleguide/Makefile.in.
#
###############################################

# Optional include to extend the makefile targets
-include ../styleguide/Makefile.in

.DEFAULT_GOAL := all

.PHONY: all validate build test cross tag clean

# ---------------------------------------------
# Configuration
# ---------------------------------------------

# The Zig 0.17 compiler; `make ZIG=zig17 ...` where `zig` is another release.
ZIG ?= zig

# The released version, read from build.zig.zon (the source of truth).
VERSION := $(shell sed -n -E 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' build.zig.zon)

# The release tag: `v` and the version, the form `zig build zigbuildx-pin` finds.
TAG := v$(VERSION)

# The hosts `cross` compiles for, beside this one.
CROSS_TARGETS := x86_64-windows aarch64-windows x86_64-linux aarch64-linux

# ---------------------------------------------
# Workflows
# ---------------------------------------------

# Format and test: the inner loop.
all: format test
	@echo "done"

# The pre-commit gate: Makefile.in's clean, format, lint, build and test, then cross.
validate: cross

# ---------------------------------------------
# Build & test
# ---------------------------------------------

# Build the library and the host tool.
build:
	$(ZIG) build

# Run the unit test suite.
test:
	$(ZIG) build test --summary all

# Compile the suite and the host tool for CROSS_TARGETS, without running them.
#
# zigbuildx runs inside other projects' build runners, on whatever host they
# build on. Its host-specific paths are runtime branches, so a Windows-only
# mistake compiles fine on macOS until something instantiates it for Windows.
cross:
	@mkdir -p zig-out/cross
	@for t in $(CROSS_TARGETS); do \
		$(ZIG) test src/module.zig -target $$t --test-no-exec -femit-bin=zig-out/cross/test-$$t || exit 1; \
		$(ZIG) build-exe src/tool.zig -target $$t -femit-bin=zig-out/cross/zigbuildx-$$t || exit 1; \
		echo "cross $$t ok"; \
	done

# ---------------------------------------------
# Release
# ---------------------------------------------

# Tag the build.zig.zon version as TAG, then push the branch and that tag.
tag:
	@test -n "$(VERSION)" || { echo "tag: cannot read .version from build.zig.zon"; exit 1; }
	git tag -a "$(TAG)" -m "$(TAG)"
	git push
	git push origin "$(TAG)"

# ---------------------------------------------
# Housekeeping
# ---------------------------------------------

# Remove every build artifact.
clean:
	rm -rf .zig-cache zig-out
