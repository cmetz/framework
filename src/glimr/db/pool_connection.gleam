//// Pool Connection Abstraction
////
//// Provides a unified interface over PostgreSQL (pog) and
//// SQLite (sqlight) pooled database connections. This allows
//// application code to work with either database without
//// changes.

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/option.{type Option}
import gleam/result
import gleam/string
import pog
import sqlight

// ------------------------------------------------------------- Public Types

/// Identifies which database driver is being used. This allows
/// you to seamlessly use multiple connections of different
/// database drivers throughout your app.
///
pub type Driver {
  Postgres
  Sqlite
}

/// Configuration for establishing a database connection. Use 
/// `postgres_config`, `postgres_params_config`, or
/// `sqlite_config` to create instances.
///
pub type Config {
  PostgresConfig(url: String, pool_size: Int)
  PostgresParamsConfig(
    host: String,
    port: Int,
    database: String,
    username: String,
    password: Option(String),
    pool_size: Int,
  )
  SqliteConfig(path: String, pool_size: Int)
}

/// A pooled database connection that abstracts over the
/// underlying driver. Use with the `query` module functions.
///
pub opaque type PoolConnection {
  PostgresPoolConnection(inner: pog.Connection, pool_ref: Dynamic)
  SqlitePoolConnection(inner: sqlight.Connection, pool_ref: Dynamic)
}

/// Unified error type for database operations. This allows 
/// users to handle specific database errors any way they like.
///
pub type DbError {
  /// The requested row was not found (for single-row queries)
  NotFound
  /// A constraint was violated (unique, foreign key, etc.)
  ConstraintError(message: String, constraint: String)
  /// A query syntax or execution error
  QueryError(message: String)
  /// Connection to database failed or unavailable
  ConnectionError(message: String)
  /// Query timed out
  TimeoutError
  /// Result decoding failed
  DecodeError(message: String)
  /// Connection configuration is invalid or missing required parameters
  ConfigError(message: String)
}

/// The result of a database query, containing the number of
/// affected rows and the returned data.
///
pub type QueryResult(t) {
  QueryResult(count: Int, rows: List(t))
}

/// A parameter value that can be passed to a database query.
/// Use the constructor functions to create values.
///
pub opaque type Value {
  PgValue(pog.Value)
  SqliteValue(sqlight.Value)
  /// Placeholder for deferred conversion based on driver
  IntValue(Int)
  FloatValue(Float)
  StringValue(String)
  BoolValue(Bool)
  NullValue
  BlobValue(BitArray)
}

// ------------------------------------------------------------- Public Functions

/// Creates a PostgreSQL configuration from a connection URL.
/// This configuration will have its own pool of connections
/// specific to this database.
///
/// URL format: `postgresql://user:password@host:port/database`
///
/// *Example:*
///
/// ```gleam
/// let config = postgres_config(
///   "postgresql://postgres:secret@localhost:5432/myapp",
///   pool_size: 10,
/// )
/// ```
///
pub fn postgres_config(url: String, pool_size pool_size: Int) -> Config {
  PostgresConfig(url: url, pool_size: pool_size)
}

/// Creates a PostgreSQL configuration from individual 
/// parameters. This is an alternative to `postgres_config` when 
/// you have separate host, port, database, username, and 
/// password values.
///
/// *Example:*
///
/// ```gleam
/// let config = postgres_params_config(
///   host: "localhost",
///   port: 5432,
///   database: "myapp",
///   username: "postgres",
///   password: Some("secret"),
///   pool_size: 10,
/// )
/// ```
///
pub fn postgres_params_config(
  host host: String,
  port port: Int,
  database database: String,
  username username: String,
  password password: Option(String),
  pool_size pool_size: Int,
) -> Config {
  PostgresParamsConfig(
    host: host,
    port: port,
    database: database,
    username: username,
    password: password,
    pool_size: pool_size,
  )
}

/// Creates a SQLite configuration from a file path. This 
/// configuration will have its own pool of connections
/// specific to this database.
///
/// Use `:memory:` for an in-memory database.
///
/// *Example:*
///
/// ```gleam
/// let config = sqlite_config("data.db", pool_size: 5)
/// let memory_config = sqlite_config(":memory:", pool_size: 1)
/// ```
///
pub fn sqlite_config(path: String, pool_size pool_size: Int) -> Config {
  SqliteConfig(path: path, pool_size: pool_size)
}

/// Returns the driver type for the provided pool connection.
///
pub fn driver(connection: PoolConnection) -> Driver {
  case connection {
    PostgresPoolConnection(_, _) -> Postgres
    SqlitePoolConnection(_, _) -> Sqlite
  }
}

/// Wraps a raw pog connection with its pool reference for use
/// with the glimr db module. The pool_ref is needed for proper
/// checkin when releasing the connection.
///
pub fn from_pog(connection: pog.Connection, pool_ref: Dynamic) -> PoolConnection {
  PostgresPoolConnection(connection, pool_ref)
}

/// Wraps a sqlight connection with its pool reference for use
/// with the glimr db module. The pool_ref is needed for proper
/// checkin when releasing the connection.
///
pub fn from_sqlight(
  connection: sqlight.Connection,
  pool_ref: Dynamic,
) -> PoolConnection {
  SqlitePoolConnection(connection, pool_ref)
}

/// Extracts the underlying pog connection. Panics if the pog
/// connection is not Postgres.
///
pub fn to_pog(connection: PoolConnection) -> pog.Connection {
  case connection {
    PostgresPoolConnection(inner, _) -> inner
    SqlitePoolConnection(_, _) ->
      panic as "Cannot convert SQLite connection to pog"
  }
}

/// Extracts the underlying sqlight connection. Panics if the 
/// connection is not SQLite.
///
pub fn to_sqlight(connection: PoolConnection) -> sqlight.Connection {
  case connection {
    SqlitePoolConnection(inner, _) -> inner
    PostgresPoolConnection(_, _) ->
      panic as "Cannot convert Postgres connection to sqlight"
  }
}

/// Extracts the pool reference from a pool connection. This is the
/// reference returned by checkout that must be passed to checkin.
///
pub fn get_pool_ref(connection: PoolConnection) -> Result(Dynamic, Nil) {
  case connection {
    SqlitePoolConnection(_, pool_ref) -> Ok(pool_ref)
    PostgresPoolConnection(_, pool_ref) -> Ok(pool_ref)
  }
}

/// Creates an integer parameter value.
///
pub fn int(value: Int) -> Value {
  IntValue(value)
}

/// Creates a float parameter value.
///
pub fn float(value: Float) -> Value {
  FloatValue(value)
}

/// Creates a string/text parameter value.
///
pub fn string(value: String) -> Value {
  StringValue(value)
}

/// Creates a boolean parameter value.
/// Note: SQLite stores booleans as integers (0/1).
///
pub fn bool(value: Bool) -> Value {
  BoolValue(value)
}

/// Creates a NULL parameter value.
///
pub fn null() -> Value {
  NullValue
}

/// Creates a binary/blob parameter value.
///
pub fn blob(value: BitArray) -> Value {
  BlobValue(value)
}

/// Creates a parameter value from an Option, converting None to NULL.
///
pub fn nullable(inner: fn(a) -> Value, value: Option(a)) -> Value {
  case value {
    option.Some(v) -> inner(v)
    option.None -> null()
  }
}

/// Converts a generic Value to a pog-specific Value for use
/// with PostgreSQL queries. Panics if given a SQLite-specific
/// value.
///
pub fn to_pog_value(value: Value) -> pog.Value {
  case value {
    PgValue(v) -> v
    IntValue(v) -> pog.int(v)
    FloatValue(v) -> pog.float(v)
    StringValue(v) -> pog.text(v)
    BoolValue(v) -> pog.bool(v)
    NullValue -> pog.null()
    BlobValue(v) -> pog.bytea(v)
    SqliteValue(_) -> panic as "Cannot convert SQLite value to pog"
  }
}

/// Converts a generic Value to a sqlight-specific Value for use
/// with SQLite queries. Panics if given a PostgreSQL-specific
/// value.
///
pub fn to_sqlight_value(value: Value) -> sqlight.Value {
  case value {
    SqliteValue(v) -> v
    IntValue(v) -> sqlight.int(v)
    FloatValue(v) -> sqlight.float(v)
    StringValue(v) -> sqlight.text(v)
    BoolValue(v) -> sqlight.bool(v)
    NullValue -> sqlight.null()
    BlobValue(v) -> sqlight.blob(v)
    PgValue(_) -> panic as "Cannot convert pog value to sqlight"
  }
}

/// Converts $1, $2, etc. placeholders to ? for SQLite.
/// This allows using consistent Postgres-style placeholders
/// in SQL files.
///
pub fn convert_placeholders(sql: String, driver: Driver) -> String {
  case driver {
    Postgres -> sql
    Sqlite -> convert_pg_to_sqlite_placeholders(sql)
  }
}

// ------------------------------------------------------------- Private Functions

/// Entry point for placeholder conversion. Converts the SQL
/// string to graphemes and delegates to the recursive converter.
///
fn convert_pg_to_sqlite_placeholders(sql: String) -> String {
  do_convert_placeholders(string.to_graphemes(sql), "", False)
}

/// Recursively processes characters, replacing $N placeholders
/// with ? for SQLite. Tracks whether we're inside a placeholder
/// to skip the numeric portion after the $.
///
fn do_convert_placeholders(
  chars: List(String),
  acc: String,
  in_placeholder: Bool,
) -> String {
  case chars {
    [] -> acc
    ["$", ..rest] -> do_convert_placeholders(rest, acc <> "?", True)
    [c, ..rest] if in_placeholder -> {
      case result.is_ok(int.parse(c)) {
        True -> do_convert_placeholders(rest, acc, True)
        False -> do_convert_placeholders(rest, acc <> c, False)
      }
    }
    [c, ..rest] -> do_convert_placeholders(rest, acc <> c, False)
  }
}
