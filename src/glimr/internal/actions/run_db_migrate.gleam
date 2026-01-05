//// Run Database Migrations Action
////
//// Shared action for running database migrations. Used by both
//// the db:migrate command and gen:db --migrate flag to ensure
//// consistent behavior.

import gleam/int
import gleam/list
import gleam/string
import glimr/console/console
import glimr/db/migrate
import glimr/db/pool_connection.{type PoolConnection}

/// Runs pending migrations and prints the results.
///
pub fn run(connection: PoolConnection, database: String) -> Nil {
  case migrate.migrate(connection, database) {
    Ok(applied) -> {
      case applied {
        [] -> {
          console.output()
          |> console.line("No pending migrations.")
          |> console.print()
        }
        _ -> {
          let count = int.to_string(list.length(applied))
          let output =
            console.output()
            |> console.line_success("Applied " <> count <> " migration(s):")

          let output =
            list.fold(applied, output, fn(out, version) {
              console.line(out, "  ✓ " <> version)
            })

          console.print(output)
        }
      }
    }
    Error(err) -> {
      console.output()
      |> console.line_error("Migration failed:")
      |> console.line(string.inspect(err))
      |> console.print()
    }
  }
}
