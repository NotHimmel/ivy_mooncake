PG_VERSION ?= pg18
export PG_CONFIG := $(shell cargo pgrx info pg-config $(PG_VERSION))
MAKEFLAGS += --no-print-directory

.PHONY: help clean ivy_duckdb_mooncake format install package ivy_duckdb run test

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
	@echo "  clean         Remove build artifacts"
	@echo ""
	@echo "Options:"
	@echo "  PG_VERSION    pg14, pg15, pg16, pg17, or pg18 (default)"

clean:
	@cargo clean

ivy_duckdb_mooncake:
	@$(MAKE) -C ivy_duckdb_mooncake GEN=ninja OVERRIDE_GIT_DESCRIBE=v1.4.1

format:
	@cargo fmt
	@cargo clippy

install:
	@cargo pgrx install --release

package:
	@cargo pgrx package

ivy_duckdb:
	@$(MAKE) -C ivy_duckdb install -j$(shell nproc)

run: ivy_duckdb
	@cargo pgrx run

test:
	@cargo pgrx regress --resetdb
