import glimr/console/command.{type Command, type ParsedArgs, Argument, Flag}
import glimr/console/console
import glimr/db/db
import glimr/db/driver.{type Connection}
import glimr/internal/actions/run_setup_db

/// The name of the console command.
const name = "setup:database"

/// The console command description.
const description = "Set up a new database directory in src/data"

/// Define the console command and its properties.
///
pub fn command(connections: List(Connection)) -> Command {
  command.new()
  |> command.name(name)
  |> command.description(description)
  |> command.args([
    Argument(name: "name", description: "Database connection name"),
    Flag(
      name: "sqlite",
      short: "s",
      description: "Creates a data.db file to be used as the sqlite db",
    ),
  ])
  |> command.handler(fn(args: ParsedArgs) { run(args, connections) })
}

/// Execute the console command.
///
fn run(args: ParsedArgs, connections: List(Connection)) -> Nil {
  let name = command.get_arg(args, "name")
  let create_sqlite = command.has_flag(args, "sqlite")

  // Validate that the connection exists in config
  case db.get_connection_safe(connections, name) {
    Error(_) -> {
      console.output()
      |> console.line_error(
        "Database connection \"" <> name <> "\" does not exist in your config.",
      )
      |> console.print()
    }
    Ok(_) -> run_setup_db.run(name, create_sqlite)
  }
}
