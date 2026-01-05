//// Run Database Fresh Action
////
//// Drops all tables and re-runs all migrations from scratch.
//// Handles both SQLite and PostgreSQL databases with driver-
//// specific drop logic.

import gleam/dynamic/decode
import gleam/list
import gleam/string
import glimr/console/console
import glimr/db/pool_connection.{type PoolConnection}
import glimr/db/query
import glimr/internal/actions/run_db_migrate

/// Drops all tables and re-runs all migrations.
///
pub fn run(connection: PoolConnection, database: String) -> Nil {
  // Drop tables based on driver type
  let drop_result = case pool_connection.driver(connection) {
    pool_connection.Sqlite -> drop_sqlite_tables(connection)
    pool_connection.Postgres -> drop_postgres_tables(connection)
  }

  case drop_result {
    Error(err) -> {
      console.output()
      |> console.line_error("Failed to drop tables:")
      |> console.line(string.inspect(err))
      |> console.print()
    }
    Ok(_) -> {
      console.output()
      |> console.blank_line()
      |> console.line_success("Tables dropped.")
      |> console.unpadded()
      |> console.print()

      // Now run migrations
      run_db_migrate.run(connection, database)
    }
  }
}

/// Drops all user tables from a SQLite database by querying
/// sqlite_master and dropping each table individually.
///
fn drop_sqlite_tables(
  connection: PoolConnection,
) -> Result(Nil, pool_connection.DbError) {
  let tables_sql =
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
  let decoder = {
    use name <- decode.field(0, decode.string)
    decode.success(name)
  }
  case query.select_all(connection, tables_sql, [], decoder) {
    Ok(tables) -> {
      list.each(tables, fn(table) {
        let drop_sql = "DROP TABLE IF EXISTS \"" <> table <> "\""
        let _ = query.execute(connection, drop_sql, [])
        Nil
      })
      Ok(Nil)
    }
    Error(_) -> Ok(Nil)
  }
}

/// Drops all tables in the PostgreSQL public schema using a
/// DO block to iterate and drop each table with CASCADE.
///
fn drop_postgres_tables(
  connection: PoolConnection,
) -> Result(Nil, pool_connection.DbError) {
  let sql =
    "DO $$ DECLARE
      r RECORD;
    BEGIN
      FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE';
      END LOOP;
    END $$;"
  case query.execute(connection, sql, []) {
    Ok(_) -> Ok(Nil)
    Error(err) -> Error(err)
  }
}
