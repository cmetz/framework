//// Glimr Console Command
////
//// Provides a fluent API for defining console commands.
//// Commands capture their context at construction time via
//// closures, allowing framework and user commands to coexist.

import gleam/dict.{type Dict}
import gleam/erlang/charlist
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import glimr/console/console
import glimr/db/db
import glimr/db/driver.{type Connection}
import glimr/db/pool.{type Pool}
import glimr/db/pool_connection.{ConfigError}
import glimr/glimr

// ------------------------------------------------------------- Public types

/// Represents a console command. All commands have a name,
/// description, optional arguments, and a handler function.
/// Commands without arguments simply have an empty args list.
///
/// Use `Command` for standard commands and `CommandWithDb` for
/// commands that require a database connection.
///
pub type Command {
  Command(
    name: String,
    description: String,
    args: List(CommandArg),
    handler: fn(ParsedArgs) -> Nil,
  )
  CommandWithDb(
    name: String,
    description: String,
    args: List(CommandArg),
    handler: fn(ParsedArgs, Pool) -> Nil,
  )
}

/// Defines an argument, flag, or option that a command accepts.
/// Use `Argument` for required positional arguments,
/// `Flag` for boolean flags like --verbose or -v, and
/// `Option` for options with values and defaults like --format=json.
///
pub type CommandArg {
  Argument(name: String, description: String)
  Flag(name: String, short: String, description: String)
  Option(name: String, description: String, default: String)
}

/// Parsed arguments passed to command handlers. Contains
/// positional arguments as a Dict, flags as a List, and
/// options with values as a Dict.
/// Use get_arg(), has_flag(), and get_option() to access values.
///
pub type ParsedArgs {
  ParsedArgs(
    arguments: Dict(String, String),
    flags: List(String),
    options: Dict(String, String),
  )
}

// ------------------------------------------------------------- Public Functions

/// Creates a new command. Use the fluent API to set the
/// name, description, args, and handler. Use `handler` for
/// standard commands or `handler_with_db` for commands that
/// need database access.
///
/// *Example*
///
/// ```gleam
/// command.new()
/// |> command.name("greet")
/// |> command.description("Greet the user")
/// |> command.handler(run)
/// ```
///
pub fn new() -> Command {
  Command(name: "", description: "", args: [], handler: temp_handler)
}

/// Sets the name of the command. This is the string users
/// will type to invoke the command. It's best to prefix
/// command names like "make:controller" or "glimr:greet"
/// but it's not required.
///
pub fn name(command: Command, name: String) -> Command {
  case command {
    Command(_, desc, a, h) -> Command(name, desc, a, h)
    CommandWithDb(_, desc, a, h) -> CommandWithDb(name, desc, a, h)
  }
}

/// Sets the description shown in the help output. Description
/// should be a one-liner, nice and simple. This text appears
/// next to the command name when users run the help command.
///
pub fn description(command: Command, description: String) -> Command {
  case command {
    Command(n, _, a, h) -> Command(n, description, a, h)
    CommandWithDb(n, _, a, h) -> CommandWithDb(n, description, a, h)
  }
}

/// Sets the handler function for the command. The handler
/// receives ParsedArgs containing any arguments and options.
/// For commands without args, ParsedArgs will be empty.
///
pub fn handler(command: Command, handler: fn(ParsedArgs) -> Nil) -> Command {
  case command {
    Command(n, desc, a, _) -> Command(n, desc, a, handler)
    CommandWithDb(_, _, _, _) ->
      panic as "Use handler_with_db for CommandWithDb"
  }
}

/// Sets the handler function for a database command. Converts
/// a Command to CommandWithDb. The handler receives ParsedArgs
/// and a Pool that is automatically started and stopped by
/// the framework. Automatically adds --database option.
///
pub fn handler_with_db(
  command: Command,
  handler: fn(ParsedArgs, Pool) -> Nil,
) -> Command {
  let db_option = Option("database", "Database connection to use", "default")
  let #(n, desc, a) = case command {
    Command(n, desc, a, _) -> #(n, desc, a)
    CommandWithDb(n, desc, a, _) -> #(n, desc, a)
  }
  CommandWithDb(n, desc, list.append(a, [db_option]), handler)
}

/// Sets the arguments, flags, and options for a command. Use
/// Argument for required positional args, Flag for boolean flags,
/// and Option for options that take values.
///
/// *Example*
///
/// ```gleam
/// command.new()
/// |> command.name("make:controller")
/// |> command.args([
///   Argument("name", "The name of the controller"),
///   Flag("resource", "r", "Generate a resource controller"),
///   Option("template", "Template to use for generation", "default"),
/// ])
/// |> command.handler(fn(args) { ... })
/// ```
///
pub fn args(command: Command, arguments: List(CommandArg)) -> Command {
  case command {
    Command(n, desc, _, h) -> Command(n, desc, arguments, h)
    CommandWithDb(n, desc, _, h) -> CommandWithDb(n, desc, arguments, h)
  }
}

/// Gets a positional argument value from ParsedArgs by name.
/// Arguments are required and validated before the handler runs,
/// so this will crash if the argument is missing.
///
pub fn get_arg(parsed: ParsedArgs, name: String) -> String {
  let assert Ok(value) = dict.get(parsed.arguments, name)
  value
}

/// Checks if a flag was provided by the user.
/// Returns True if --name or -short was passed on the CLI.
/// The name parameter should match the Flag's name field.
///
pub fn has_flag(parsed: ParsedArgs, name: String) -> Bool {
  list.contains(parsed.flags, name)
}

/// Gets an option value from ParsedArgs by name.
/// Returns the provided value or the option's default.
///
pub fn get_option(parsed: ParsedArgs, name: String) -> String {
  let assert Ok(value) = dict.get(parsed.options, name)
  value
}

// ------------------------------------------------------------- Internal Public Functions

/// Retrieves command-line arguments as Gleam strings. Calls
/// the Erlang function to get raw charlists and converts them
/// to Gleam strings for easier processing.
///
@internal
pub fn get_args() -> List(String) {
  erlang_get_args()
  |> list.map(charlist.to_string)
}

/// Finds a command by name and executes it with the given
/// arguments. For CommandWithDb, starts a pool, provides
/// the connection, and cleans up after. Returns False if
/// the command is not found.
///
@internal
pub fn find_and_run(
  commands: List(Command),
  connections: List(Connection),
  name: String,
  args: List(String),
) -> Bool {
  case find(commands, name) {
    Ok(cmd) -> {
      run(cmd, args, connections)
      True
    }
    Error(_) -> False
  }
}

/// Displays the help message with all available commands.
/// Command descriptions are aligned for readability based
/// on the longest command name in the list.
///
@internal
pub fn print_help(commands: List(Command)) {
  print_glimr_version()
  io.println("")

  io.println(console.warning("Usage:"))
  io.println("  command [arguments] [options]")
  io.println("")

  // Find the longest command name for alignment
  let max_length =
    list.fold(commands, string.length("-h, --help"), fn(acc, cmd) {
      let cmd_name = case cmd {
        Command(n, _, _, _) -> n
        CommandWithDb(n, _, _, _) -> n
      }
      int.max(acc, string.length(cmd_name))
    })

  io.println(console.warning("Options:"))
  let help_label = string.pad_end("-h, --help", max_length + 2, " ")
  io.println(
    "  " <> console.success(help_label) <> "Display help for the given command",
  )
  io.println("")

  // Split commands into non-namespaced and namespaced
  let #(non_namespaced, namespaced) =
    list.partition(commands, fn(cmd) {
      let cmd_name = case cmd {
        Command(n, _, _, _) -> n
        CommandWithDb(n, _, _, _) -> n
      }
      !string.contains(cmd_name, ":")
    })

  // Sort non-namespaced commands alphabetically
  let sorted_non_namespaced =
    list.sort(non_namespaced, fn(a, b) {
      let name_a = case a {
        Command(n, _, _, _) -> n
        CommandWithDb(n, _, _, _) -> n
      }
      let name_b = case b {
        Command(n, _, _, _) -> n
        CommandWithDb(n, _, _, _) -> n
      }
      string.compare(name_a, name_b)
    })

  // Group namespaced commands by namespace
  let grouped = group_by_namespace(namespaced)

  // Sort namespace groups alphabetically
  let sorted_groups = list.sort(grouped, fn(a, b) { string.compare(a.0, b.0) })

  // Print non-namespaced commands
  io.println(console.warning("Available commands:"))
  list.each(sorted_non_namespaced, fn(cmd) {
    let #(cmd_name, cmd_desc) = case cmd {
      Command(n, d, _, _) -> #(n, d)
      CommandWithDb(n, d, _, _) -> #(n, d)
    }
    let padded_name = string.pad_end(cmd_name, max_length + 2, " ")
    io.println("  " <> console.success(padded_name) <> cmd_desc)
  })

  // Print namespaced commands grouped by namespace
  list.each(sorted_groups, fn(group) {
    let #(namespace, cmds) = group
    io.println(" " <> console.warning(namespace))
    list.each(cmds, fn(cmd) {
      let #(cmd_name, cmd_desc) = case cmd {
        Command(n, d, _, _) -> #(n, d)
        CommandWithDb(n, d, _, _) -> #(n, d)
      }
      let padded_name = string.pad_end(cmd_name, max_length + 2, " ")
      io.println("  " <> console.success(padded_name) <> cmd_desc)
    })
  })

  io.println("")
}

/// Prints the current Glimr framework version to the console.
/// Called when the user runs with -V or --version flags, and
/// also displayed at the top of the help output.
///
@internal
pub fn print_glimr_version() -> Nil {
  io.println("Glimr Framework " <> console.success(glimr.get_version()))
}

// ------------------------------------------------------------- Private Functions

/// Filters the list of commands given and finds the desired
/// command by the name that is provided. Returns Ok(Command)
/// if found, or Error(Nil) if no command matches.
///
fn find(commands: List(Command), name: String) -> Result(Command, Nil) {
  list.find(commands, fn(cmd) {
    case cmd {
      Command(cmd_name, _, _, _) -> cmd_name == name
      CommandWithDb(cmd_name, _, _, _) -> cmd_name == name
    }
  })
}

/// Executes a command by calling its handler function.
/// Checks for help flag first, then parses and validates
/// arguments before calling the handler. For CommandWithDb,
/// starts pool, provides connection, and cleans up.
///
fn run(
  cmd: Command,
  raw_args: List(String),
  connections: List(Connection),
) -> Nil {
  case has_help_flag(raw_args) {
    True -> print_command_help(cmd)
    False -> {
      case cmd {
        Command(name, _, args, handler) -> {
          case parse_and_validate(name, args, raw_args) {
            Ok(parsed) -> handler(parsed)
            Error(_) -> Nil
          }
        }
        CommandWithDb(name, _, args, handler) -> {
          case parse_and_validate(name, args, raw_args) {
            Ok(parsed) -> run_with_db(handler, parsed, connections)
            Error(_) -> Nil
          }
        }
      }
    }
  }
}

/// Runs a database command handler with a managed pool.
/// Looks up connection by --database option (defaults to "default"),
/// starts pool, runs handler, stops pool.
///
fn run_with_db(
  handler: fn(ParsedArgs, Pool) -> Nil,
  parsed: ParsedArgs,
  connections: List(Connection),
) -> Nil {
  let db_name = get_option(parsed, "database")

  case db.get_connection_safe(connections, db_name) {
    Error(_) -> {
      console.output()
      |> console.line_error(
        "Database connection \""
        <> db_name
        <> "\" does not exist in your config.",
      )
      |> console.print()
    }
    Ok(connection_config) -> {
      // Use pool size of 1 for console commands
      let connection_config = driver.with_pool_size(connection_config, 1)
      case db.start_pool(connection_config) {
        Error(ConfigError(message)) -> {
          console.output()
          |> console.line_error("There's an issue with your config_db:")
          |> console.line(message)
          |> console.print()
        }
        Error(err) -> {
          console.output()
          |> console.line_error("Failed to start database pool.")
          |> console.blank_line()
          |> console.line(string.inspect(err))
          |> console.print()
        }
        Ok(db_pool) -> {
          handler(parsed, db_pool)
          pool.stop(db_pool)
        }
      }
    }
  }
}

/// Checks if the raw arguments contain -h or --help flag.
/// Used to determine if the user is requesting help for a
/// specific command instead of running it.
///
fn has_help_flag(raw_args: List(String)) -> Bool {
  list.any(raw_args, fn(arg) { arg == "-h" || arg == "--help" })
}

/// Groups commands by their namespace (the part before the colon).
/// Commands within each group are sorted alphabetically by name.
/// Returns a list of tuples containing namespace and its commands.
///
fn group_by_namespace(commands: List(Command)) -> List(#(String, List(Command))) {
  // Sort all commands first
  let sorted =
    list.sort(commands, fn(a, b) {
      let name_a = case a {
        Command(n, _, _, _) -> n
        CommandWithDb(n, _, _, _) -> n
      }
      let name_b = case b {
        Command(n, _, _, _) -> n
        CommandWithDb(n, _, _, _) -> n
      }
      string.compare(name_a, name_b)
    })

  // Group by namespace
  list.fold(sorted, [], fn(acc, cmd) {
    let cmd_name = case cmd {
      Command(n, _, _, _) -> n
      CommandWithDb(n, _, _, _) -> n
    }
    let namespace = case string.split(cmd_name, ":") {
      [ns, ..] -> ns
      _ -> ""
    }
    case list.key_find(acc, namespace) {
      Ok(existing) -> list.key_set(acc, namespace, list.append(existing, [cmd]))
      Error(_) -> list.append(acc, [#(namespace, [cmd])])
    }
  })
}

/// Prints detailed help for a specific command showing
/// its description, usage, arguments, flags, and options. Called
/// when a command is invoked with -h or --help flag.
///
fn print_command_help(cmd: Command) -> Nil {
  let #(name, description, args) = case cmd {
    Command(n, d, a, _) -> #(n, d, a)
    CommandWithDb(n, d, a, _) -> #(n, d, a)
  }

  // Description
  io.println(console.warning("Description:"))
  io.println("  " <> description)
  io.println("")

  // Usage
  io.println(console.warning("Usage:"))
  let usage_line = build_usage_line(name, args)
  io.println("  " <> usage_line)
  io.println("")

  // Arguments section
  let arguments =
    list.filter_map(args, fn(arg) {
      case arg {
        Argument(arg_name, arg_desc) -> Ok(#(arg_name, arg_desc))
        Flag(_, _, _) -> Error(Nil)
        Option(_, _, _) -> Error(Nil)
      }
    })

  case arguments {
    [] -> Nil
    _ -> {
      io.println(console.warning("Arguments:"))
      let max_arg_len =
        list.fold(arguments, 0, fn(acc, arg) {
          int.max(acc, string.length(arg.0))
        })
      list.each(arguments, fn(arg) {
        let padded = string.pad_end(arg.0, max_arg_len + 2, " ")
        io.println("  " <> console.success(padded) <> arg.1)
      })
      io.println("")
    }
  }

  // Extract flags and options
  let flags =
    list.filter_map(args, fn(arg) {
      case arg {
        Flag(flag_name, short, flag_desc) -> Ok(#(flag_name, short, flag_desc))
        Argument(_, _) -> Error(Nil)
        Option(_, _, _) -> Error(Nil)
      }
    })

  let options =
    list.filter_map(args, fn(arg) {
      case arg {
        Option(opt_name, opt_desc, opt_default) ->
          Ok(#(opt_name, opt_desc, opt_default))
        Argument(_, _) -> Error(Nil)
        Flag(_, _, _) -> Error(Nil)
      }
    })

  // Calculate max length for alignment across flags and options
  let max_flag_len =
    list.fold(flags, string.length("-h, --help"), fn(acc, flag) {
      let #(flag_name, short, _) = flag
      let label = case short {
        "" -> "    --" <> flag_name
        _ -> "-" <> short <> ", --" <> flag_name
      }
      int.max(acc, string.length(label))
    })

  let max_opt_len =
    list.fold(options, 0, fn(acc, opt) {
      let #(opt_name, _, _) = opt
      let label = "    --" <> opt_name <> "=<value>"
      int.max(acc, string.length(label))
    })

  let max_len = int.max(max_flag_len, max_opt_len)

  // Flags section (includes -h, --help)
  io.println(console.warning("Flags:"))
  list.each(flags, fn(flag) {
    let #(flag_name, short, flag_desc) = flag
    let label = case short {
      "" -> "    --" <> flag_name
      _ -> "-" <> short <> ", --" <> flag_name
    }
    let padded = string.pad_end(label, max_len + 2, " ")
    io.println("  " <> console.success(padded) <> flag_desc)
  })

  // Always show -h, --help
  let help_label = string.pad_end("-h, --help", max_len + 2, " ")
  io.println(
    "  " <> console.success(help_label) <> "Display help for this command",
  )
  io.println("")

  // Options section (only if there are options with values)
  case options {
    [] -> Nil
    _ -> {
      io.println(console.warning("Options:"))
      list.each(options, fn(opt) {
        let #(opt_name, opt_desc, opt_default) = opt
        let label = "    --" <> opt_name <> "=<value>"
        let padded = string.pad_end(label, max_len + 2, " ")
        let desc_with_default = opt_desc <> " [default: " <> opt_default <> "]"
        io.println("  " <> console.success(padded) <> desc_with_default)
      })
      io.println("")
    }
  }
}

/// Builds the usage line showing command name, flags/options placeholder,
/// and argument placeholders in the correct format. Arguments are
/// shown as <name> and flags/options as [options] when present.
///
fn build_usage_line(name: String, args: List(CommandArg)) -> String {
  let has_flags_or_options =
    list.any(args, fn(arg) {
      case arg {
        Flag(_, _, _) -> True
        Option(_, _, _) -> True
        Argument(_, _) -> False
      }
    })

  let arg_placeholders =
    list.filter_map(args, fn(arg) {
      case arg {
        Argument(arg_name, _) -> Ok("<" <> arg_name <> ">")
        Flag(_, _, _) -> Error(Nil)
        Option(_, _, _) -> Error(Nil)
      }
    })
    |> string.join(" ")

  case has_flags_or_options, arg_placeholders {
    True, "" -> name <> " [options]"
    True, _ -> name <> " [options] " <> arg_placeholders
    False, "" -> name
    False, _ -> name <> " " <> arg_placeholders
  }
}

/// Parses raw CLI arguments against command argument
/// definitions. Validates that all required Arguments are
/// provided. Returns ParsedArgs on success, prints error and
/// returns Error on failure.
///
fn parse_and_validate(
  cmd_name: String,
  arg_defs: List(CommandArg),
  raw_args: List(String),
) -> Result(ParsedArgs, Nil) {
  let argument_defs =
    list.filter_map(arg_defs, fn(def) {
      case def {
        Argument(name, _) -> Ok(name)
        Flag(_, _, _) -> Error(Nil)
        Option(_, _, _) -> Error(Nil)
      }
    })

  let flag_defs =
    list.filter_map(arg_defs, fn(def) {
      case def {
        Flag(name, short, _) -> Ok(#(name, short))
        Argument(_, _) -> Error(Nil)
        Option(_, _, _) -> Error(Nil)
      }
    })

  let option_defs =
    list.filter_map(arg_defs, fn(def) {
      case def {
        Option(name, _, _) -> Ok(name)
        Argument(_, _) -> Error(Nil)
        Flag(_, _, _) -> Error(Nil)
      }
    })

  // Get option defaults
  let option_defaults =
    list.filter_map(arg_defs, fn(def) {
      case def {
        Option(name, _, default) -> Ok(#(name, default))
        Argument(_, _) -> Error(Nil)
        Flag(_, _, _) -> Error(Nil)
      }
    })
    |> dict.from_list

  // Parse flags and options from raw args
  let #(positional_values, parsed_flags, parsed_options) =
    parse_raw_args(raw_args, flag_defs, option_defs)

  // Merge defaults with parsed options (parsed values take precedence)
  let options_with_defaults = dict.merge(option_defaults, parsed_options)

  // Match positional values to argument definitions
  let arguments =
    list.index_map(argument_defs, fn(name, i) {
      let value =
        positional_values
        |> list.drop(i)
        |> list.first
      case value {
        Ok(v) -> #(name, v)
        Error(_) -> #(name, "")
      }
    })
    |> list.filter(fn(pair) { pair.1 != "" })
    |> dict.from_list

  // Check for missing required arguments
  let missing =
    list.filter(argument_defs, fn(name) {
      case dict.get(arguments, name) {
        Ok(_) -> False
        Error(_) -> True
      }
    })

  case missing {
    [] ->
      Ok(ParsedArgs(
        arguments: arguments,
        flags: parsed_flags,
        options: options_with_defaults,
      ))
    _ -> {
      io.println(
        console.error("Error: Missing required argument(s): ")
        <> string.join(missing, ", "),
      )
      io.println("")
      print_usage(cmd_name, arg_defs)
      Error(Nil)
    }
  }
}

/// Parses raw CLI args into positional values, flags, and options.
/// Flags are boolean (--flag or -f), options have values (--opt=val).
/// Returns a tuple of #(positional_values, flag_names, option_dict).
///
fn parse_raw_args(
  raw_args: List(String),
  flag_defs: List(#(String, String)),
  option_defs: List(String),
) -> #(List(String), List(String), Dict(String, String)) {
  let #(positional, flags, options) =
    list.fold(raw_args, #([], [], dict.new()), fn(acc, arg) {
      let #(pos, flgs, opts) = acc
      case string.starts_with(arg, "--") {
        True -> {
          let rest = string.drop_start(arg, 2)
          // Check if it's an option with value (--option=value)
          case string.split_once(rest, "=") {
            Ok(#(opt_name, opt_value)) -> {
              case list.contains(option_defs, opt_name) {
                True -> #(pos, flgs, dict.insert(opts, opt_name, opt_value))
                False -> #(pos, flgs, opts)
              }
            }
            Error(_) -> {
              // It's a flag (--flag)
              case list.find(flag_defs, fn(def) { def.0 == rest }) {
                Ok(#(name, _)) -> #(pos, [name, ..flgs], opts)
                Error(_) -> #(pos, flgs, opts)
              }
            }
          }
        }
        False ->
          case string.starts_with(arg, "-") {
            True -> {
              let rest = string.drop_start(arg, 1)
              // It's a short flag (-f)
              case list.find(flag_defs, fn(def) { def.1 == rest }) {
                Ok(#(name, _)) -> #(pos, [name, ..flgs], opts)
                Error(_) -> #(pos, flgs, opts)
              }
            }
            False -> #([arg, ..pos], flgs, opts)
          }
      }
    })

  #(list.reverse(positional), flags, options)
}

/// Prints usage information for a command showing required
/// arguments and available flags/options. Called when validation
/// fails to help users understand the expected syntax.
///
fn print_usage(cmd_name: String, arg_defs: List(CommandArg)) -> Nil {
  let arg_names =
    list.filter_map(arg_defs, fn(def) {
      case def {
        Argument(name, _) -> Ok("<" <> name <> ">")
        Flag(_, _, _) -> Error(Nil)
        Option(_, _, _) -> Error(Nil)
      }
    })
    |> string.join(" ")

  let flag_names =
    list.filter_map(arg_defs, fn(def) {
      case def {
        Flag(name, _, _) -> Ok("[--" <> name <> "]")
        Argument(_, _) -> Error(Nil)
        Option(_, _, _) -> Error(Nil)
      }
    })
    |> string.join(" ")

  let option_names =
    list.filter_map(arg_defs, fn(def) {
      case def {
        Option(name, _, _) -> Ok("[--" <> name <> "=<value>]")
        Argument(_, _) -> Error(Nil)
        Flag(_, _, _) -> Error(Nil)
      }
    })
    |> string.join(" ")

  let flags_and_options = case flag_names, option_names {
    "", "" -> ""
    f, "" -> f
    "", o -> o
    f, o -> f <> " " <> o
  }

  let usage = case flags_and_options {
    "" -> cmd_name <> " " <> arg_names
    _ -> cmd_name <> " " <> arg_names <> " " <> flags_and_options
  }

  io.println(console.warning("Usage: ") <> usage)
}

/// Default handler for commands without a handler set.
/// Prints an error message indicating the command is not
/// properly configured. Used as placeholder during setup.
///
fn temp_handler(_args: ParsedArgs) -> Nil {
  io.println(console.error(
    "A handler function has not been set for this command.",
  ))
}

// ------------------------------------------------------------- FFI Bindings

/// External call to Erlang's init:get_plain_arguments/0 which
/// returns command-line arguments as a list of charlists. Used
/// internally by get_args() to retrieve CLI arguments.
///
@external(erlang, "init", "get_plain_arguments")
fn erlang_get_args() -> List(charlist.Charlist)
