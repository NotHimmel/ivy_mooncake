#!/usr/bin/env bash
#
# make-offline-bundle.sh -- produce a self-contained tarball for air-gapped
# ("完全内网" / no public internet) build + install of ivy_mooncake.
#
# RUN THIS ON A CONNECTED MACHINE. It gathers every build-time input that the
# normal build would otherwise fetch from the internet, so the air-gapped side
# can run `make OFFLINE=1 install` with zero external network:
#
#   layer 1 (this script) source tree + recursive submodules, .git stripped and
#                         replaced with the marker stubs the Makefiles check
#   layer 2 (cargo)       vendor/ -- all Rust crates from Cargo.lock
#   layer 3 (FetchContent) offline-deps/httpfs-src -- the one DuckDB extension
#                         built.-time git-cloned; pinned commit, recursive
#   layer 5 (runtime)     offline-deps/duckdb-extensions/... -- the signed
#                         mooncake.duckdb_extension from the community repo.
#                         At runtime pg_duckdb executes `INSTALL mooncake FROM
#                         community`; when the file already sits in the
#                         extension_directory that INSTALL is a no-network
#                         no-op (duckdb extension_install.cpp: file exists ->
#                         NOP), so pre-placing it makes first use fully
#                         offline. Air-gapped placement: see BUNDLE-INFO.
#
# NOT bundled (provision separately on the air-gapped host; see BUNDLE-INFO):
#   - toolchain: rustc + cargo-pgrx (pinned in rust-toolchain.toml / Dockerfile)
#   - system libs: OpenSSL + curl dev packages (httpfs links system OpenSSL)
#   - IvorySQL itself (pg_config)
#
# Usage:
#   scripts/make-offline-bundle.sh [OUTPUT_DIR]
# Env toggles (for iterating; leave unset for a real bundle):
#   BUNDLE_SKIP_VENDOR=1    reuse an existing vendor/ instead of re-running it
#   BUNDLE_SKIP_ARCHIVE=1   stage everything but don't create the final tarball
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="${1:-$REPO_ROOT/dist}"
HTTPFS_DEST="offline-deps/httpfs-src"
CMAKE_EXT="ivy_duckdb/third_party/pg_duckdb_extensions.cmake"

log() { printf '\033[1;34m[bundle]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[bundle] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight: this is the ONLINE step; fail loud if prerequisites missing ---
command -v git   >/dev/null || die "git not found"
command -v cargo >/dev/null || die "cargo not found"
command -v tar   >/dev/null || die "tar not found"
[ -f Cargo.toml ] && [ -f "$CMAKE_EXT" ] || die "run from the ivy_mooncake repo root"
if ! git ls-remote https://github.com/duckdb/duckdb-httpfs HEAD >/dev/null 2>&1; then
	die "no network to github. This script must run on a CONNECTED machine."
fi

# --- layer 1: complete the source tree (recursive submodules) ---------------
log "initializing submodules (recursive)..."
git submodule update --init --recursive

# --- layer 2: vendor Rust crates --------------------------------------------
if [ "${BUNDLE_SKIP_VENDOR:-}" = 1 ] && [ -d vendor ]; then
	log "reusing existing vendor/ (BUNDLE_SKIP_VENDOR=1)"
else
	log "vendoring Rust crates (both workspaces)..."
	cargo vendor --locked --manifest-path Cargo.toml \
		--sync ivy_moonlink/Cargo.toml vendor/ >/dev/null
fi
[ -d vendor ] || die "vendor/ was not produced"

# --- layer 3: fetch the httpfs extension source at its pinned commit ---------
# Parse url + commit from the extension config so they never drift from what
# the build actually loads.
HTTPFS_URL="$(awk '/duckdb_extension_load\(httpfs/{f=1} f&&/GIT_URL/{print $2; f=0}' "$CMAKE_EXT")"
HTTPFS_TAG="$(awk '/duckdb_extension_load\(httpfs/{f=1} f&&/GIT_TAG/{print $2; f=0}' "$CMAKE_EXT")"
[ -n "$HTTPFS_URL" ] && [ -n "$HTTPFS_TAG" ] || die "could not parse httpfs GIT_URL/GIT_TAG from $CMAKE_EXT"
log "fetching httpfs source $HTTPFS_TAG from $HTTPFS_URL ..."
rm -rf "$HTTPFS_DEST"
mkdir -p "$(dirname "$HTTPFS_DEST")"
git clone --quiet "$HTTPFS_URL" "$HTTPFS_DEST"
git -C "$HTTPFS_DEST" fetch --quiet origin "$HTTPFS_TAG" 2>/dev/null || git -C "$HTTPFS_DEST" fetch --quiet origin
git -C "$HTTPFS_DEST" checkout --quiet --detach "$HTTPFS_TAG"
# Deliberately NOT recursing httpfs's own submodules: they are just a full
# duckdb checkout + extension-ci-tools, used only to build httpfs standalone.
# Built in-tree (via EXTENSION_CONFIGS) it uses the parent duckdb, so pulling
# them would duplicate a whole duckdb tree into the bundle for nothing.
# It's pure source now; drop its git metadata (FETCHCONTENT_SOURCE_DIR does not
# need .git) so the bundle carries no dangling gitlinks.
find "$HTTPFS_DEST" -name .git -prune -exec rm -rf {} +

# --- layer 5: the mooncake DuckDB extension (runtime, community-signed) ------
# Version must match the DuckDB linked into pg_duckdb (ivy_duckdb/Makefile),
# platform must match the target host. The community file is signed and its
# origin is "community", so no allow_unsigned/repository changes are needed on
# the air-gapped host -- pre-placing the file turns the runtime INSTALL into a
# cache-hit no-op.
DUCKDB_VER="$(sed -n 's/^DUCKDB_VERSION *= *//p' ivy_duckdb/Makefile | head -1)"
[ -n "$DUCKDB_VER" ] || die "could not parse DUCKDB_VERSION from ivy_duckdb/Makefile"
# Which target platforms to bundle the (binary) extension for. Everything else
# in the bundle is source and builds natively on any architecture; this is the
# only per-platform artifact. Default covers the packaging machine; override
# for cross-platform bundles, e.g.:
#   BUNDLE_PLATFORMS="linux_amd64 linux_arm64" make offline-bundle
# install-duckdb-extensions copies the whole tree, and DuckDB picks its own
# <platform>/ subdirectory at runtime, so shipping several is harmless.
if [ -z "${BUNDLE_PLATFORMS:-}" ]; then
	case "$(uname -m)" in
		x86_64)  BUNDLE_PLATFORMS=linux_amd64 ;;
		aarch64) BUNDLE_PLATFORMS=linux_arm64 ;;
		*) die "unsupported platform $(uname -m); set BUNDLE_PLATFORMS explicitly" ;;
	esac
fi
for platform in $BUNDLE_PLATFORMS; do
	EXT_DEST="offline-deps/duckdb-extensions/$DUCKDB_VER/$platform"
	EXT_URL="http://community-extensions.duckdb.org/$DUCKDB_VER/$platform/mooncake.duckdb_extension.gz"
	log "fetching mooncake.duckdb_extension ($DUCKDB_VER/$platform) from community repo..."
	mkdir -p "$EXT_DEST"
	if command -v curl >/dev/null; then
		curl -fsSL "$EXT_URL" -o "$EXT_DEST/mooncake.duckdb_extension.gz"
	else
		wget -q "$EXT_URL" -O "$EXT_DEST/mooncake.duckdb_extension.gz"
	fi
	gunzip -f "$EXT_DEST/mooncake.duckdb_extension.gz"
	[ -s "$EXT_DEST/mooncake.duckdb_extension" ] || die "mooncake.duckdb_extension download/unpack failed for $platform"
done
DUCKDB_PLATFORM="$BUNDLE_PLATFORMS"

# --- overlay: .git-marker stubs so the air-gapped build needs no git ---------
# The ivy_duckdb Makefile depends on .git/modules/third_party/duckdb/HEAD whose
# recipe is `git submodule update`. Touching the marker satisfies the rule so
# the recipe never runs. Mirrors the Dockerfile's stub logic.
OVERLAY="$(mktemp -d)"
trap 'rm -rf "$OVERLAY"' EXIT
for sm in ivy_duckdb ivy_moonlink ivy_duckdb_mooncake; do
	mkdir -p "$OVERLAY/$sm/.git/modules/third_party/duckdb"
	: > "$OVERLAY/$sm/.git/modules/third_party/duckdb/HEAD"
done
mkdir -p "$OVERLAY/ivy_duckdb/third_party/duckdb/.git"
: > "$OVERLAY/ivy_duckdb/third_party/duckdb/.git/HEAD"

# --- manifest ---------------------------------------------------------------
DESCRIBE="$(git describe --always --dirty 2>/dev/null || echo unknown)"
cat > "$OVERLAY/BUNDLE-INFO.txt" <<EOF
ivy_mooncake offline build bundle
=================================
source revision : $DESCRIBE
httpfs source   : $HTTPFS_URL @ $HTTPFS_TAG
rustc pinned    : $(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml 2>/dev/null || echo '(see rust-toolchain.toml)')
cargo-pgrx      : 0.16.1 (must be pre-installed on the air-gapped host)

Bundled build-time inputs (no network needed):
  - full source tree + recursive submodules (.git stripped; marker stubs added)
  - vendor/           : Rust crates for both workspaces (from Cargo.lock)
  - offline-deps/httpfs-src : DuckDB httpfs extension source (pinned commit)
  - offline-deps/duckdb-extensions/$DUCKDB_VER/{$DUCKDB_PLATFORM}/mooncake.duckdb_extension
                      : signed community build; pre-place it so the runtime
                        INSTALL becomes a zero-network cache hit

Provision separately on the air-gapped host (NOT in this tarball):
  - rustc $(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml 2>/dev/null) and cargo-pgrx 0.16.1
  - system OpenSSL + curl dev packages (httpfs links system OpenSSL; do NOT enable vcpkg)
  - IvorySQL (a working pg_config)

Build on the air-gapped host:
  tar xzf ivy_mooncake-offline-*.tar.gz && cd ivy_mooncake
  make OFFLINE=1 ivy_duckdb PG_VERSION=pg14   # C++/DuckDB side (layer 3)
  make OFFLINE=1 install    PG_VERSION=pg14   # Rust extension (layer 2) +
                                              # auto-installs the mooncake
                                              # DuckDB extension into sharedir

Runtime setup on the air-gapped host -- postgresql.conf, then restart:
  shared_preload_libraries = 'pg_duckdb,pg_mooncake'
  wal_level = logical
  duckdb.allow_community_extensions = true
  duckdb.extension_directory = '<sharedir>/pg_duckdb/extensions'
      # exact path is printed by `make OFFLINE=1 install`; tying the
      # extension cache to the installation instead of a data directory
      # means re-initdb needs no re-copying. The pre-placed file turns the
      # runtime INSTALL into a zero-network cache hit.
EOF

if [ "${BUNDLE_SKIP_ARCHIVE:-}" = 1 ]; then
	log "BUNDLE_SKIP_ARCHIVE=1: staged overlay at $OVERLAY (not archived)"
	log "httpfs source at $HTTPFS_DEST, vendor/ ready"
	trap - EXIT
	echo "$OVERLAY"
	exit 0
fi

# --- archive: working tree (minus VCS + build artifacts) + overlay ----------
# Two passes into one uncompressed tar, then gzip:
#   pass 1  the working tree, dropping every .git (real, huge) and build output
#   pass 2  the overlay, whose members live UNDER .git/ (the marker stubs) --
#           so it must NOT carry the .git excludes, hence a separate append.
# A single invocation can't do this: --exclude is global and would strip the
# stubs too. (tar's `*` matches `/`, so `*/.git` catches .git at any depth.)
mkdir -p "$OUT_DIR"
TAR="$OUT_DIR/ivy_mooncake-offline-${DESCRIBE}.tar"
XFORM='s,^\./,ivy_mooncake/,'
log "archiving working tree ..."
tar cf "$TAR" \
	--exclude='*/.git' --exclude='./.git' \
	--exclude='./dist' \
	--exclude='./target' \
	--exclude='./ivy_duckdb/third_party/duckdb/build' \
	--transform="$XFORM" \
	-C "$REPO_ROOT" .
log "appending .git marker stubs ..."
tar rf "$TAR" --transform="$XFORM" -C "$OVERLAY" .
log "compressing ..."
gzip -f "$TAR"
log "done: ${TAR}.gz ($(du -h "${TAR}.gz" | cut -f1))"
