PG_VERSION ?= pg18
export PG_CONFIG := $(shell cargo pgrx info pg-config $(PG_VERSION))
# Select the pgrx pg feature from PG_VERSION instead of relying on the
# Cargo default. Keeps the build target and PG_CONFIG in sync.
PG_FEATURES := --no-default-features --features $(PG_VERSION),bgworker
MAKEFLAGS += --no-print-directory

# Offline builds: `make OFFLINE=1 install` (etc). cargo-pgrx spawns its own
# cargo and exposes no --offline/--config flag, so we gate two ways cargo always
# honors: the CARGO_NET_OFFLINE env var, and auto-discovery of .cargo/config.toml.
# $(CARGO) temporarily swaps the vendored-source config in as .cargo/config.toml
# for the duration of the build and always restores the online one afterward
# (trap covers a failed/interrupted cargo; only SIGKILL can leave the .bak).
# Requires a pre-populated vendor/ (see .cargo/config.offline.toml); we fail
# loudly if it's missing rather than silently falling back to the network.
ifdef OFFLINE
export CARGO_NET_OFFLINE := true
CARGO := test -d vendor || { echo "OFFLINE=1 but vendor/ is missing. Run 'cargo vendor --locked --manifest-path Cargo.toml --sync ivy_moonlink/Cargo.toml vendor/' on a connected machine (or unpack the offline bundle) first." >&2; exit 1; } && \
	cp .cargo/config.toml .cargo/config.toml.online.bak && \
	cp .cargo/config.offline.toml .cargo/config.toml && \
	trap 'mv -f .cargo/config.toml.online.bak .cargo/config.toml' EXIT INT TERM && \
	cargo
else
CARGO := cargo
endif

.PHONY: help clean ivy_duckdb_mooncake format install package ivy_duckdb run test offline-bundle

help:
	@echo "Usage: make <COMMAND> [OPTIONS]"
	@echo ""
	@echo "Commands:"
	@echo "  run           Build and run pg_mooncake for development"
	@echo "  install       Build and install pg_mooncake"
	@echo "  ivy_duckdb    Build and install ivy_duckdb"
	@echo "  package       Build an installation package for release"
	@echo "  format        Format the codebase"
	@echo "  test          Run all tests"
	@echo "  offline-bundle  Produce a self-contained tarball for air-gapped build (run online)"
	@echo "  clean         Remove build artifacts"
	@echo ""
	@echo "Options:"
	@echo "  PG_VERSION    pg14, pg15, pg16, pg17, or pg18 (default); selects pgrx feature + pg_config"
	@echo "  OFFLINE=1     Build Rust crates from vendor/ with no network (see .cargo/config.offline.toml)"

clean:
	@cargo clean

ivy_duckdb_mooncake:
	@$(MAKE) -C ivy_duckdb_mooncake GEN=ninja OVERRIDE_GIT_DESCRIBE=v1.4.1

format:
	@cargo fmt
	@cargo clippy

install:
	@$(CARGO) pgrx install --release -c $(PG_CONFIG) $(PG_FEATURES)

package:
	@$(CARGO) pgrx package -c $(PG_CONFIG) $(PG_FEATURES)

ivy_duckdb:
	@$(MAKE) -C ivy_duckdb install -j$(shell nproc)

run: ivy_duckdb
	@$(CARGO) pgrx run $(PG_VERSION) $(PG_FEATURES)

test:
	@$(CARGO) pgrx regress $(PG_VERSION) --resetdb $(PG_FEATURES)

# Run on a CONNECTED machine. Gathers submodules + vendored crates + the httpfs
# extension source into dist/ivy_mooncake-offline-*.tar.gz for air-gapped build.
offline-bundle:
	@scripts/make-offline-bundle.sh
