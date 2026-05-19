<div align=center>
<h1 align=center>ivy_mooncake 🥮</h1>
<h4 align=center>Real-time analytics on Postgres tables (IvorySQL distribution)</h4>

[![][docs-shield]][docs-link]
[![][license-shield]][license-link]
</div>

## Overview

**ivy_mooncake** is the IvorySQL distribution of [pg_mooncake][upstream-link], a Postgres extension that creates a columnstore mirror of your Postgres tables in [Iceberg][iceberg-link], enabling fast analytics queries with sub-second freshness:
- **Real-time ingestion** powered by [moonlink][moonlink-link] for streaming and batched INSERT/UPDATE/DELETE.
- **Fast analytics** accelerated by [DuckDB][pgduckdb-link], ranking top 10 on [ClickBench][clickbench-link].
- **Postgres-native** allowing you to query a columnstore table just like a regular Postgres table.
- **Iceberg-native** making your data readily accessible by other query engines.

This fork tracks IvorySQL-maintained branches of `pg_duckdb`, `moonlink`, and `duckdb_mooncake` (`ivy_duckdb`, `ivy_moonlink`, `ivy_duckdb_mooncake`). The repository name is `ivy_mooncake`, but the extension it installs is unchanged — `pg_mooncake` — so SQL-side compatibility with upstream is preserved.

## Installation

To build ivy_mooncake, first install [Rust][rust-install], [pgrx][pgrx-install], and [the build tools for DuckDB][duckdb-install].

Then, clone the repository with submodules:
```bash
git clone --recurse-submodules https://github.com/IvorySQL/ivy_mooncake.git
```

To build and install for Postgres versions 14-18, run:
```bash
cargo pgrx init --pg18=$(which pg_config)   # Replace with your Postgres version
make ivy_duckdb                             # Skip if ivy_duckdb is already installed
make install PG_VERSION=pg18
```

Finally, add `pg_mooncake` to `shared_preload_libraries` in your `postgresql.conf` file and enable logical replication:
```ini
duckdb.allow_community_extensions = true
shared_preload_libraries = 'pg_duckdb,pg_mooncake'
wal_level = logical
```

## Quick Start

First, create the pg_mooncake extension:
```sql
CREATE EXTENSION pg_mooncake CASCADE;
```

Next, create a regular Postgres table `trades`:
```sql
CREATE TABLE trades(
  id bigint PRIMARY KEY,
  symbol text,
  time timestamp,
  price real
);
```

Then, create a columnstore mirror `trades_iceberg` that stays in sync with `trades`:
```sql
CALL mooncake.create_table('trades_iceberg', 'trades');
```

Now, insert some data into `trades`:
```sql
INSERT INTO trades VALUES
  (1,  'AMD', '2024-06-05 10:00:00', 119),
  (2, 'AMZN', '2024-06-05 10:05:00', 207),
  (3, 'AAPL', '2024-06-05 10:10:00', 203),
  (4, 'AMZN', '2024-06-05 10:15:00', 210);
```

Finally, query `trades_iceberg` to see that it reflects the up-to-date state of `trades`:
```sql
SELECT avg(price) FROM trades_iceberg WHERE symbol = 'AMZN';
```

Note: The repository is renamed to `ivy_mooncake` only at the GitHub-fork level. Inside the repo, the extension, the cdylib, and all SQL-level identifiers (`pg_mooncake` extension, `mooncake.*` schema, `USING mooncake` access method, `INSTALL mooncake FROM community`) are intentionally unchanged from upstream so SQL written against `pg_mooncake` continues to work.

## Upstream

ivy_mooncake is a fork of [Mooncake-Labs/pg_mooncake][upstream-link] under the [MIT License][license-link].

[clickbench-link]: https://www.mooncake.dev/blog/clickbench-v0.1
[docs-link]: https://docs.mooncake.dev/
[docs-shield]: https://img.shields.io/badge/docs-mooncake?logo=readthedocs&logoColor=white
[duckdb-install]: https://duckdb.org/docs/stable/dev/building/overview.html#prerequisites
[iceberg-link]: https://iceberg.apache.org/
[license-link]: ./LICENSE
[license-shield]: https://img.shields.io/badge/License-MIT-blue
[moonlink-link]: https://github.com/IvorySQL/ivy_moonlink
[pgduckdb-link]: https://github.com/IvorySQL/ivy_duckdb
[pgrx-install]: https://github.com/pgcentralfoundation/pgrx?tab=readme-ov-file#getting-started
[rust-install]: https://www.rust-lang.org/tools/install
[upstream-link]: https://github.com/Mooncake-Labs/pg_mooncake
