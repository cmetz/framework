import gleam/io
import gleam/string
import glimr/console/command.{type Command, type ParsedArgs, Flag, Option}
import glimr/console/console
import glimr/internal/actions/compile_loom

/// The name of the console command.
const name = "loom:compile"

/// The console command description.
const description = "Compile loom templates to Gleam code"

const views_path = "src/resources/views/"

const app_loom_path = "src/app/loom/"

/// Define the console command and its properties.
///
pub fn command() -> Command {
  command.new()
  |> command.name(name)
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

/// Execute the console command.
///
fn run(args: ParsedArgs) -> Nil {
  let path = command.get_option(args, "path")
  let verbose = command.has_flag(args, "verbose")

  case path {
    "" -> compile_all(verbose)
    _ -> compile_path(path, verbose)
  }
}

fn compile_all(verbose: Bool) -> Nil {
  case compile_loom.run(verbose) {
    Ok(_) -> Nil
    Error(msg) -> io.println(console.error(msg))
  }
}

fn compile_path(path: String, verbose: Bool) -> Nil {
  let is_views_path = string.starts_with(path, views_path)
  let is_app_loom_path = string.starts_with(path, app_loom_path)

  case is_views_path || is_app_loom_path {
    False -> {
      io.println(console.error(
        "Not a loom file: path must be in src/resources/views/ or src/app/loom/",
      ))
    }
    True -> {
      case compile_loom.run_path(path, verbose) {
        Ok(_) -> Nil
        Error(msg) -> io.println(console.error(msg))
      }
    }
  }
}
