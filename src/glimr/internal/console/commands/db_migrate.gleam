import glimr/console/command.{type Command, type ParsedArgs, Flag}
import glimr/db/pool.{type Pool}
import glimr/internal/actions/run_db_fresh
import glimr/internal/actions/run_db_migrate

/// The name of the console command.
const name = "db:migrate"

/// The console command description.
const description = "Run pending database migrations"

/// Define the Command and its properties.
///
pub fn command() -> Command {
  command.new()
  |> command.name(name)
  |> command.description(description)
  |> command.args([
    Flag(
      name: "fresh",
      short: "f",
      description: "Drop all tables and re-run all migrations",
    ),
  ])
  |> command.handler_with_db(run)
}

/// Execute the console command.
///
fn run(args: ParsedArgs, pool: Pool) -> Nil {
  let database = command.get_option(args, "database")
  let fresh = command.has_flag(args, "fresh")

  use connection <- pool.get_connection(pool)

  case fresh {
    True -> run_db_fresh.run(connection, database)
    False -> run_db_migrate.run(connection, database)
  }
}
