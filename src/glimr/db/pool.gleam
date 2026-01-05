//// Connection Pooling
////
//// Provides connection pooling for both PostgreSQL and SQLite.
//// PostgreSQL uses pog's built-in pooling. SQLite uses an ETS
//// heir-based pool (ported from pgo) for crash-safe connection
//// management.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleam/string
import glimr/db/pool_connection.{
  type Config, type DbError, type PoolConnection, ConnectionError,
  PostgresConfig, PostgresParamsConfig, SqliteConfig,
}
import pog
import sqlight

// ------------------------------------------------------------- Public Types

/// A connection pool that manages database connections. Use
/// `start` to create a pool and `get_connection` to borrow
/// connections.
///
pub opaque type Pool {
  PostgresPool(name: Dynamic)
  SqlitePool(name: Dynamic)
}

// ------------------------------------------------------------- Public Functions

/// Starts a connection pool with the given configuration.
/// For Postgres, this creates a named connection pool.
/// For SQLite, this creates a pool of connections managed
/// by an Erlang process.
///
/// *Example:*
///
/// ```gleam
/// let config = connection.sqlite_config("data.db", pool_size: 15)
/// let assert Ok(pool) = pool.start(config)
/// ```
///
pub fn start(config: Config) -> Result(Pool, DbError) {
  case config {
    PostgresConfig(url, pool_size) -> start_postgres_pool_url(url, pool_size)
    PostgresParamsConfig(host, port, database, username, password, pool_size) ->
      start_postgres_pool_params(
        host,
        port,
        database,
        username,
        password,
        pool_size,
      )
    SqliteConfig(path, pool_size) -> start_sqlite_pool(path, pool_size)
  }
}

/// Gracefully shuts down a connection pool, closing all
/// connections.
///
pub fn stop(pool: Pool) -> Nil {
  case pool {
    PostgresPool(name) -> {
      let _ = pgo_pool_stop(name)
      Nil
    }
    SqlitePool(name) -> {
      let _ = sqlite_pool_stop(name)
      Nil
    }
  }
}

/// Borrows a connection from the pool, executes a function,
/// and returns the connection to the pool. Can be used
/// in controllers, actions, etc. with the _wc variant of
/// the generated repository queries. 
///
/// *Example:*
///
/// ```gleam
/// pub fn show(req: Request, ctx: Context) -> Response {
///   use connection <- pool.get_connection(ctx.db.pool)
///   let assert Ok(user) = user_repository.find_wc(connection, 1)
///   
///   wisp.html_response("Hello " <> user.name, 200)
/// }
/// ```
///
pub fn get_connection(pool: Pool, next: fn(PoolConnection) -> next) -> next {
  case checkout(pool) {
    Error(e) -> panic as { "Connection pool failure: " <> string.inspect(e) }
    Ok(connection) -> {
      let next = next(connection)
      checkin(pool, connection)

      next
    }
  }
}

/// Borrows a connection from the pool, executes a function,
/// and returns the connection to the pool. Returns a Result,
/// useful for operations that need error handling like
/// console commands that may need a connection.
///
/// *Example:*
///
/// ```gleam
/// use connection <- pool.get_connection_or(pool)
/// query.execute(connection, "SELECT 1", [])
/// ```
///
pub fn get_connection_or(
  pool: Pool,
  f: fn(PoolConnection) -> Result(a, DbError),
) -> Result(a, DbError) {
  case checkout(pool) {
    Ok(connection) -> {
      let result = f(connection)
      checkin(pool, connection)
      result
    }
    Error(e) -> Error(e)
  }
}

/// Gets a connection from the pool without automatic return.
/// You MUST call `release` when done. However, if your process
/// crashes without calling release, the connection will be
/// automatically reclaimed by the pool (crash-safe).
///
pub fn checkout(pool: Pool) -> Result(PoolConnection, DbError) {
  case pool {
    PostgresPool(name) -> {
      case pgo_pool_checkout(name) {
        Ok(#(pool_ref, pog_conn)) ->
          Ok(pool_connection.from_pog(pog_conn, pool_ref))
        Error(_) -> Error(ConnectionError("No connections available in pool"))
      }
    }
    SqlitePool(name) -> {
      case sqlite_pool_checkout(name, []) {
        Ok(#(pool_ref, sqlight_conn)) ->
          Ok(pool_connection.from_sqlight(sqlight_conn, pool_ref))
        Error(_) -> Error(ConnectionError("No connections available in pool"))
      }
    }
  }
}

/// Returns a pool connection to the pool. Only needed if you used
/// `checkout` directly instead of `get_connection`.
///
pub fn checkin(pool: Pool, connection: PoolConnection) -> Nil {
  case pool {
    PostgresPool(_) -> {
      let assert Ok(pool_ref) = pool_connection.get_pool_ref(connection)
      let _ = pgo_pool_checkin(pool_ref, pool_connection.to_pog(connection))
      Nil
    }
    SqlitePool(_) -> {
      let assert Ok(pool_ref) = pool_connection.get_pool_ref(connection)
      let _ =
        sqlite_pool_checkin(pool_ref, pool_connection.to_sqlight(connection))
      Nil
    }
  }
}

// ------------------------------------------------------------- Private Functions

/// Creates a PostgreSQL connection pool from a URL using pog's
/// built-in pooling. Generates a unique pool name and configures
/// the pool size.
///
fn start_postgres_pool_url(url: String, pool_size: Int) -> Result(Pool, DbError) {
  let pool_name = process.new_name(prefix: "glimr_db_pool")

  case pog.url_config(pool_name, url) {
    Ok(config) -> {
      let config = pog.pool_size(config, pool_size)
      start_pog_pool(pool_name, config)
    }
    Error(Nil) -> Error(ConnectionError("Invalid Postgres connection URL"))
  }
}

/// Creates a PostgreSQL connection pool from individual parameters
/// using pog's builder pattern. This avoids URL parsing and handles
/// special characters in passwords correctly.
///
fn start_postgres_pool_params(
  host: String,
  port: Int,
  database: String,
  username: String,
  password: option.Option(String),
  pool_size: Int,
) -> Result(Pool, DbError) {
  let pool_name = process.new_name(prefix: "glimr_db_pool")

  let config =
    pog.default_config(pool_name)
    |> pog.host(host)
    |> pog.port(port)
    |> pog.database(database)
    |> pog.user(username)
    |> pog.pool_size(pool_size)

  let config = case password {
    option.Some(pw) -> pog.password(config, option.Some(pw))
    option.None -> config
  }

  start_pog_pool(pool_name, config)
}

/// Shared helper to start a pog pool from a configured config.
///
fn start_pog_pool(
  pool_name: process.Name(pog.Message),
  config: pog.Config,
) -> Result(Pool, DbError) {
  case pog.start(config) {
    Ok(actor.Started(_, _conn)) -> Ok(PostgresPool(name_to_dynamic(pool_name)))
    Error(actor.InitFailed(_)) ->
      Error(ConnectionError("Failed to start Postgres pool"))
    Error(actor.InitTimeout) ->
      Error(ConnectionError("Postgres pool initialization timed out"))
    Error(actor.InitExited(_)) ->
      Error(ConnectionError("Postgres pool exited during initialization"))
  }
}

/// Creates a SQLite connection pool under the SQLite pool
/// supervisor. Uses an ETS heir-based implementation (ported
/// from pgo). Connections are automatically reclaimed if the
/// borrowing process crashes, and the pool is automatically
/// restarted if it crashes.
///
fn start_sqlite_pool(path: String, pool_size: Int) -> Result(Pool, DbError) {
  let pool_name = process.new_name(prefix: "glimr_sqlite_pool")
  let config = sqlite_pool_config(pool_size)
  case sqlite_pool_sup_start(name_to_dynamic(pool_name), path, config) {
    Ok(name) -> Ok(SqlitePool(name))
    Error(_) -> Error(ConnectionError("Failed to start SQLite pool"))
  }
}

/// Creates the configuration map for the SQLite pool.
///
fn sqlite_pool_config(pool_size: Int) -> Dynamic {
  make_pool_config(pool_size)
}

// ------------------------------------------------------------- FFI Bindings

/// Creates the configuration map for the SQLite pool in Erlang.
///
@external(erlang, "sqlite_pool_ffi", "make_config")
fn make_pool_config(pool_size: Int) -> Dynamic

/// Starts a SQLite connection pool under the supervisor.
///
@external(erlang, "sqlite_pool_sup", "start_pool")
fn sqlite_pool_sup_start(
  name: Dynamic,
  path: String,
  config: Dynamic,
) -> Result(Dynamic, Dynamic)

/// Stops a SQLite pool managed by the supervisor.
///
@external(erlang, "sqlite_pool_sup", "stop_pool")
fn sqlite_pool_stop(name: Dynamic) -> Dynamic

/// Checks out a connection from the SQLite pool. Returns the
/// pool reference and the sqlight connection.
///
@external(erlang, "sqlite_pool", "checkout")
fn sqlite_pool_checkout(
  pool_name: Dynamic,
  opts: List(#(String, Dynamic)),
) -> Result(#(Dynamic, sqlight.Connection), Dynamic)

/// Returns a connection to the SQLite pool.
///
@external(erlang, "sqlite_pool", "checkin")
fn sqlite_pool_checkin(
  pool_ref: Dynamic,
  connection: sqlight.Connection,
) -> Dynamic

/// Checks out a connection from the Postgres pool. Returns the
/// pool reference and the pog connection.
///
@external(erlang, "pgo_pool_ffi", "checkout")
fn pgo_pool_checkout(
  pool_name: Dynamic,
) -> Result(#(Dynamic, pog.Connection), Dynamic)

/// Returns a connection to the Postgres pool.
///
@external(erlang, "pgo_pool_ffi", "checkin")
fn pgo_pool_checkin(pool_ref: Dynamic, connection: pog.Connection) -> Dynamic

/// Stops a Postgres pool by terminating it via the supervisor.
///
@external(erlang, "pgo_pool_ffi", "stop_pool")
fn pgo_pool_stop(pool_name: Dynamic) -> Dynamic

/// Converts a process Name to Dynamic for FFI calls.
///
@external(erlang, "pgo_pool_ffi", "identity")
fn name_to_dynamic(name: process.Name(a)) -> Dynamic
