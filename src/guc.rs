// Custom GUCs registered by pg_mooncake.
//
// Postmaster context: changes only take effect on PG restart. This is
// required for `enable_bgworker` because RegisterBackgroundWorker can only
// be called from `_PG_init` running during shared_preload_libraries load.

use pgrx::{GucContext, GucFlags, GucRegistry, GucSetting};

/// `pg_mooncake.enable_bgworker` — controls whether the moonlink background
/// worker is registered at postmaster startup.
///
/// `on` (default): register and start moonlink, enabling mirror tables.
/// `off`: skip registration; pg_mooncake.so still loads but no bgworker
/// runs. Mirror functions error out, but pg_duckdb-only queries (external
/// data sources, postgres_scan, etc.) keep working.
pub(crate) static ENABLE_BGWORKER: GucSetting<bool> = GucSetting::<bool>::new(true);

pub(crate) fn init() {
    GucRegistry::define_bool_guc(
        c"pg_mooncake.enable_bgworker",
        c"Whether to start the moonlink background worker",
        c"If off, pg_mooncake loads without registering the moonlink \
          background worker. Mirror tables will not function; \
          pg_duckdb-only queries still work. Takes effect on PG restart \
          (Postmaster context).",
        &ENABLE_BGWORKER,
        GucContext::Postmaster,
        GucFlags::default(),
    );
}
