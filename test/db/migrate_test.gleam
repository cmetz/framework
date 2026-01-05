import gleam/dynamic/decode
import gleam/list
import gleeunit/should
import glimr/db/pool
import glimr/db/pool_connection
import glimr/db/query

// ------------------------------------------------------------- SQLite Drop All Tables

pub fn sqlite_drop_all_tables_test() {
  let config = pool_connection.sqlite_config(":memory:", pool_size: 1)
  let assert Ok(p) = pool.start(config)

  // Create multiple tables
  pool.get_connection(p, fn(connection) {
    let assert Ok(_) =
      query.execute(
        connection,
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
      )
    let assert Ok(_) =
      query.execute(
        connection,
        "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)",
        [],
      )
    let assert Ok(_) =
      query.execute(
        connection,
        "CREATE TABLE comments (id INTEGER PRIMARY KEY, body TEXT)",
        [],
      )
    Nil
  })

  // Verify tables exist
  let tables_before = get_sqlite_tables(p)
  tables_before
  |> list.length()
  |> should.equal(3)

  // Drop all tables using the same logic as db:migrate --fresh
  pool.get_connection(p, fn(connection) { drop_all_sqlite_tables(connection) })

  // Verify all tables are gone
  let tables_after = get_sqlite_tables(p)
  tables_after
  |> list.length()
  |> should.equal(0)

  pool.stop(p)
}

pub fn sqlite_drop_tables_with_foreign_keys_test() {
  let config = pool_connection.sqlite_config(":memory:", pool_size: 1)
  let assert Ok(p) = pool.start(config)

  // Create tables with foreign key relationships
  pool.get_connection(p, fn(connection) {
    let assert Ok(_) =
      query.execute(
        connection,
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
      )
    let assert Ok(_) =
      query.execute(
        connection,
        "CREATE TABLE posts (
          id INTEGER PRIMARY KEY,
          user_id INTEGER,
          title TEXT,
          FOREIGN KEY (user_id) REFERENCES users(id)
        )",
        [],
      )
    Nil
  })

  // Insert some data
  pool.get_connection(p, fn(connection) {
    let assert Ok(_) =
      query.execute(
        connection,
        "INSERT INTO users (id, name) VALUES (1, 'Alice')",
        [],
      )
    let assert Ok(_) =
      query.execute(
        connection,
        "INSERT INTO posts (id, user_id, title) VALUES (1, 1, 'Hello')",
        [],
      )
    Nil
  })

  // Drop all tables
  pool.get_connection(p, fn(connection) { drop_all_sqlite_tables(connection) })

  // Verify all tables are gone
  let tables_after = get_sqlite_tables(p)
  tables_after
  |> list.length()
  |> should.equal(0)

  pool.stop(p)
}

pub fn sqlite_drop_empty_database_test() {
  let config = pool_connection.sqlite_config(":memory:", pool_size: 1)
  let assert Ok(p) = pool.start(config)

  // Drop on empty database should not error
  pool.get_connection(p, fn(connection) { drop_all_sqlite_tables(connection) })

  // Still no tables
  let tables = get_sqlite_tables(p)
  tables
  |> list.length()
  |> should.equal(0)

  pool.stop(p)
}

pub fn sqlite_can_recreate_tables_after_drop_test() {
  let config = pool_connection.sqlite_config(":memory:", pool_size: 1)
  let assert Ok(p) = pool.start(config)

  // Create a table
  pool.get_connection(p, fn(connection) {
    let assert Ok(_) =
      query.execute(
        connection,
        "CREATE TABLE submissions (id INTEGER PRIMARY KEY, name TEXT)",
        [],
      )
    Nil
  })

  // Insert data
  pool.get_connection(p, fn(connection) {
    let assert Ok(_) =
      query.execute(
        connection,
        "INSERT INTO submissions (id, name) VALUES (1, 'Test')",
        [],
      )
    Nil
  })

  // Drop all tables
  pool.get_connection(p, fn(connection) { drop_all_sqlite_tables(connection) })

  // Recreate the same table - this should NOT error
  pool.get_connection(p, fn(connection) {
    let assert Ok(_) =
      query.execute(
        connection,
        "CREATE TABLE submissions (id INTEGER PRIMARY KEY, name TEXT)",
        [],
      )
    Nil
  })

  // Verify table exists and is empty
  let count =
    pool.get_connection(p, fn(connection) {
      let decoder = decode.at([0], decode.int)
      let assert Ok(query.QueryResult(rows: [count], ..)) =
        query.select(
          connection,
          "SELECT COUNT(*) FROM submissions",
          [],
          decoder,
        )
      count
    })

  count
  |> should.equal(0)

  pool.stop(p)
}

// ------------------------------------------------------------- Helper Functions

fn get_sqlite_tables(p: pool.Pool) -> List(String) {
  pool.get_connection(p, fn(connection) {
    let tables_sql =
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    let decoder = {
      use name <- decode.field(0, decode.string)
      decode.success(name)
    }
    case query.select_all(connection, tables_sql, [], decoder) {
      Ok(tables) -> tables
      Error(_) -> []
    }
  })
}

fn drop_all_sqlite_tables(connection: pool_connection.PoolConnection) -> Nil {
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
    }
    Error(_) -> Nil
  }
}
