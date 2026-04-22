import gleam/io
import glimr/console/command.{type Args, type Command, Flag, Option}
import glimr/console/console
import glimr/internal/actions/compile_loom
import glimr/loom/loom

/// The console command description.
const description = "Compile loom templates to Gleam code"

/// Define the console command and its properties.
///
pub fn command() -> Command {
  command.new()
  |> command.description(description)
  |> command.args([
    Option("path", "Path to a specific loom file to compile", ""),
  ])
  |> command.args([
    Flag(
      "verbose",
      "v",
      "Display detailed information about compiled templates",
    ),
  ])
  |> command.handler(run)
}

/// Execute the console command
///
fn run(args: Args) -> Nil {
  let path = command.get_option(args, "path")
  let verbose = command.has_flag(args, "verbose")

  let result = case path {
    "" -> compile_loom.run(verbose)
    _ -> {
      case loom.is_views_path(path) {
        True -> compile_loom.run_path(path, verbose)
        False ->
          Error("Not a loom file: path must be in " <> loom.views_path <> ".")
      }
    }
  }

  case result {
    Ok(_) -> Nil
    Error(msg) -> {
      io.println(console.error(msg))
      io.println("")
      io.println(console.error("Build failed"))
      console.halt(1)
    }
  }
}

/// Console command's entry point
///
pub fn main() {
  command.run(command())
}
