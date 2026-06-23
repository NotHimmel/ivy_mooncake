# syntax=docker/dockerfile:1.6
#
# ivy_mooncake — IvorySQL distribution of pg_mooncake (UBI8 base)
#
# Build:
#   docker build -t ivorysql/ivy_mooncake:5.3-ubi8 .
#
# Run:
#   docker run --name ivy_mooncake \
#     -e IVORYSQL_PASSWORD=password \
#     -p 5432:5432 -p 1521:1521 \
#     -v ivy_mooncake_data:/var/lib/ivorysql/data \
#     -v ivy_mooncake_warehouse:/tmp/moonlink_iceberg \
#     ivorysql/ivy_mooncake:5.3-ubi8

ARG IVORYSQL_BASE=registry.highgo.com/ivorysql/ivorysql:5.4-ubi8

# ============================================================================
# Stage 1: build
# ============================================================================
FROM ${IVORYSQL_BASE} AS build

USER 0

# Install build toolchain. UBI8 = RHEL-based, use dnf/microdnf, not apt.
RUN set -eux; \
    PKG=$(command -v dnf || command -v microdnf || command -v yum); \
    $PKG install -y --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        ca-certificates curl git which findutils \
        gcc gcc-c++ make cmake pkgconfig \
        openssl-devel readline-devel zlib-devel \
        lz4-devel libxml2-devel libpq-devel \
        libcurl-devel \
        clang clang-devel llvm-libs \
        ccache \
        ; \
    # ninja-build optional (in CRB/EPEL). Don't fail if absent.
    $PKG install -y --enablerepo='*' ninja-build 2>/dev/null || true; \
    $PKG clean all || true; \
    rm -rf /var/cache/{dnf,yum,microdnf} 2>/dev/null || true

# Rust 1.91.1 + cargo-pgrx 0.16.1 (versions locked to project requirements).
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain 1.91.1 --profile minimal
# Prepend ccache compiler wrappers (/usr/lib64/ccache/{cc,gcc,c++,g++}) so the
# DuckDB C++ build and pgxs C compiles route through ccache automatically.
# CCACHE_DIR points at the BuildKit cache mount used below, so object files
# survive across rebuilds even when a layer is invalidated.
ENV PATH="/usr/lib64/ccache:/root/.cargo/bin:${PATH}" \
    CCACHE_DIR="/ccache" \
    CCACHE_MAXSIZE="10G"
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    cargo install --locked cargo-pgrx@0.16.1

# Locate IvorySQL pg_config. Override at build time if auto-detect fails:
#   --build-arg IVORYSQL_PG_CONFIG=/path/to/pg_config
ARG IVORYSQL_PG_CONFIG=
RUN set -eux; \
    P="${IVORYSQL_PG_CONFIG}"; \
    if [ -z "${P}" ] || [ ! -x "${P}" ]; then \
        P="$(find / -name pg_config -executable -type f 2>/dev/null | grep -i ivorysql | head -1)"; \
    fi; \
    if [ -z "${P}" ] || [ ! -x "${P}" ]; then \
        P="$(command -v pg_config || true)"; \
    fi; \
    if [ -z "${P}" ] || [ ! -x "${P}" ]; then \
        echo "ERROR: cannot locate IvorySQL pg_config" >&2; \
        find / -name pg_config -executable 2>/dev/null | head -10 >&2; \
        exit 1; \
    fi; \
    echo "PG_CONFIG=${P}"; \
    "${P}" --version; \
    echo "${P}" > /etc/pgconfig

RUN cargo pgrx init --pg18="$(cat /etc/pgconfig)"

WORKDIR /ivy_mooncake

# Copy manifest + 3 submodules + sources.
COPY Cargo.toml Cargo.lock Makefile pg_mooncake.control rust-toolchain.toml ./
COPY ivy_moonlink        ./ivy_moonlink
COPY ivy_duckdb          ./ivy_duckdb
COPY ivy_duckdb_mooncake ./ivy_duckdb_mooncake
COPY src                 ./src

# Bypass git-dependent make rules in submodules. .dockerignore excludes the
# host's .git/, so submodules' .git pointer files break. We replace each
# submodule's .git pointer with a self-contained minimal directory that
# carries the marker files the Makefile checks. Submodule SOURCES were
# copied in by the earlier COPY steps; we only need to fake the markers.
RUN set -eux; \
    # Replace gitlink files with fake .git dirs containing expected markers.
    for sm in ivy_duckdb ivy_moonlink ivy_duckdb_mooncake; do \
        rm -f "${sm}/.git"; \
        mkdir -p "${sm}/.git/modules/third_party/duckdb"; \
        touch "${sm}/.git/modules/third_party/duckdb/HEAD"; \
    done; \
    # ivy_duckdb's nested duckdb sub-submodule also needs the same.
    if [ -d ivy_duckdb/third_party/duckdb ]; then \
        rm -f ivy_duckdb/third_party/duckdb/.git; \
        mkdir -p ivy_duckdb/third_party/duckdb/.git; \
        touch ivy_duckdb/third_party/duckdb/.git/HEAD; \
    fi; \
    # Sanity: duckdb sources must be present (host pre-ran `git submodule
    # update --init --recursive` before docker build).
    test -f ivy_duckdb/third_party/duckdb/CMakeLists.txt \
        || (echo "ERROR: ivy_duckdb/third_party/duckdb/CMakeLists.txt missing." >&2; \
            echo "Run on host first:  git submodule update --init --recursive" >&2; \
            exit 1)

# Build + install ivy_duckdb to IvorySQL libdir/sharedir.
# GEN=ninja if available; else fall back to default make generator.
RUN --mount=type=cache,target=/ccache \
    set -eux; \
    PG_CONFIG="$(cat /etc/pgconfig)"; \
    GEN="$(command -v ninja >/dev/null 2>&1 && echo ninja || echo '')"; \
    PG_CONFIG="${PG_CONFIG}" GEN="${GEN}" make ivy_duckdb; \
    ccache -s 2>/dev/null || true

# Build + package ivy_mooncake, then collect ALL runtime artifacts.
# Bypass `make package` because its bare `cargo pgrx package` auto-picks
# /usr/bin/pg_config (system PG 13 on UBI8). Pass IvorySQL pg_config
# explicitly via --pg-config so packaging uses pg18 features.
#
# Packaging and artifact-collection MUST be one RUN: target/ is a BuildKit
# cache mount (not persisted into the image layer), so a later RUN would not
# see the package output. We copy artifacts OUT of the cache mount into the
# real filesystem (/build_output) within this same RUN.
# - ivy_duckdb installed files: from IvorySQL libdir/sharedir (real fs)
# - ivy_mooncake package: from target/release/pg_mooncake-pg18/ (cache mount)
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/ivy_mooncake/target,sharing=locked \
    --mount=type=cache,target=/ccache \
    set -eux; \
    PG_CONFIG="$(cat /etc/pgconfig)"; \
    cargo pgrx package --pg-config "${PG_CONFIG}"; \
    ccache -s 2>/dev/null || true; \
    LIBDIR="$($PG_CONFIG --pkglibdir)"; \
    SHAREDIR="$($PG_CONFIG --sharedir)"; \
    mkdir -p /build_output/lib /build_output/share/extension; \
    # ivy_duckdb artifacts (installed in-place by `make ivy_duckdb`)
    cp -av "${LIBDIR}/pg_duckdb.so"               /build_output/lib/; \
    cp -av "${LIBDIR}/libduckdb.so"               /build_output/lib/; \
    cp -av "${SHAREDIR}/extension/pg_duckdb.control" /build_output/share/extension/; \
    cp -av "${SHAREDIR}/extension/pg_duckdb"--*.sql  /build_output/share/extension/; \
    # ivy_mooncake artifacts (from cargo pgrx package output tree)
    find target/release/pg_mooncake-pg18 -name 'pg_mooncake.so'         -exec cp -av {} /build_output/lib/             \; ; \
    find target/release/pg_mooncake-pg18 -name 'pg_mooncake.control'    -exec cp -av {} /build_output/share/extension/ \; ; \
    find target/release/pg_mooncake-pg18 -name 'pg_mooncake--*.sql'     -exec cp -av {} /build_output/share/extension/ \; ; \
    echo "---staging tree---"; \
    find /build_output -type f | sort

# Pgrx regression tests live in tests/pg_regress/. Not needed to build the
# extension, but required by `cargo pgrx regress` in CI. Copied last so that
# editing test SQL files doesn't invalidate the expensive ivy_duckdb /
# cargo pgrx package layers above.
COPY tests ./tests

# ============================================================================
# Stage 2: runtime
# ============================================================================
FROM ${IVORYSQL_BASE}

LABEL org.opencontainers.image.title="ivy_mooncake" \
      org.opencontainers.image.description="IvorySQL distribution of pg_mooncake — real-time analytics via Iceberg columnstore" \
      org.opencontainers.image.source="https://github.com/IvorySQL/ivy_mooncake" \
      org.opencontainers.image.base.name="${IVORYSQL_BASE}" \
      org.opencontainers.image.licenses="MIT"

USER 0

# Carry pg_config path from build stage.
COPY --from=build /etc/pgconfig /etc/pgconfig

# Copy staging tree.
COPY --from=build /build_output /build_output

# Install staged files into IvorySQL's real libdir/sharedir + append config.
RUN set -eux; \
    PG_CONFIG="$(cat /etc/pgconfig)"; \
    LIBDIR="$($PG_CONFIG --pkglibdir)"; \
    SHAREDIR="$($PG_CONFIG --sharedir)"; \
    test -d "${LIBDIR}"   || (echo "ERROR: ${LIBDIR} missing in runtime image" >&2; exit 1); \
    test -d "${SHAREDIR}/extension" || (echo "ERROR: ${SHAREDIR}/extension missing" >&2; exit 1); \
    cp -av /build_output/lib/*.so                   "${LIBDIR}/"; \
    cp -av /build_output/share/extension/*          "${SHAREDIR}/extension/"; \
    rm -rf /build_output; \
    # Append required PG configuration so initdb / restart picks it up.
    SAMPLE="${SHAREDIR}/postgresql.conf.sample"; \
    test -f "${SAMPLE}" || (echo "ERROR: ${SAMPLE} missing" >&2; exit 1); \
    cat >> "${SAMPLE}" <<'EOF'

# ---- ivy_mooncake configuration (added by Dockerfile) ----
# liboracle_parser + ivorysql_ora come from the IvorySQL base.
# pg_duckdb + pg_mooncake added by this image. Order matters.
shared_preload_libraries = 'liboracle_parser,ivorysql_ora,pg_duckdb,pg_mooncake'
wal_level = logical
duckdb.allow_community_extensions = true
EOF

# Force UTF8 locale for initdb. pg_duckdb refuses to install on SQL_ASCII
# databases (its install SQL checks current_setting('server_encoding')).
# Use C.UTF-8 — universal, no langpack package needed (vs en_US.UTF-8 which
# requires glibc-langpack-en on UBI8).
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LC_COLLATE=C.UTF-8 \
    LC_CTYPE=C.UTF-8

# Mooncake iceberg warehouse + temp dir (volume-mount in production).
ENV MOONCAKE_WAREHOUSE=/var/lib/ivorysql/mooncake
RUN mkdir -p "${MOONCAKE_WAREHOUSE}" /tmp/moonlink_temp_file \
 && chmod 0777 "${MOONCAKE_WAREHOUSE}" /tmp/moonlink_temp_file

# ---------- env -> postgresql.conf shim ----------
# Translate IVY_* environment variables into PG GUC settings at container
# start time. Lets users toggle pg_mooncake.* GUCs (and any future setting
# we expose) via plain `-e KEY=VAL` without rebuilding the image or editing
# postgresql.conf on a bind mount.
#
# Two trigger points:
#   1. ivy-entrypoint-shim.sh runs on every container start before exec'ing
#      the base entrypoint. It applies env -> conf if postgresql.conf exists
#      (i.e. PGDATA already initialized).
#   2. /docker-entrypoint-initdb.d/00-ivy-apply-env.sh runs after the base
#      entrypoint's initdb on first start (when postgresql.conf is freshly
#      created). It calls the same logic so the first start also honors
#      env vars.
RUN set -eux; \
    cat > /usr/local/bin/ivy-apply-env.sh <<'APPLY'
#!/usr/bin/env bash
# Idempotently apply IVY_* env vars to $PGDATA/postgresql.conf.
# Safe to call repeatedly; replaces existing key with new value.
set -euo pipefail

CONF="${PGDATA:-/var/local/ivorysql/ivorysql-5/data}/postgresql.conf"
[ -f "$CONF" ] || exit 0  # PGDATA not initialized yet, nothing to do

apply() {
    local key="$1" val="$2"
    # Drop any prior value (commented or active), append fresh
    sed -i "\\|^[[:space:]]*${key}[[:space:]]*=|d" "$CONF"
    echo "${key} = ${val}" >> "$CONF"
    echo "ivy-apply-env: ${key} = ${val}" >&2
}

[ -n "${IVY_MOONCAKE_ENABLE_BGWORKER:-}" ] && \
    apply pg_mooncake.enable_bgworker "${IVY_MOONCAKE_ENABLE_BGWORKER}"
# Add further IVY_* -> GUC mappings here as new tunables surface.

exit 0
APPLY
RUN set -eux; \
    cat > /usr/local/bin/ivy-entrypoint-shim.sh <<'SHIM'
#!/usr/bin/env bash
set -e
/usr/local/bin/ivy-apply-env.sh
exec /usr/local/bin/docker-entrypoint.sh "$@"
SHIM
RUN set -eux; \
    mkdir -p /docker-entrypoint-initdb.d; \
    cat > /docker-entrypoint-initdb.d/00-ivy-apply-env.sh <<'INITDB'
#!/usr/bin/env bash
# Runs after the base entrypoint's initdb on first container start.
/usr/local/bin/ivy-apply-env.sh
INITDB
RUN set -eux; \
    chmod 0755 /usr/local/bin/ivy-apply-env.sh \
               /usr/local/bin/ivy-entrypoint-shim.sh \
               /docker-entrypoint-initdb.d/00-ivy-apply-env.sh

ENTRYPOINT ["/usr/local/bin/ivy-entrypoint-shim.sh"]
CMD ["postgres"]

# Switch back to the highgo image's runtime user.
# Adjust if your base uses a different uid/name.
USER ivorysql
