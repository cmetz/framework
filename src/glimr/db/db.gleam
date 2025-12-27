//// ------------------------------------------------------------
//// Database Utilities
//// ------------------------------------------------------------
////
//// High-level database utilities including transaction support
//// with automatic retry on deadlock.
////

import dot_env/env
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import glimr/db/connection.{
  type Connection, type DbError, ConnectionError, Postgres, QueryError, Sqlite,
}
import glimr/db/pool.{type Pool}
import glimr/db/query

// ------------------------------------------------------------- Public Functions

/// ------------------------------------------------------------
/// Load Config
/// ------------------------------------------------------------
///
/// Builds database configuration from environment variables.
/// Reads DB_DRIVER and DB_POOL_SIZE from the environment.
///
/// For PostgreSQL, uses DB_URL if set, otherwise uses individual
/// parameters: DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME,
/// DB_PASSWORD.
///
/// For SQLite, DB_DATABASE is preferred but DB_PATH is supported
/// for backward compatibility.
///
pub fn load_config() -> connection.Config {
  let assert Ok(driver) = env.get_string("DB_DRIVER")
  let pool_size = env.get_int("DB_POOL_SIZE") |> result.unwrap(15)

  case driver {
    "postgres" -> load_postgres_config(pool_size)
    "sqlite" -> load_sqlite_config(pool_size)
    _ -> panic as "Please specify a valid DB_DRIVER in your .env file."
  }
}

/// ------------------------------------------------------------
/// Load Postgres Config
/// ------------------------------------------------------------
///
/// Loads PostgreSQL configuration from environment variables.
/// Tries DB_URL first, falls back to individual parameters.
///
fn load_postgres_config(pool_size: Int) -> connection.Config {
  case env.get_string("DB_URL") {
    Ok(url) -> connection.postgres_config(url, pool_size: pool_size)
    Error(_) -> {
      // Use individual parameters
      let assert Ok(host) = env.get_string("DB_HOST")
      let port = env.get_int("DB_PORT") |> result.unwrap(5432)
      let assert Ok(database) = env.get_string("DB_DATABASE")
      let assert Ok(username) = env.get_string("DB_USERNAME")
      let password = case env.get_string("DB_PASSWORD") {
        Ok(pw) -> Some(pw)
        Error(_) -> None
      }
      connection.postgres_params_config(
        host: host,
        port: port,
        database: database,
        username: username,
        password: password,
        pool_size: pool_size,
      )
    }
  }
}

/// ------------------------------------------------------------
/// Load SQLite Config
/// ------------------------------------------------------------
///
/// Loads SQLite configuration from environment variables.
/// Tries DB_DATABASE first, falls back to DB_PATH.
///
fn load_sqlite_config(pool_size: Int) -> connection.Config {
  let path = case env.get_string("DB_DATABASE") {
    Ok(p) -> p
    Error(_) -> {
      let assert Ok(p) = env.get_string("DB_PATH")
      p
    }
  }
  connection.sqlite_config(path, pool_size: pool_size)
}

/// ------------------------------------------------------------
/// Transaction
/// ------------------------------------------------------------
///
/// Executes a function within a database transaction. The 
/// connection is automatically checked out from the pool, and 
/// the transaction is committed on success or rolled back on 
/// error.
///
/// The `retries` parameter controls retry behavior for deadlocks:
/// - 0 = no retries (try once, fail on error)
/// - 3 = retry up to 3 times on deadlock (4 total attempts)
///
/// ------------------------------------------------------------
///
/// *Example:*
///
/// ```gleam
/// db.transaction(pool, fn(conn) {
///   use _ <- account_repository.debit(conn, from_id, amount)
///   use _ <- account_repository.credit(conn, to_id, amount)
///   Ok(Nil)
/// }, 3)
/// ```
///
pub fn transaction(
  pool: Pool,
  retries: Int,
  callback: fn(Connection) -> Result(a, DbError),
) -> Result(a, DbError) {
  case retries < 0 {
    True -> Error(ConnectionError("Transaction retries cannot be negative"))
    False -> do_transaction(pool, retries, callback)
  }
}

// ------------------------------------------------------------- Private Functions

/// ------------------------------------------------------------
/// Do Transaction
/// ------------------------------------------------------------
///
/// Executes a transaction with the specified retry count. 
/// Checks out a connection, begins a transaction, runs the 
/// callback, and either commits on success or rolls back on 
/// error. On deadlock, delegates to `maybe_retry` for potential 
/// retry.
///
fn do_transaction(
  pool: Pool,
  retries_remaining: Int,
  callback: fn(Connection) -> Result(a, DbError),
) -> Result(a, DbError) {
  case pool.checkout(pool) {
    Error(e) -> Error(e)
    Ok(conn) -> {
      let begin_sql = begin_statement(conn)
      case query.execute(conn, begin_sql, []) {
        Error(e) -> {
          pool.checkin(pool, conn)
          Error(e)
        }
        Ok(_) -> {
          case callback(conn) {
            Ok(value) -> {
              // Commit on success
              case query.execute(conn, "COMMIT", []) {
                Ok(_) -> {
                  pool.checkin(pool, conn)
                  Ok(value)
                }
                Error(e) -> {
                  // Try to rollback if commit fails
                  let _ = query.execute(conn, "ROLLBACK", [])
                  pool.checkin(pool, conn)
                  maybe_retry(pool, retries_remaining, callback, e)
                }
              }
            }
            Error(e) -> {
              // Rollback on error
              let _ = query.execute(conn, "ROLLBACK", [])
              pool.checkin(pool, conn)
              maybe_retry(pool, retries_remaining, callback, e)
            }
          }
        }
      }
    }
  }
}

/// ------------------------------------------------------------
/// Maybe Retry
/// ------------------------------------------------------------
///
/// Checks if an error is a deadlock and retries are remaining.
/// If so, waits with exponential backoff (50ms * retry number)
/// and retries the transaction. Otherwise, returns the error.
///
fn maybe_retry(
  pool: Pool,
  retries_remaining: Int,
  callback: fn(Connection) -> Result(a, DbError),
  error: DbError,
) -> Result(a, DbError) {
  case is_deadlock_error(error) && retries_remaining > 0 {
    True -> {
      // Backoff: 50ms * retry number
      process.sleep(50 * retries_remaining)
      do_transaction(pool, retries_remaining - 1, callback)
    }
    False -> Error(error)
  }
}

/// ------------------------------------------------------------
/// Begin Statement
/// ------------------------------------------------------------
///
/// Returns the appropriate BEGIN statement for the database 
/// driver. PostgreSQL uses "BEGIN", SQLite uses 
/// "BEGIN TRANSACTION".
///
fn begin_statement(conn: Connection) -> String {
  case connection.driver(conn) {
    Postgres -> "BEGIN"
    Sqlite -> "BEGIN TRANSACTION"
  }
}

/// ------------------------------------------------------------
/// Is Deadlock Error
/// ------------------------------------------------------------
///
/// Checks if an error indicates a deadlock or lock contention.
/// Looks for PostgreSQL's "deadlock detected" message or 
/// SQLite's "database is locked" / "busy" messages.
///
fn is_deadlock_error(error: DbError) -> Bool {
  case error {
    QueryError(msg) -> {
      let lower = string.lowercase(msg)
      string.contains(lower, "deadlock")
      || string.contains(lower, "database is locked")
      || string.contains(lower, "busy")
    }
    _ -> False
  }
}
