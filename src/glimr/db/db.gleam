//// Database Utilities
////
//// High-level database utilities including transaction support
//// with automatic retry on deadlock, and provider-based
//// configuration for multi-database support.

import dot_env/env
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import glimr/db/driver.{type Connection}
import glimr/db/pool.{type Pool}
import glimr/db/pool_connection.{
  type DbError, type PoolConnection, ConfigError, ConnectionError, Postgres,
  QueryError, Sqlite,
}
import glimr/db/query

// ------------------------------------------------------------- Public Functions

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
pub fn load_config() -> pool_connection.Config {
  let assert Ok(driver) = env.get_string("DB_DRIVER")
  let pool_size = env.get_int("DB_POOL_SIZE") |> result.unwrap(15)

  case driver {
    "postgres" -> load_postgres_config(pool_size)
    "sqlite" -> load_sqlite_config(pool_size)
    _ -> panic as "Please specify a valid DB_DRIVER in your .env file."
  }
}

/// Loads the database provider configuration by calling the
/// `database_provider.register()` function from the user's
/// application. Returns a list of Connection configurations.
///
/// Panics if the database_provider module is not found or
/// doesn't have a register() function.
///
pub fn load_provider() -> List(Connection) {
  case do_load_provider() {
    Ok(connections) -> connections
    Error(reason) -> {
      let msg = case reason {
        "module_not_found" ->
          "database_provider module not found. "
          <> "Please create src/database_provider.gleam with a register() function."
        "no_register_function" ->
          "database_provider module exists but doesn't have a register() function."
        _ -> "Failed to load database provider: " <> reason
      }
      panic as msg
    }
  }
}

/// Finds a connection by name from a list of connections. Panics if
/// the connection is not found.
///
pub fn get_connection(connections: List(Connection), name: String) -> Connection {
  case list.find(connections, fn(c) { driver.connection_name(c) == name }) {
    Ok(c) -> c
    Error(_) ->
      panic as {
        "Connection '"
        <> name
        <> "' not found in database_provider. "
        <> "Available connections: "
        <> string.join(list.map(connections, driver.connection_name), ", ")
      }
  }
}

/// Finds a connection by name from a list of connections. Returns
/// Error(Nil) if the connection is not found instead of panicking.
///
pub fn get_connection_safe(
  connections: List(Connection),
  name: String,
) -> Result(Connection, Nil) {
  list.find(connections, fn(c) { driver.connection_name(c) == name })
}

/// Creates a connection pool from a Connection configuration.
/// The pool size is taken from the connection's pool_size field.
/// Returns a ConfigError if required parameters are missing.
///
pub fn start_pool(connection: Connection) -> Result(Pool, DbError) {
  case driver.validate(connection) {
    [] -> {
      let config = driver.to_config(connection)
      pool.start(config)
    }
    missing -> {
      let name = driver.connection_name(connection)
      let params = string.join(missing, ", ")
      Error(ConfigError(
        "Connection '" <> name <> "' is missing required parameters: " <> params,
      ))
    }
  }
}

/// Executes a function within a database transaction. The 
/// connection is automatically checked out from the pool, and 
/// the transaction is committed on success or rolled back on 
/// error.
///
/// The `retries` parameter controls retry behavior for deadlocks:
/// - 0 = no retries (try once, fail on error)
/// - 3 = retry up to 3 times on deadlock (4 total attempts)
///
/// *Example:*
///
/// ```gleam
/// db.transaction(pool, fn(connection) {
///   use _ <- account_repository.debit(connection, from_id, amount)
///   use _ <- account_repository.credit(connection, to_id, amount)
///   Ok(Nil)
/// }, 3)
/// ```
///
pub fn transaction(
  pool: Pool,
  retries: Int,
  callback: fn(PoolConnection) -> Result(a, DbError),
) -> Result(a, DbError) {
  case retries < 0 {
    True -> Error(ConnectionError("Transaction retries cannot be negative"))
    False -> do_transaction(pool, retries, callback)
  }
}

// ------------------------------------------------------------- Private Functions

/// Loads PostgreSQL configuration from environment variables.
/// Tries DB_URL first, falls back to individual parameters.
///
fn load_postgres_config(pool_size: Int) -> pool_connection.Config {
  case env.get_string("DB_URL") {
    Ok(url) -> pool_connection.postgres_config(url, pool_size: pool_size)
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
      pool_connection.postgres_params_config(
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

/// Load SQLite Config
///
/// Loads SQLite configuration from environment variables.
/// Tries DB_DATABASE first, falls back to DB_PATH.
///
fn load_sqlite_config(pool_size: Int) -> pool_connection.Config {
  let path = case env.get_string("DB_DATABASE") {
    Ok(p) -> p
    Error(_) -> {
      let assert Ok(p) = env.get_string("DB_PATH")
      p
    }
  }
  pool_connection.sqlite_config(path, pool_size: pool_size)
}

/// Executes a transaction with the specified retry count. 
/// Checks out a connection, begins a transaction, runs the 
/// callback, and either commits on success or rolls back on 
/// error. On deadlock, delegates to `maybe_retry` for potential 
/// retry.
///
fn do_transaction(
  pool: Pool,
  retries_remaining: Int,
  callback: fn(PoolConnection) -> Result(a, DbError),
) -> Result(a, DbError) {
  case pool.checkout(pool) {
    Error(e) -> Error(e)
    Ok(connection) -> {
      let begin_sql = begin_statement(connection)
      case query.execute(connection, begin_sql, []) {
        Error(e) -> {
          pool.checkin(pool, connection)
          Error(e)
        }
        Ok(_) -> {
          case callback(connection) {
            Ok(value) -> {
              // Commit on success
              case query.execute(connection, "COMMIT", []) {
                Ok(_) -> {
                  pool.checkin(pool, connection)
                  Ok(value)
                }
                Error(e) -> {
                  // Try to rollback if commit fails
                  let _ = query.execute(connection, "ROLLBACK", [])
                  pool.checkin(pool, connection)
                  maybe_retry(pool, retries_remaining, callback, e)
                }
              }
            }
            Error(e) -> {
              // Rollback on error
              let _ = query.execute(connection, "ROLLBACK", [])
              pool.checkin(pool, connection)
              maybe_retry(pool, retries_remaining, callback, e)
            }
          }
        }
      }
    }
  }
}

/// Checks if an error is a deadlock and retries are remaining.
/// If so, waits with exponential backoff (50ms * retry number)
/// and retries the transaction. Otherwise, returns the error.
///
fn maybe_retry(
  pool: Pool,
  retries_remaining: Int,
  callback: fn(PoolConnection) -> Result(a, DbError),
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

/// Returns the appropriate BEGIN statement for the database 
/// driver. PostgreSQL uses "BEGIN", SQLite uses 
/// "BEGIN TRANSACTION".
///
fn begin_statement(connection: PoolConnection) -> String {
  case pool_connection.driver(connection) {
    Postgres -> "BEGIN"
    Sqlite -> "BEGIN TRANSACTION"
  }
}

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

// ------------------------------------------------------------- FFI Bindings

/// Calls database_provider:register() via FFI.
///
@external(erlang, "db_provider_ffi", "load_provider")
fn do_load_provider() -> Result(List(Connection), String)
