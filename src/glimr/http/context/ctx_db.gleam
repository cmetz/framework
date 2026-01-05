//// Database Context
////
//// Provides a database context that manages multiple named connection pools.
//// Use `ctx.db.pool` for the default connection and `ctx.db.pool_for("name")`
//// to access other named connections.

import gleam/dict
import gleam/list
import glimr/db/db
import glimr/db/driver.{type Connection}
import glimr/db/pool.{type Pool}

/// Database context containing the default pool and a function
/// to access named connection pools.
///
pub type DbContext {
  DbContext(pool: Pool, pool_for: fn(String) -> Pool)
}

/// Loads all database pools from the given connections.
/// The connection named "default" is used for `ctx.db.pool`.
/// Use `ctx.db.pool_for("name")` to access other connections.
///
/// *Example*
///
/// ```gleam
/// // In ctx_provider.gleam
/// import glimr/http/context/ctx_db
/// import config/config_db
///
/// pub fn register() -> Context {
///   ctx.Context(
///     db: ctx_db.load(config_db.connections()),
///   )
/// }
/// ```
///
pub fn load(connections: List(Connection)) -> DbContext {
  let pools =
    connections
    |> list.map(fn(conn) {
      let assert Ok(pool) = db.start_pool(conn)
      #(driver.connection_name(conn), pool)
    })
    |> dict.from_list

  let assert Ok(default) = dict.get(pools, "default")

  DbContext(pool: default, pool_for: fn(name) {
    let assert Ok(p) = dict.get(pools, name)
    p
  })
}
