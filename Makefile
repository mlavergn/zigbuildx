###############################################
#
# Makefile — Zig Build Extensions
#
# `make validate` is the gate; `make` is the inner loop.
#
###############################################

.DEFAULT_GOAL := all

# ---------------------------------------------
# Configuration
# ---------------------------------------------

# The released version, read from build.zig.zon (the source of truth).
VERSION := $(shell sed -n -E 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' build.zig.zon)

# Every Zig source this project owns.
ZIG_SOURCES := build.zig $(shell find src -name '*.zig' | sort)

# The Zig 0.17 compiler; `make ZIG=zig17 ...` where `zig` is another release.
ZIG ?= zig

# The zlint config directory; `make substyle` adds it as a submodule.
STYLEGUIDE ?= styleguide

.PHONY: all validate test cross format lint tag substyle subpull clean

# ---------------------------------------------
# Primary workflows
# ---------------------------------------------

# Format and test.
all: format test
	@echo "done"

# Full pre-commit gate. zlint exits zero on findings: read the output.
validate: clean format lint test cross
	@echo "validate done"

# ---------------------------------------------
# Test, format & lint
# ---------------------------------------------

# Run the unit test suite.
test:
	$(ZIG) build test --summary all

# Compile the suite and the host tool for the hosts this one cannot run.
#
# zigbuildx runs inside other projects' build runners, on whatever host they
# build on. Its host-specific paths are runtime branches, so a Windows-only
# mistake compiles fine on macOS until something instantiates it for Windows;
# this does, without running anything.
CROSS_TARGETS := x86_64-windows aarch64-windows x86_64-linux aarch64-linux
cross:
	@mkdir -p zig-out/cross
	@for t in $(CROSS_TARGETS); do \
		$(ZIG) test src/module.zig -target $$t --test-no-exec -femit-bin=zig-out/cross/test-$$t || exit 1; \
		$(ZIG) build-exe src/tool.zig -target $$t -femit-bin=zig-out/cross/zigbuildx-$$t || exit 1; \
		echo "cross $$t ok"; \
	done

# Format the Zig sources.
format:
	$(ZIG) fmt $(ZIG_SOURCES) build.zig.zon

# Lint the Zig sources against the shared styleguide.
lint:
	@zlintpre $(ZIG_SOURCES)
	@echo "$(ZIG_SOURCES)" | tr ' ' '\n' | zlint -c $(STYLEGUIDE) -S

# ---------------------------------------------
# Release
# ---------------------------------------------

# Tag the build.zig.zon version and push it.
tag:
	@test -n "$(VERSION)" || { echo "could not read .version from build.zig.zon"; exit 1; }
	git tag -a "$(VERSION)" -m "$(VERSION)"
	git push
	git push --tags

# ---------------------------------------------
# Housekeeping
# ---------------------------------------------

# Remove every build artifact.
clean:
	rm -rf .zig-cache
	rm -rf zig-out
