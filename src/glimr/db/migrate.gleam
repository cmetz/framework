//// Migration Runner
////
//// Manages database schema migrations for Glimr applications.
//// Migrations are SQL files stored in `src/data/_migrations/`
//// with timestamped filenames:
//// (e.g., `20251217120000_create_users.sql`).
////
//// Tracks applied migrations in the `_glimr_migrations` table
//// to ensure each migration runs only once.

import dot_env
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import glimr/db/db
import glimr/db/pool
import glimr/db/pool_connection.{type DbError, type PoolConnection}
import glimr/db/query
import simplifile

// ------------------------------------------------------------- Public Types

/// Represents a database migration loaded from a SQL file.
/// The version is extracted from the filename prefix
/// (timestamp), the name from the remainder of the filename,
/// and sql contains the migration statements to execute.
///
pub type Migration {
  Migration(version: String, name: String, sql: String)
}

/// Represents the status of a migration - whether it has been
/// applied to the database or is still pending.
///
pub type MigrationStatus {
  MigrationStatus(version: String, name: String, applied: Bool)
}

// ------------------------------------------------------------- Public Functions

/// Applies all pending migrations to the database. Creates the
/// migrations tracking table if it doesn't exist, then runs any
/// migrations that haven't been applied yet in version order.
///
/// The connection_name determines which migrations folder to use:
/// `src/data/{connection_name}/_migrations/`
///
/// Returns a list of version strings for successfully applied
/// migrations, or an error if any migration fails.
///
/// *Example:*
///
/// ```gleam
/// use connection <- pool.get_connection_or(pool)
/// case migrate.migrate(connection, "default") {
///   Ok(applied) -> io.println("Applied " <> int.to_string(list.length(applied)))
///   Error(err) -> io.println("Migration failed")
/// }
/// ```
///
pub fn migrate(
  connection: PoolConnection,
  connection_name: String,
) -> Result(List(String), DbError) {
  // Ensure migrations table exists
  case ensure_migrations_table(connection) {
    Ok(_) -> {
      // Get applied migrations
      case get_applied_migrations(connection) {
        Ok(applied) -> {
          // Get pending migrations
          case get_pending_migrations(applied, connection_name) {
            Ok(pending) -> {
              // Apply each pending migration
              apply_migrations(connection, pending, [])
            }
            Error(err) -> Error(err)
          }
        }
        Error(err) -> Error(err)
      }
    }
    Error(err) -> Error(err)
  }
}

/// Entry point for the migration CLI.
///
pub fn main() {
  run_migrate()
}

/// CLI command that applies all pending migrations. Loads
/// database configuration from environment variables, connects
/// to the database, and runs pending migrations.
///
/// Prints progress to stdout and exits cleanly.
///
pub fn run_migrate() {
  // Load .env file
  dot_env.load_default()

  io.println("Glimr Migration Runner")
  io.println("======================")

  // Build config from environment
  let config = db.load_config()

  case pool.start(config) {
    Ok(db_pool) -> {
      let result =
        pool.get_connection_or(db_pool, fn(connection) {
          migrate(connection, "default")
        })
      case result {
        Ok(applied) -> {
          case applied {
            [] -> io.println("No pending migrations.")
            _ -> {
              io.println(
                "Applied "
                <> int.to_string(list.length(applied))
                <> " migration(s):",
              )
              list.each(applied, fn(version) { io.println("  ✓ " <> version) })
            }
          }
        }
        Error(err) -> {
          io.println("Migration failed: " <> string.inspect(err))
        }
      }
      pool.stop(db_pool)
    }
    Error(err) -> {
      io.println("Failed to connect to database: " <> string.inspect(err))
    }
  }
}

/// CLI command that drops all tables and re-runs all migrations
/// from scratch. For SQLite, deletes the database file. For
/// PostgreSQL, drops all tables in the public schema.
///
/// Use this during development to reset the database to a clean
/// state. Do not use in production.
///
pub fn run_fresh() {
  // Load .env file
  dot_env.load_default()

  io.println("Glimr Database Fresh")
  io.println("====================")

  let config = db.load_config()

  // Drop the database
  let _ = case config {
    pool_connection.SqliteConfig(path, _) -> {
      io.println("Dropping database: " <> path)
      simplifile.delete(path)
    }
    pool_connection.PostgresConfig(_, _)
    | pool_connection.PostgresParamsConfig(_, _, _, _, _, _) -> {
      io.println("Dropping all tables...")
      case pool.start(config) {
        Ok(db_pool) -> {
          let _ =
            pool.get_connection_or(db_pool, fn(connection) {
              drop_all_tables(connection)
            })
          pool.stop(db_pool)
          Ok(Nil)
        }
        Error(_) -> Ok(Nil)
      }
    }
  }

  io.println("")

  // Run migrations
  case pool.start(config) {
    Ok(db_pool) -> {
      let result =
        pool.get_connection_or(db_pool, fn(connection) {
          migrate(connection, "default")
        })
      case result {
        Ok(applied) -> {
          io.println(
            "Applied "
            <> int.to_string(list.length(applied))
            <> " migration(s):",
          )
          list.each(applied, fn(version) { io.println("  ✓ " <> version) })
        }
        Error(err) -> {
          io.println("Migration failed: " <> string.inspect(err))
        }
      }
      pool.stop(db_pool)
    }
    Error(err) -> {
      io.println("Failed to connect to database: " <> string.inspect(err))
    }
  }
}

// ------------------------------------------------------------- Private Functions

/// Drops all tables in the PostgreSQL public schema. Used by
/// `run_fresh` to reset the database before re-running
/// migrations.
///
fn drop_all_tables(connection: PoolConnection) -> Result(Nil, DbError) {
  // For PostgreSQL, drop all tables in public schema
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

/// Creates the `_glimr_migrations` table if it doesn't exist.
/// Uses driver-appropriate column types for version and
/// timestamp.
///
fn ensure_migrations_table(connection: PoolConnection) -> Result(Nil, DbError) {
  let sql = case pool_connection.driver(connection) {
    pool_connection.Postgres -> {
      "CREATE TABLE IF NOT EXISTS _glimr_migrations (
        version VARCHAR(255) PRIMARY KEY,
        applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )"
    }
    pool_connection.Sqlite -> {
      "CREATE TABLE IF NOT EXISTS _glimr_migrations (
        version TEXT PRIMARY KEY,
        applied_at TEXT DEFAULT CURRENT_TIMESTAMP
      )"
    }
  }

  case query.execute(connection, sql, []) {
    Ok(_) -> Ok(Nil)
    Error(err) -> Error(err)
  }
}

/// Queries the `_glimr_migrations` table to get a list of all
/// migration versions that have already been applied, sorted
/// by version.
///
fn get_applied_migrations(
  connection: PoolConnection,
) -> Result(List(String), DbError) {
  let sql = "SELECT version FROM _glimr_migrations ORDER BY version"
  let decoder = {
    use version <- decode.field(0, decode.string)
    decode.success(version)
  }

  query.select_all(connection, sql, [], decoder)
}

/// Filters the list of all migrations to find those that
/// haven't been applied yet, sorted by version for correct
/// ordering.
///
fn get_pending_migrations(
  applied: List(String),
  connection_name: String,
) -> Result(List(Migration), DbError) {
  case load_all_migrations(connection_name) {
    Ok(all) -> {
      let pending =
        list.filter(all, fn(m) { !list.contains(applied, m.version) })
        |> list.sort(by: fn(a, b) { string.compare(a.version, b.version) })
      Ok(pending)
    }
    Error(err) -> Error(err)
  }
}

/// Reads all SQL files from `src/data/{connection}/_migrations/`
/// and parses them into Migration records. Creates the migrations
/// directory if it doesn't exist. Filenames must follow the
/// format `TIMESTAMP_name.sql`:
/// (e.g., `20251217120000_create_users.sql`).
///
fn load_all_migrations(
  connection_name: String,
) -> Result(List(Migration), DbError) {
  let migrations_path = "src/data/" <> connection_name <> "/_migrations"

  let _ = simplifile.create_directory_all(migrations_path)

  case simplifile.read_directory(migrations_path) {
    Ok(files) -> {
      let migrations =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".sql") })
        |> list.filter_map(fn(file) {
          let path = migrations_path <> "/" <> file
          case simplifile.read(path) {
            Ok(content) -> {
              // Parse filename: 20251217120000_create_users.sql
              let base = string.replace(file, ".sql", "")
              case string.split_once(base, "_") {
                Ok(#(version, name)) -> Ok(Migration(version, name, content))
                Error(_) -> Error(Nil)
              }
            }
            Error(_) -> Error(Nil)
          }
        })
        |> list.sort(by: fn(a, b) { string.compare(a.version, b.version) })

      Ok(migrations)
    }
    Error(_) -> Ok([])
  }
}

/// Recursively applies a list of pending migrations.
/// Accumulates successfully applied version strings and returns
/// them when complete. Stops on the first error.
///
fn apply_migrations(
  connection: PoolConnection,
  pending: List(Migration),
  applied: List(String),
) -> Result(List(String), DbError) {
  case pending {
    [] -> Ok(list.reverse(applied))
    [migration, ..rest] -> {
      case apply_single_migration(connection, migration) {
        Ok(_) ->
          apply_migrations(connection, rest, [migration.version, ..applied])
        Error(err) -> Error(err)
      }
    }
  }
}

/// Executes a single migration's SQL statements and records it
/// in the migrations table. Splits SQL by semicolons and
/// executes each statement individually.
///
fn apply_single_migration(
  connection: PoolConnection,
  migration: Migration,
) -> Result(Nil, DbError) {
  let sql = extract_sql_for_driver(migration.sql, connection)

  // Split SQL into individual statements and execute each
  let statements =
    sql
    |> string.split(";")
    |> list.map(string.trim)
    |> list.filter(fn(s) { s != "" })

  case execute_statements(connection, statements) {
    Ok(_) -> {
      let record_sql = "INSERT INTO _glimr_migrations (version) VALUES ($1)"
      case
        query.execute(connection, record_sql, [
          pool_connection.string(migration.version),
        ])
      {
        Ok(_) -> Ok(Nil)
        Error(err) -> Error(err)
      }
    }
    Error(err) -> Error(err)
  }
}

/// Recursively executes a list of SQL statements. Stops on the
/// first error, returning that error. Used to run multi-
/// statement migrations where each statement is separated by
/// semicolons.
///
fn execute_statements(
  connection: PoolConnection,
  statements: List(String),
) -> Result(Nil, DbError) {
  case statements {
    [] -> Ok(Nil)
    [stmt, ..rest] -> {
      case query.execute(connection, stmt, []) {
        Ok(_) -> execute_statements(connection, rest)
        Error(err) -> Error(err)
      }
    }
  }
}

/// Filters out comment lines from migration SQL. Migration
/// files are driver-specific, so this just removes lines
/// starting with `--` to clean up the SQL before execution.
///
fn extract_sql_for_driver(sql: String, _connection: PoolConnection) -> String {
  sql
  |> string.split("\n")
  |> list.filter(fn(line) {
    let trimmed = string.trim(line)
    !string.starts_with(trimmed, "--")
  })
  |> string.join("\n")
  |> string.trim()
}
