//// Glimr Console Kernel
////
//// Registers Glimr's console commands and is the entry point
//// to run your app's custom console commands as well as
//// Glimr's default console commands.

import gleam/io
import glimr/console/command.{type Command}
import glimr/console/console
import glimr/db/driver.{type Connection}
import glimr/internal/console/commands/db_migrate
import glimr/internal/console/commands/gen_db
import glimr/internal/console/commands/greet
import glimr/internal/console/commands/make_action
import glimr/internal/console/commands/make_command
import glimr/internal/console/commands/make_controller
import glimr/internal/console/commands/make_middleware
import glimr/internal/console/commands/make_model
import glimr/internal/console/commands/make_request
import glimr/internal/console/commands/make_rule

// ------------------------------------------------------------- Public Functions

/// Returns the list of internal Glimr framework commands.
/// Commands are generic over ctx so they can be merged
/// with user commands into a single unified list.
///
pub fn commands() -> List(Command) {
  [
    db_migrate.command(),
    gen_db.command(),
    greet.command(),
    make_action.command(),
    make_controller.command(),
    make_middleware.command(),
    make_request.command(),
    make_rule.command(),
    make_command.command(),
    make_model.command(),
  ]
}

/// Entry point for running console commands. Merges internal
/// Glimr commands with user-defined commands into a single
/// list. Commands receive the user's context and can decode
/// GlimrContext from it if needed.
///
pub fn run(
  commands commands: List(Command),
  db_connections db_connections: List(Connection),
) {
  let args = command.get_args()

  case args {
    [] -> command.print_help(commands)
    ["-V"] | ["--version"] -> command.print_glimr_version()
    [name, ..rest] -> {
      case command.find_and_run(commands, db_connections, name, rest) {
        True -> Nil
        False -> io.println(console.error("Command not found: " <> name))
      }
    }
  }
}
