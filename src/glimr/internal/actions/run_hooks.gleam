//// Hook Runner
////
//// Executes hook commands configured in the Glimr project.
//// Supports both internal Glimr commands and external shell
//// commands with file path substitution.
////

import gleam/dict
import gleam/io
import gleam/list
import gleam/string
import glimr/internal/actions/compile_commands
import shellout

/// Runs a list of hook commands sequentially. Stops and returns
/// an error if any hook fails. Internal commands starting with
/// "./glimr " are executed directly, others via shell.
///
pub fn run(hooks: List(String)) -> Result(Nil, String) {
  run_hooks(hooks)
}

/// Runs hooks for each file, substituting $PATH with the file
/// path. Processes files sequentially, stopping on the first
/// error encountered.
///
pub fn run_for_files(
  hooks: List(String),
  files: List(String),
) -> Result(Nil, String) {
  case files {
    [] -> Ok(Nil)
    [file, ..rest] -> {
      let substituted_hooks =
        list.map(hooks, fn(hook) { string.replace(hook, "$PATH", file) })
      case run_hooks(substituted_hooks) {
        Ok(_) -> run_for_files(hooks, rest)
        Error(e) -> Error(e)
      }
    }
  }
}

/// Recursive helper that processes hooks one at a time. Returns
/// Ok when all hooks complete successfully or Error on the
/// first failure.
///
fn run_hooks(hooks: List(String)) -> Result(Nil, String) {
  case hooks {
    [] -> Ok(Nil)
    [hook, ..rest] -> {
      case run_hook(hook) {
        Ok(_) -> run_hooks(rest)
        Error(e) -> Error(e)
      }
    }
  }
}

/// Runs a single hook command. Dispatches to internal command
/// handler if the command starts with "./glimr ", otherwise
/// runs it as an external shell command.
///
fn run_hook(cmd: String) -> Result(Nil, String) {
  case string.starts_with(cmd, "./glimr ") {
    True -> run_internal_command(cmd)
    False -> run_external_command(cmd)
  }
}

/// Executes an internal Glimr command by name. Looks up the
/// command in the registry and calls its main() function
/// dynamically to avoid spawning a new BEAM VM.
///
fn run_internal_command(cmd: String) -> Result(Nil, String) {
  let parts =
    cmd
    |> string.drop_start(8)
    |> string.trim()
    |> string.split(" ")

  let name = list.first(parts) |> unwrap_or("")

  case compile_commands.read_registry() {
    Ok(registry) -> {
      case dict.get(registry, name) {
        Ok(info) -> {
          // Convert module path to Erlang atom format
          // glimr/internal/console/commands/build -> glimr@internal@console@commands@build
          let module = string.replace(info.module, "/", "@")
          call_module_main(module)
          Ok(Nil)
        }
        Error(_) -> {
          Error("Unknown command: " <> name)
        }
      }
    }
    Error(_) -> {
      // Registry not found, fall back to external
      run_external_command(cmd)
    }
  }
}

/// Dynamically calls a module's main() function using Erlang
/// apply/3. The module string should be in Erlang atom format
/// (e.g., "glimr@internal@console@commands@build").
///
@external(erlang, "glimr_hooks_ffi", "call_module_main")
fn call_module_main(module: String) -> Nil

/// Unwraps a Result, returning the Ok value or a default.
/// Provides a fallback value when the result contains an
/// error instead of a valid value.
///
fn unwrap_or(result: Result(a, e), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(_) -> default
  }
}

/// Executes an external command via /bin/sh. Prints any output
/// from the command and returns Error with details if the
/// command fails.
///
fn run_external_command(cmd: String) -> Result(Nil, String) {
  case shellout.command("/bin/sh", ["-c", cmd], in: ".", opt: []) {
    Ok(output) -> {
      let trimmed = string.trim_end(output)
      case trimmed {
        "" -> Nil
        _ -> io.println(trimmed)
      }
      Ok(Nil)
    }
    Error(#(_, msg)) -> {
      Error("Hook failed: " <> cmd <> "\n" <> msg)
    }
  }
}
