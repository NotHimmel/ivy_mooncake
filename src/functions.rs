use crate::utils::{block_on, get_stream, DATABASE};
use core::ffi::CStr;
use native_tls::TlsConnector;
use pgrx::{direct_function_call, prelude::*};
use postgres::Client;
use postgres_native_tls::MakeTlsConnector;
use regex::Regex;

#[pg_extern(sql = "
CREATE PROCEDURE mooncake.create_snapshot(dst text) LANGUAGE c AS 'MODULE_PATHNAME', '@FUNCTION_NAME@';
")]
fn create_snapshot(dst: &str) {
    let dst = parse_table(dst);
    let lsn = unsafe { pgrx::pg_sys::XactLastCommitEnd };
    block_on(moonlink_rpc::create_snapshot(
        &mut *get_stream(),
        DATABASE.clone(),
        dst,
        lsn,
    ))
    .expect("create_snapshot failed");
}

#[pg_extern(sql = "
CREATE PROCEDURE mooncake.create_table(dst text, src text, src_uri text DEFAULT NULL, table_config json DEFAULT NULL) LANGUAGE c AS 'MODULE_PATHNAME', '@FUNCTION_NAME@';
")]
fn create_table(dst: &str, src: &str, src_uri: Option<&str>, table_config: Option<&str>) {
    let dst = parse_table(dst);
    let src = parse_table(src);
    let dst_uri = get_loopback_uri();
    let src_uri = src_uri.unwrap_or(&dst_uri).to_owned();
    create_mooncake_table(&dst, &dst_uri, &src, &src_uri);
    let table_config = table_config.unwrap_or("{}").to_owned();
    block_on(moonlink_rpc::create_table(
        &mut *get_stream(),
        DATABASE.clone(),
        dst,
        src,
        src_uri,
        table_config,
    ))
    .expect("create_table failed");
}

#[pg_extern(sql = "
CREATE FUNCTION mooncake_drop_trigger() RETURNS event_trigger LANGUAGE c AS 'MODULE_PATHNAME', '@FUNCTION_NAME@';
CREATE EVENT TRIGGER mooncake_drop_trigger ON sql_drop EXECUTE FUNCTION mooncake_drop_trigger();
")]
fn drop_trigger() {
    Spi::connect(|client| {
        let get_dropped_tables_query =
            "SELECT quote_ident(schema_name) || '.' || quote_ident(object_name) FROM pg_event_trigger_dropped_objects() WHERE object_type = 'table'";
        let dropped_tables = client
            .select(get_dropped_tables_query, None, &[])
            .expect("error reading dropped objects");
        for dropped_table in dropped_tables {
            let table: String = dropped_table
                .get(1)
                .expect("error reading dropped table")
                .expect("error reading dropped table");
            {
                let table = table.clone();
                pgrx::register_xact_callback(pgrx::PgXactCallbackEvent::PreCommit, move || {
                    block_on(moonlink_rpc::drop_table(
                        &mut *get_stream(),
                        DATABASE.clone(),
                        table,
                    ))
                    .expect("drop_table failed");
                });
            }
            pgrx::register_xact_callback(pgrx::PgXactCallbackEvent::ParallelPreCommit, move || {
                block_on(moonlink_rpc::drop_table(
                    &mut *get_stream(),
                    DATABASE.clone(),
                    table,
                ))
                .expect("drop_table failed");
            });
        }
    });
}

#[pg_extern(sql = "
CREATE FUNCTION mooncake.list_tables() RETURNS TABLE (
    \"table\" text,
    commit_lsn pg_lsn,
    flush_lsn pg_lsn,
    iceberg_warehouse_location text
) LANGUAGE c AS 'MODULE_PATHNAME', '@FUNCTION_NAME@';
")]
fn list_tables() -> TableIterator<
    'static,
    (
        name!(table, String),
        name!(commit_lsn, i64),
        name!(flush_lsn, Option<i64>),
        name!(iceberg_warehouse_location, String),
    ),
> {
    let tables =
        block_on(moonlink_rpc::list_tables(&mut *get_stream())).expect("list_tables failed");
    TableIterator::new(
        tables
            .into_iter()
            .filter(|table| table.database == *DATABASE)
            .map(|table| {
                (
                    table.table,
                    table.commit_lsn as i64,
                    table.flush_lsn.map(|lsn| lsn as i64),
                    table.iceberg_warehouse_location,
                )
            }),
    )
}

#[pg_extern(sql = "
CREATE PROCEDURE mooncake.load_files(dst text, files text[]) LANGUAGE c AS 'MODULE_PATHNAME', '@FUNCTION_NAME@';
")]
fn load_files(dst: &str, files: Vec<String>) {
    let dst = parse_table(dst);
    block_on(moonlink_rpc::load_files(
        &mut *get_stream(),
        DATABASE.clone(),
        dst,
        files,
    ))
    .expect("load_files failed");
}

#[pg_extern(sql = "
CREATE PROCEDURE mooncake.optimize_table(dst text, mode text) LANGUAGE c AS 'MODULE_PATHNAME', '@FUNCTION_NAME@';
")]
fn optimize_table(dst: &str, mode: &str) {
    let dst = parse_table(dst);
    block_on(moonlink_rpc::optimize_table(
        &mut *get_stream(),
        DATABASE.clone(),
        dst,
        mode.to_owned(),
    ))
    .expect("optimize_table failed");
}

fn parse_table(table: &str) -> String {
    // https://www.postgresql.org/docs/current/sql-syntax-lexical.html#SQL-SYNTAX-IDENTIFIERS
    let ident = r#"([\w$]+|"([^"]|"")+")"#;
    let pattern = format!(r#"^((?<schema>{ident})\.)?(?<table>{ident})$"#);
    let re = Regex::new(&pattern).unwrap();
    let caps = re
        .captures(table)
        .unwrap_or_else(|| panic!("invalid input: {table}"));
    let schema = caps.name("schema").map_or_else(
        || {
            let schema: &CStr =
                unsafe { direct_function_call(pg_sys::current_schema, &[]).unwrap() };
            schema.to_str().unwrap()
        },
        |m| m.as_str(),
    );
    spi::quote_qualified_identifier(schema, &caps["table"])
}

fn get_loopback_uri() -> String {
    let hosts = unsafe { CStr::from_ptr(pg_sys::Unix_socket_directories) };
    let host = hosts.to_str().unwrap().split(",").next().unwrap().trim();
    let port: i32 = unsafe { pg_sys::PostPortNumber };
    let user = unsafe { CStr::from_ptr(pg_sys::GetUserNameFromId(pg_sys::GetUserId(), false)) };
    let user = user.to_str().unwrap();
    format!(
        "postgresql:///{}?host={}&port={port}&user={}",
        uri_encode(&DATABASE),
        uri_encode(host),
        uri_encode(user)
    )
}

fn uri_encode(input: &str) -> String {
    // https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
    const HEX_DIGITS: &[u8; 16] = b"0123456789ABCDEF";
    let mut result = String::with_capacity(input.len() * 3);
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                result.push(byte as char)
            }
            _ => {
                result.push('%');
                result.push(HEX_DIGITS[(byte >> 4) as usize] as char);
                result.push(HEX_DIGITS[(byte & 15) as usize] as char);
            }
        }
    }
    result
}

fn create_mooncake_table(dst: &str, dst_uri: &str, src: &str, src_uri: &str) {
    let tls_connector = TlsConnector::new().expect("error creating tls connector");
    let make_tls_connector = MakeTlsConnector::new(tls_connector);
    let mut client = Client::connect(src_uri, make_tls_connector.clone())
        .unwrap_or_else(|_| panic!("error connecting to server: {src_uri}"));

    let get_columns_query = format!(
        "SELECT string_agg(
                format(
                '%I %s%s',
                attname,
                format_type(atttypid, atttypmod),
                CASE WHEN attnotnull THEN ' NOT NULL' ELSE '' END
            ),
            ', ' ORDER BY attnum
        )
        FROM pg_attribute
        WHERE attrelid = '{}'::regclass::oid AND attnum > 0 AND NOT attisdropped",
        src.replace("'", "''")
    );
    let columns: String = client
        .query_one(&get_columns_query, &[])
        .unwrap_or_else(|_| panic!("relation does not exist: {src}"))
        .get(0);

    if dst_uri != src_uri {
        client = Client::connect(dst_uri, make_tls_connector)
            .unwrap_or_else(|_| panic!("error connecting to server: {dst_uri}"));
    }

    let create_table_query = format!("CREATE TABLE {dst} ({columns}) USING mooncake");
    client
        .simple_query(&create_table_query)
        .unwrap_or_else(|_| panic!("error creating table: {dst}"));
}

/// Diagnostic helper for moonlink bgworker liveness.
///
/// Returns a JSON object combining the GUC value with filesystem-level
/// evidence of whether the bgworker is actually running. Useful when
/// `SHOW pg_mooncake.enable_bgworker` reports `on` but mirror operations
/// still fail because the bgworker died or never bound the socket.
#[cfg(feature = "bgworker")]
#[pg_extern(sql = "
CREATE FUNCTION mooncake.bgworker_status() RETURNS json LANGUAGE c AS 'MODULE_PATHNAME', '@FUNCTION_NAME@';
")]
fn bgworker_status() -> pgrx::Json {
    use std::os::unix::net::UnixStream as StdUnixStream;
    use std::path::Path;
    use std::time::Duration;

    let guc_enabled = crate::guc::ENABLE_BGWORKER.get();

    // Same relative path as utils::get_stream() — resolved against the PG
    // process working directory, which is $PGDATA at runtime.
    let socket_path = "pg_mooncake/moonlink.sock";

    let socket_exists = Path::new(socket_path).exists();

    // Probe connect with a tight timeout so we never block PG backend on
    // a hung socket. `connect_timeout` is on `SocketAddr` for std streams
    // but UnixStream needs the raw socket(2)+connect(2) sequence; a plain
    // `connect()` returns immediately for Unix sockets either way (no
    // resolution / handshake), so we just check the result.
    let socket_listening = if socket_exists {
        // Wrap in a thread so a misbehaving server doesn't block us.
        // For Unix sockets `connect()` itself doesn't block on protocol,
        // so this is just defense-in-depth.
        let path = socket_path.to_string();
        let handle = std::thread::spawn(move || StdUnixStream::connect(&path).is_ok());
        // 250ms ceiling, then give up if probe stalled.
        let start = std::time::Instant::now();
        loop {
            if handle.is_finished() {
                break handle.join().unwrap_or(false);
            }
            if start.elapsed() > Duration::from_millis(250) {
                break false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    } else {
        false
    };

    pgrx::Json(serde_json::json!({
        "guc_enabled": guc_enabled,
        "socket_path": socket_path,
        "socket_exists": socket_exists,
        "socket_listening": socket_listening,
    }))
}

/// Enumerate moonlink_slot_* replication slots and flag orphans.
///
/// A slot is considered orphan when:
/// - it lives in the current database, AND
/// - that database has zero tables using the mooncake table access method
///   (so no mirror table could possibly reference it).
///
/// Slots belonging to other databases are reported with NULL counts and
/// is_orphan=false because their mooncake AM table count is not visible
/// from this connection.
///
/// Usage:
///   SELECT * FROM mooncake.list_orphan_slots();
///   SELECT * FROM mooncake.list_orphan_slots() WHERE is_orphan;
///
/// Pair with `SELECT pg_drop_replication_slot(slot_name) ...` to clean up.
#[pg_extern(sql = "
CREATE FUNCTION mooncake.list_orphan_slots() RETURNS TABLE(
    slot_name text,
    slot_database text,
    mirror_tables_count integer,
    is_orphan boolean
) LANGUAGE c AS 'MODULE_PATHNAME', '@FUNCTION_NAME@';
")]
fn list_orphan_slots() -> TableIterator<
    'static,
    (
        name!(slot_name, String),
        name!(slot_database, Option<String>),
        name!(mirror_tables_count, Option<i32>),
        name!(is_orphan, bool),
    ),
> {
    let rows: Vec<(String, Option<String>, Option<i32>, bool)> = Spi::connect(|client| {
        let q = "
            WITH local_mooncake_count AS (
                SELECT count(*)::int AS cnt
                FROM pg_class c
                JOIN pg_am a ON c.relam = a.oid
                WHERE a.amname = 'mooncake'
            )
            SELECT
                s.slot_name::text AS slot_name,
                s.database::text AS slot_database,
                CASE WHEN s.database = current_database()
                     THEN lm.cnt
                     ELSE NULL
                END AS mirror_tables_count,
                CASE WHEN s.database = current_database() AND lm.cnt = 0
                     THEN true
                     ELSE false
                END AS is_orphan
            FROM pg_replication_slots s
            CROSS JOIN local_mooncake_count lm
            WHERE s.slot_name LIKE 'moonlink_slot_%'
            ORDER BY s.slot_name
        ";

        client
            .select(q, None, &[])
            .expect("error querying moonlink slots")
            .map(|row| {
                let slot_name: String = row
                    .get(1)
                    .expect("error reading slot_name")
                    .expect("slot_name is null");
                let slot_database: Option<String> =
                    row.get(2).expect("error reading slot_database");
                let mirror_tables_count: Option<i32> =
                    row.get(3).expect("error reading mirror_tables_count");
                let is_orphan: bool = row
                    .get(4)
                    .expect("error reading is_orphan")
                    .unwrap_or(false);
                (slot_name, slot_database, mirror_tables_count, is_orphan)
            })
            .collect()
    });

    TableIterator::new(rows.into_iter())
}

/// Force-drop orphan moonlink replication slots in the current database.
///
/// For each `moonlink_slot_*` whose database is the current database AND
/// the database has zero mooncake-AM tables:
///   1. Terminate the active client (if any) via pg_terminate_backend,
///      since pg_drop_replication_slot refuses to drop an active slot.
///   2. Drop the slot via pg_drop_replication_slot.
///   3. After processing slots, drop `moonlink_pub` if it still exists
///      and there are no mooncake tables remaining (best-effort, ignored
///      on failure).
///
/// Intended use: right after `CREATE EXTENSION pg_mooncake CASCADE` on a
/// database where a prior install left behind orphan slots. Calling this
/// before the moonlink bgworker has a chance to attach to the old slot
/// avoids the recovery panic loop.
///
/// Returns one row per slot acted on. The `publication_dropped` column
/// is true only on the LAST row, reflecting whether moonlink_pub was
/// also cleaned. If no orphans existed but the publication did, a single
/// synthetic row with empty `slot_name` is emitted.
#[pg_extern(sql = "
CREATE FUNCTION mooncake.drop_orphan_slots() RETURNS TABLE(
    slot_name text,
    terminated_active_pid integer,
    publication_dropped boolean
) LANGUAGE c AS 'MODULE_PATHNAME', '@FUNCTION_NAME@';
")]
fn drop_orphan_slots() -> TableIterator<
    'static,
    (
        name!(slot_name, String),
        name!(terminated_active_pid, Option<i32>),
        name!(publication_dropped, bool),
    ),
> {
    let rows: Vec<(String, Option<i32>, bool)> = Spi::connect_mut(|client| {
        // 1) Decide whether this database has any mooncake-AM tables.
        let no_mooncake_tables: bool = client
            .select(
                "SELECT count(*)::int = 0
                 FROM pg_class c JOIN pg_am a ON c.relam = a.oid
                 WHERE a.amname = 'mooncake'",
                None,
                &[],
            )
            .expect("checking mooncake tables")
            .first()
            .get::<bool>(1)
            .expect("reading no_mooncake_tables")
            .unwrap_or(false);

        // 2) Pull the orphan slot list with active_pid for termination.
        let orphans: Vec<(String, Option<i32>)> = if no_mooncake_tables {
            client
                .select(
                    "SELECT slot_name::text, active_pid
                     FROM pg_replication_slots
                     WHERE slot_name LIKE 'moonlink_slot_%'
                       AND database = current_database()",
                    None,
                    &[],
                )
                .expect("listing orphan slots")
                .map(|row| {
                    let name: String = row
                        .get(1)
                        .expect("reading slot_name")
                        .expect("slot_name is null");
                    let active_pid: Option<i32> = row.get(2).expect("reading active_pid");
                    (name, active_pid)
                })
                .collect()
        } else {
            // Database still has mooncake tables — refuse to nuke slots.
            Vec::new()
        };

        let mut out: Vec<(String, Option<i32>, bool)> = Vec::new();
        let total = orphans.len();

        for (i, (slot, active_pid)) in orphans.into_iter().enumerate() {
            // Terminate the active replication client first if needed.
            if let Some(pid) = active_pid {
                let _ = client.update(
                    &format!("SELECT pg_terminate_backend({pid})"),
                    None,
                    &[],
                );
            }

            // Drop the slot. Use quote_literal-style format to avoid SQL
            // injection — slot_name is constrained by the LIKE filter, but
            // be defensive in case someone wedges a weird identifier.
            let drop_sql = format!(
                "SELECT pg_drop_replication_slot({})",
                quote_string_literal(&slot),
            );
            if let Err(e) = client.update(&drop_sql, None, &[]) {
                pgrx::warning!("failed to drop slot {}: {}", slot, e);
            }

            // On the last orphan, also drop the publication if it exists
            // (only safe when no mooncake tables remain, which is already
            // implied by no_mooncake_tables=true).
            let is_last = i == total - 1;
            let publication_dropped = if is_last {
                attempt_drop_publication(client)
            } else {
                false
            };

            out.push((slot, active_pid, publication_dropped));
        }

        // Edge case: no orphan slots but publication still lingers.
        if out.is_empty() && no_mooncake_tables {
            if attempt_drop_publication(client) {
                out.push((String::new(), None, true));
            }
        }

        out
    });

    TableIterator::new(rows.into_iter())
}

/// Helper: drop `moonlink_pub` if present; return whether it was dropped.
fn attempt_drop_publication(client: &mut pgrx::spi::SpiClient<'_>) -> bool {
    let exists: bool = client
        .select(
            "SELECT count(*)::int > 0 FROM pg_publication WHERE pubname = 'moonlink_pub'",
            None,
            &[],
        )
        .map(|t| {
            t.first()
                .get::<bool>(1)
                .ok()
                .flatten()
                .unwrap_or(false)
        })
        .unwrap_or(false);

    if exists {
        if let Err(e) = client.update("DROP PUBLICATION IF EXISTS moonlink_pub", None, &[]) {
            pgrx::warning!("failed to drop publication moonlink_pub: {}", e);
            false
        } else {
            true
        }
    } else {
        false
    }
}

/// Minimal single-quote escaping for `pg_drop_replication_slot('<slot>')`.
fn quote_string_literal(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push('\'');
        }
        out.push(ch);
    }
    out.push('\'');
    out
}
