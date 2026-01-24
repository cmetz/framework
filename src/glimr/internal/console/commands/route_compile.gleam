import gleam/io
import gleam/string
import glimr/console/command.{type Command, type ParsedArgs, Flag, Option}
import glimr/console/console
import glimr/internal/actions/compile_routes

const name = "route:compile"

const description = "Compile route definitions to optimized pattern matching"

const routes_path = "src/routes/"

pub fn command() -> Command {
  command.new()
  |> command.name(name)
  |> command.description(description)
  |> command.args([
    Option("path", "Path to a specific route file to compile", ""),
  ])
  |> command.args([
    Flag("verbose", "v", "Display information about compiled routes"),
  ])
  |> command.handler(run)
}

fn run(args: ParsedArgs) -> Nil {
  let path = command.get_option(args, "path")
  let verbose = command.has_flag(args, "verbose")

  case path {
    "" -> compile_all(verbose)
    _ -> compile_path(path, verbose)
  }
}

fn compile_all(verbose: Bool) -> Nil {
  case compile_routes.run(verbose) {
    Ok(_) -> Nil
    Error(msg) -> io.println(console.error(msg))
  }
}

fn compile_path(path: String, verbose: Bool) -> Nil {
  case string.starts_with(path, routes_path), string.ends_with(path, ".gleam") {
    False, _ -> {
      io.println(console.error("Not a route file: path must be in src/routes/"))
    }
    _, False -> {
      io.println(console.error("Not a route file: path must end with .gleam"))
    }
    True, True -> {
      case compile_routes.run_path(path, verbose) {
        Ok(_) -> Nil
        Error(msg) -> io.println(console.error(msg))
      }
    }
  }
}
