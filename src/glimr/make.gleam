//// ------------------------------------------------------------
//// Make Commands
//// ------------------------------------------------------------
////
//// CLI commands for generating boilerplate code. Provides 
//// commands to scaffold controllers, middleware, form requests, 
//// and validation rules. Automatically creates nested 
//// directories if they don't exist.
////

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/charlist
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glimr/db/driver
import glimr/db/gen as db_gen
import glimr/db/gen/migrate as gen_migrate
import glimr/db/migrate as db_migrate
import glimr/utils/string as string_utils
import shellout
import simplifile
import wisp

// ------------------------------------------------------------- Private Types

/// ------------------------------------------------------------
/// Flags Type
/// ------------------------------------------------------------
///
/// Container for parsed command-line flags. Extracted from
/// arguments before command matching, allowing flags to appear
/// in any position. Boolean flags default to False, optional
/// values default to None.
///
type Flags {
  Flags(
    resource: Bool,
    file: Bool,
    migrate: Bool,
    models: Option(List(String)),
    conns: Option(List(String)),
  )
}

// ------------------------------------------------------------- Public Functions

/// ------------------------------------------------------------
/// Main Entry Point
/// ------------------------------------------------------------
///
/// The main entry point for the Glimr make command system.
/// Parses command-line arguments and delegates to the
/// appropriate generator function. Use via the `./glimr` 
/// wrapper script for a Laravel-style CLI experience.
///
pub fn main() {
  let args = get_args()
  let #(flags, positional) = parse_flags(args)

  case positional {
    // Make commands
    ["make:controller", name] -> make_controller(name, resource: flags.resource)
    ["make:middleware", name] -> make_middleware(name)
    ["make:model", name] -> make_model(name, flags.conns)
    ["make:request", name] -> make_request(name)
    ["make:rule", name] -> make_rule(name, file: flags.file)
    ["make:action", name] -> make_action(name)
    ["setup:sqlite"] -> setup_sqlite()
    ["setup:database"] -> setup_database()

    // Database commands
    ["db:migrate"] -> db_migrate.main()
    ["db:fresh"] -> db_migrate.run_fresh()

    // Generator commands
    ["gen:db"] -> gen_db(flags)

    _ -> print_help()
  }
}

// ------------------------------------------------------------- Private Constants

/// ------------------------------------------------------------
/// Databases Config Path
/// ------------------------------------------------------------
///
const databases_config_path = "src/data/._databases.json"

// ------------------------------------------------------------- Private Functions

// TODO: properly document this
fn print_help() {
  io.println("Glimr Framework")
  io.println("")
  io.println("Usage: ./glimr <command> [arguments]")
  io.println("")
  io.println("Available Commands:")
  io.println("")
  io.println(
    "  make:controller <name>                      Create a new controller. Appends _controller to the end of the name",
  )
  io.println(
    "  make:controller <name> --resource           Create a resource controller",
  )
  io.println(
    "  make:middleware <name>                      Create a new middleware",
  )
  io.println(
    "  make:model <name>                           Create a new model (for 'default' connection)",
  )
  io.println(
    "  make:model <name> --connection=<name>       Create model for specific connection",
  )
  io.println(
    "  make:request <name>                         Create a form request. Appends _request to the end of the name",
  )
  io.println(
    "  make:rule <name>                            Create a validation rule",
  )
  io.println(
    "  make:rule <name> --file                     Create a file validation rule",
  )
  io.println(
    "  make:action <name>                          Create an action. Should return a result type",
  )
  io.println("")
  io.println(
    "  setup:database                              Set up a new database connection",
  )
  io.println("")
  io.println(
    "  db:migrate                                  Run pending migrations",
  )
  io.println(
    "  db:fresh                                    Drop database and re-run migrations",
  )
  io.println("")
  io.println(
    "  gen:db                                      Generate repository/migration code (uses 'default' connection)",
  )
  io.println(
    "  gen:db --connection=<name>                  Generate repository/migraiton code for specific connection",
  )
  io.println(
    "  gen:db --connection=<name> --model=<x>      Generate repository/migration code for specific model(s) only",
  )
  io.println("")
  io.println("Examples:")
  io.println("  ./glimr make:controller user")
  io.println("  ./glimr make:controller post --resource")
  io.println("  ./glimr make:middleware auth")
  io.println("  ./glimr make:model user")
  io.println("  ./glimr make:model user --connection=analytics")
  io.println("  ./glimr make:request store_user")
  io.println("  ./glimr make:rule username_available")
  io.println("  ./glimr make:action store_user")
  io.println("  ./glimr setup:database")
  io.println("  ./glimr db:migrate")
  io.println("  ./glimr db:fresh")
  io.println("  ./glimr gen:db")
  io.println("  ./glimr gen:db --connection=main")
  io.println("  ./glimr gen:db --connection=main --model=user")
}

/// ------------------------------------------------------------
/// Validate Models
/// ------------------------------------------------------------
///
/// Validates that specified model directories exist. Returns
/// Ok(None) if no models specified (meaning all models),
/// Ok(Some(models)) if all specified models exist, or
/// Error(invalid_models) if any models don't exist.
///
fn validate_models(
  models_path: String,
  models: Option(List(String)),
) -> Result(Option(List(String)), List(String)) {
  case models {
    None -> Ok(None)
    Some(model_list) -> {
      let #(valid, invalid) =
        list.partition(model_list, fn(model) {
          case simplifile.is_directory(models_path <> "/" <> model) {
            Ok(True) -> True
            _ -> False
          }
        })
      case invalid {
        [] -> Ok(Some(valid))
        _ -> Error(invalid)
      }
    }
  }
}

/// ------------------------------------------------------------
/// Load Databases Config
/// ------------------------------------------------------------
///
/// Reads the _databases.json file and returns a Dict mapping
/// database names to their driver types.
///
fn load_databases_config() -> Result(Dict(String, String), Nil) {
  case simplifile.read(databases_config_path) {
    Error(_) -> Error(Nil)
    Ok(content) -> {
      let decoder = decode.dict(decode.string, decode.string)
      case json.parse(content, using: decoder) {
        Ok(databases) -> Ok(databases)
        Error(_) -> Error(Nil)
      }
    }
  }
}

/// ------------------------------------------------------------
/// Save Databases Config
/// ------------------------------------------------------------
///
/// Writes the databases Dict to _databases.json.
///
fn save_databases_config(databases: Dict(String, String)) -> Result(Nil, Nil) {
  let content =
    databases
    |> dict.to_list
    |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })
    |> json.object
    |> json.to_string

  case simplifile.write(databases_config_path, content) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(Nil)
  }
}

/// ------------------------------------------------------------
/// Setup Database
/// ------------------------------------------------------------
///
/// Interactive setup for a new database connection. Prompts for
/// driver type and connection name, then creates the folder
/// structure and updates _databases.json.
///
fn setup_database() {
  io.println("Database Setup")
  io.println("==============")
  io.println("")

  // Prompt for driver type
  io.println("Select database driver:")
  io.println("  1. sqlite")
  io.println("  2. postgres")
  io.println("  3. postgres (URI)")
  io.println("")
  let driver_type = case prompt("Enter choice [1]: ") {
    "" | "1" -> "sqlite"
    "2" -> "postgres"
    "3" -> "postgres"
    other -> {
      io.println("Invalid choice: " <> other)
      io.println("Using sqlite as default.")
      "sqlite"
    }
  }
  io.println("")

  // Prompt for connection name
  let name =
    case prompt("Enter connection name [default]: ") {
      "" -> "default"
      n -> n
    }
    |> string.lowercase
    |> string.replace(" ", "_")

  io.println("")

  // Create folder structure
  let base_path = "src/data/" <> name
  let models_path = base_path <> "/models"

  case simplifile.create_directory_all(models_path) {
    Ok(_) | Error(simplifile.Eexist) -> {
      io.println("Created: " <> models_path)

      // Generate phantom type file
      generate_db_type_file(base_path, name)

      // Update _databases.json
      let databases = case load_databases_config() {
        Ok(existing) -> existing
        Error(_) -> dict.new()
      }
      let databases = dict.insert(databases, name, driver_type)

      case save_databases_config(databases) {
        Ok(_) -> {
          io.println("Updated: " <> databases_config_path)
          io.println("")
          io.println(
            "Database '"
            <> name
            <> "' configured with driver '"
            <> driver_type
            <> "'",
          )
          io.println("")
          io.println("Next steps:")
          io.println(
            "  1. Create a model: ./glimr make:model user --connection=" <> name,
          )
          io.println(
            "  2. Generate code:  ./glimr gen:db --connection=" <> name,
          )
        }
        Error(_) -> {
          io.println("Error: Could not update " <> databases_config_path)
        }
      }
    }
    Error(_) -> {
      io.println("Error: Could not create directory " <> models_path)
    }
  }
}

/// ------------------------------------------------------------
/// Gen DB
/// ------------------------------------------------------------
///
/// Generates database code (migrations and repositories) for the
/// specified connections and models. Loads database configuration,
/// validates the connection exists, and runs the migration and
/// code generators.
///
fn gen_db(flags: Flags) {
  let red = "\u{001b}[31m"
  let reset = "\u{001b}[0m"

  // Load database config
  case load_databases_config() {
    Error(_) -> {
      io.println(red <> "Error: No databases configured." <> reset)
      io.println("Run `./glimr setup:database` to set up a database.")
    }
    Ok(databases) -> {
      // Default to "default" if no --connection flag, but verify it exists
      let connection_names = case flags.conns {
        Some(names) -> Ok(names)
        None -> {
          case dict.get(databases, "default") {
            Ok(_) -> Ok(["default"])
            Error(_) -> Error(Nil)
          }
        }
      }

      case connection_names {
        Error(_) -> {
          io.println(red <> "Error: No 'default' database configured." <> reset)
          io.println("")
          io.println("Either:")
          io.println("  1. Run `./glimr setup:database` and name it 'default'")
          io.println(
            "  2. Use `./glimr gen:db --connection=<name>` to specify a database",
          )
        }
        Ok(names) -> {
          list.each(names, fn(name) {
            case dict.get(databases, name) {
              Error(_) -> {
                io.println(
                  red <> "Error: Database '" <> name <> "' not found." <> reset,
                )
                io.println(
                  "Run `./glimr setup:database` to set up this database.",
                )
              }
              Ok(driver_type) -> {
                let models_path = "src/data/" <> name <> "/models"
                case validate_models(models_path, flags.models) {
                  Error(invalid) -> {
                    io.println(
                      red
                      <> "Error: Model(s) not found in "
                      <> models_path
                      <> ": "
                      <> string.join(invalid, ", ")
                      <> reset,
                    )
                  }
                  Ok(model_filter) -> {
                    io.println("")
                    gen_migrate.run(name, driver_type, model_filter)
                    io.println("")
                    db_gen.run(name, driver_type, model_filter)

                    // Run migrations if --migrate flag is set
                    case flags.migrate {
                      True -> {
                        io.println("")
                        db_migrate.main()
                      }
                      False -> Nil
                    }
                  }
                }
              }
            }
          })
        }
      }
    }
  }
}

/// ------------------------------------------------------------
/// Generate DB Type File
/// ------------------------------------------------------------
///
/// Generates the database type file with the phantom type.
///
fn generate_db_type_file(base_path: String, name: String) {
  let pascal_name = driver.to_pascal_case(name)
  let type_name = pascal_name <> "Conn"

  let content =
    "//// ------------------------------------------------------------\n"
    <> "//// Connection Type: "
    <> name
    <> "\n"
    <> "//// ------------------------------------------------------------\n"
    <> "////\n"
    <> "//// This file is generated by glimr. Do not edit.\n"
    <> "////\n"
    <> "//// The phantom type "
    <> type_name
    <> " enables compile-time checking\n"
    <> "//// to prevent cross-connection queries in transactions.\n"
    <> "////\n\n"
    <> "/// The phantom type for the "
    <> name
    <> " connection.\n"
    <> "pub type "
    <> type_name
    <> "\n"

  let file_path = base_path <> "/" <> name <> ".gleam"

  case simplifile.write(file_path, content) {
    Ok(_) -> {
      let _ = shellout.command("gleam", ["format", file_path], ".", [])
      io.println("Created: " <> file_path)
    }
    Error(_) -> io.println("Error: Could not write " <> file_path)
  }
}

/// ------------------------------------------------------------
/// Prompt
/// ------------------------------------------------------------
///
/// Displays a prompt and reads a line of input from stdin.
///
fn prompt(message: String) -> String {
  io.print(message)
  case read_line() {
    Ok(line) -> string.trim(line)
    Error(_) -> ""
  }
}

@external(erlang, "io", "get_line")
fn do_get_line(prompt: charlist.Charlist) -> charlist.Charlist

fn read_line() -> Result(String, Nil) {
  let line = do_get_line(charlist.from_string(""))
  Ok(charlist.to_string(line))
}

/// ------------------------------------------------------------
/// Parse Flags
/// ------------------------------------------------------------
///
/// Extracts flags from command-line arguments and returns both
/// the parsed flags and the remaining positional arguments.
/// Supports both long (--flag) and short (-f) flag formats.
///
fn parse_flags(args: List(String)) -> #(Flags, List(String)) {
  let flags =
    Flags(
      resource: False,
      file: False,
      migrate: False,
      models: None,
      conns: None,
    )
  do_parse_flags(args, flags, [])
}

fn do_parse_flags(
  args: List(String),
  flags: Flags,
  positional: List(String),
) -> #(Flags, List(String)) {
  case args {
    [] -> #(flags, list.reverse(positional))
    ["--resource", ..rest] | ["-r", ..rest] ->
      do_parse_flags(rest, Flags(..flags, resource: True), positional)
    ["--file", ..rest] | ["-f", ..rest] ->
      do_parse_flags(rest, Flags(..flags, file: True), positional)
    ["--migrate", ..rest] | ["-m", ..rest] ->
      do_parse_flags(rest, Flags(..flags, migrate: True), positional)
    [arg, ..rest] -> {
      // Check for --model=value pattern
      case string.split_once(arg, "--model=") {
        Ok(#("", value)) -> {
          let models =
            string.split(value, ",")
            |> list.map(string.trim)
            |> list.filter(fn(s) { s != "" })
          do_parse_flags(rest, Flags(..flags, models: Some(models)), positional)
        }
        _ -> {
          // Check for --connection=value pattern
          case string.split_once(arg, "--connection=") {
            Ok(#("", value)) -> {
              let conns =
                string.split(value, ",")
                |> list.map(string.trim)
                |> list.filter(fn(s) { s != "" })
              do_parse_flags(
                rest,
                Flags(..flags, conns: Some(conns)),
                positional,
              )
            }
            _ -> do_parse_flags(rest, flags, [arg, ..positional])
          }
        }
      }
    }
  }
}

/// ------------------------------------------------------------
/// Make Controller
/// ------------------------------------------------------------
///
/// Creates a controller file from a stub template. Supports
/// both basic controllers (index method only) and resource
/// controllers (full CRUD: index, show, store, edit, update,
/// delete). Automatically creates nested directories if they
/// don't exist.
///
fn make_controller(name: String, resource resource: Bool) {
  let module_name = to_snake_case(name) <> "_controller"
  let file_path = "src/app/http/controllers/" <> module_name <> ".gleam"

  let stub_name = case resource {
    True -> "controller_resource.stub"
    False -> "controller.stub"
  }

  case read_stub("http/" <> stub_name) {
    Ok(content) -> {
      let _ = ensure_directory_exists(file_path)
      case simplifile.write(file_path, content) {
        Ok(_) -> {
          io.println("Controller created successfully!")
          io.println("  " <> file_path)
        }
        Error(_) -> io.println("Error: Could not write file " <> file_path)
      }
    }
    Error(_) -> io.println("Error: Could not read stub file")
  }
}

/// ------------------------------------------------------------
/// Make Middleware
/// ------------------------------------------------------------
///
/// Creates a middleware file from a stub template. The
/// generated middleware includes a handle function with Request, 
/// Context, and Next parameters. Automatically creates nested 
/// directories if they don't exist.
///
fn make_middleware(name: String) {
  let module_name = to_snake_case(name)
  let file_path = "src/app/http/middleware/" <> module_name <> ".gleam"

  case read_stub("http/middleware.stub") {
    Ok(content) -> {
      let _ = ensure_directory_exists(file_path)
      case simplifile.write(file_path, content) {
        Ok(_) -> {
          io.println("Middleware created successfully!")
          io.println("  " <> file_path)
        }
        Error(_) -> io.println("Error: Could not write file " <> file_path)
      }
    }
    Error(_) -> io.println("Error: Could not read stub file")
  }
}

/// ------------------------------------------------------------
/// Make Request
/// ------------------------------------------------------------
///
/// Creates a form request validation file from a stub template.
/// The generated file includes rules() and data() functions for
/// validating and extracting form data. Automatically creates
/// nested directories if they don't exist.
///
fn make_request(name: String) {
  let module_name = to_snake_case(name) <> "_request"
  let file_path = "src/app/http/requests/" <> module_name <> ".gleam"

  case read_stub("http/request.stub") {
    Ok(content) -> {
      let _ = ensure_directory_exists(file_path)
      case simplifile.write(file_path, content) {
        Ok(_) -> {
          io.println("Request created successfully!")
          io.println("  " <> file_path)
        }
        Error(_) -> io.println("Error: Could not write file " <> file_path)
      }
    }
    Error(_) -> io.println("Error: Could not read stub file")
  }
}

/// ------------------------------------------------------------
/// Make Rule
/// ------------------------------------------------------------
///
/// Creates a custom validation rule file from a stub template.
/// Supports both text validation rules and file validation
/// rules. The generated file includes a validate() function
/// that returns a custom validation function. Automatically
/// creates nested directories if they don't exist.
///
fn make_rule(name: String, file file: Bool) {
  let module_name = to_snake_case(name)
  let file_path = "src/app/http/rules/" <> module_name <> ".gleam"

  let stub_name = case file {
    True -> "rule_file.stub"
    False -> "rule.stub"
  }

  case read_stub("http/" <> stub_name) {
    Ok(content) -> {
      let _ = ensure_directory_exists(file_path)
      case simplifile.write(file_path, content) {
        Ok(_) -> {
          io.println("Rule created successfully!")
          io.println("  " <> file_path)
        }
        Error(_) -> io.println("Error: Could not write file " <> file_path)
      }
    }
    Error(_) -> io.println("Error: Could not read stub file")
  }
}

/// ------------------------------------------------------------
/// Make Action
/// ------------------------------------------------------------
///
/// Creates an action file from a stub template. Actions are
/// single-purpose classes that encapsulate a specific business
/// operation, promoting the single responsibility principle.
/// Automatically creates nested directories if they don't 
/// exist.
///
fn make_action(name: String) {
  let module_name = to_snake_case(name)
  let file_path = "src/app/actions/" <> module_name <> ".gleam"
  let stub_name = "action.stub"

  case read_stub(stub_name) {
    Ok(content) -> {
      let _ = ensure_directory_exists(file_path)
      case simplifile.write(file_path, content) {
        Ok(_) -> {
          io.println("Action created successfully!")
          io.println("  " <> file_path)
        }
        Error(_) -> io.println("Error: Could not write file " <> file_path)
      }
    }
    Error(_) -> io.println("Error: Could not read stub file")
  }
}

/// ------------------------------------------------------------
/// Make Model
/// ------------------------------------------------------------
///
/// Creates a new model directory with schema and query stubs.
/// The model directory is created in src/data/{driver}/models/
/// with a schema file and query stubs. The table name is
/// automatically pluralized from the model name.
///
/// If no connection is specified, defaults to "default" if it exists.
///
fn make_model(name: String, connections: Option(List(String))) {
  let red = "\u{001b}[31m"
  let reset = "\u{001b}[0m"

  // Load database config
  case load_databases_config() {
    Error(_) -> {
      io.println(red <> "Error: No databases configured." <> reset)
      io.println("Run `./glimr setup:database` to set up a database.")
    }
    Ok(databases) -> {
      // Determine which connection to use
      let connection_name = case connections {
        Some([first, ..]) -> Ok(first)
        Some([]) | None -> {
          case dict.get(databases, "default") {
            Ok(_) -> Ok("default")
            Error(_) -> Error(Nil)
          }
        }
      }

      case connection_name {
        Error(_) -> {
          io.println(
            red <> "Error: No 'default' connection configured." <> reset,
          )
          io.println("")
          io.println("Either:")
          io.println("  1. Run `./glimr setup:database` and name it 'default'")
          io.println(
            "  2. Use `./glimr make:model " <> name <> " --connection=<name>`",
          )
        }
        Ok(connection) -> {
          case dict.get(databases, connection) {
            Error(_) -> {
              io.println(
                red
                <> "Error: Connection '"
                <> connection
                <> "' not found."
                <> reset,
              )
              io.println(
                "Run `./glimr setup:database` to set up this connection.",
              )
            }
            Ok(_driver_type) -> {
              let model_name = to_snake_case(name)
              let table_name = string_utils.pluralize(model_name)
              let model_dir =
                "src/data/" <> connection <> "/models/" <> model_name
              let queries_dir = model_dir <> "/queries"

              // Create directories
              let _ = simplifile.create_directory_all(queries_dir)

              io.println(
                "Creating model '"
                <> model_name
                <> "' in connection '"
                <> connection
                <> "'",
              )
              io.println("")

              // Create schema file
              case read_stub("data/schema.stub") {
                Ok(schema_content) -> {
                  let schema_path =
                    model_dir <> "/" <> model_name <> "_schema.gleam"
                  let schema_output =
                    string.replace(
                      schema_content,
                      "{{ table_name }}",
                      table_name,
                    )
                  case simplifile.write(schema_path, schema_output) {
                    Ok(_) -> io.println("  Created: " <> schema_path)
                    Error(_) ->
                      io.println("  Error: Could not write " <> schema_path)
                  }
                }
                Error(_) -> io.println("Error: Could not read schema stub")
              }

              // Create query files
              let query_stubs = [
                "create", "delete", "find", "list_all", "update",
              ]
              list.each(query_stubs, fn(query_name) {
                let stub_path = "data/queries/" <> query_name <> ".stub"
                case read_stub(stub_path) {
                  Ok(query_content) -> {
                    let query_path = queries_dir <> "/" <> query_name <> ".sql"
                    let query_output =
                      string.replace(
                        query_content,
                        "{{ table_name }}",
                        table_name,
                      )
                    case simplifile.write(query_path, query_output) {
                      Ok(_) -> io.println("  Created: " <> query_path)
                      Error(_) ->
                        io.println("  Error: Could not write " <> query_path)
                    }
                  }
                  Error(_) ->
                    io.println("  Warning: Could not read stub " <> stub_path)
                }
              })

              io.println("")
              io.println("Model created successfully!")
            }
          }
        }
      }
    }
  }
}

/// ------------------------------------------------------------
/// Setup SQLite
/// ------------------------------------------------------------
///
/// Creates the SQLite database directory and file, and updates
/// the .env file to configure DB_DRIVER and DB_DATABASE. Creates
/// the directory src/data/sqlite/ and an empty data.db file.
///
fn setup_sqlite() {
  // TODO: do this as part of setup:database if sqlite is chosen?
  let db_dir = "src/data/sqlite"
  let db_path = db_dir <> "/data.db"

  // Create directory
  case simplifile.create_directory_all(db_dir) {
    Ok(_) | Error(simplifile.Eexist) -> {
      // Create empty database file if it doesn't exist
      case simplifile.is_file(db_path) {
        Ok(True) -> {
          io.println("Database file already exists: " <> db_path)
        }
        _ -> {
          case simplifile.write(db_path, "") {
            Ok(_) -> io.println("Created database file: " <> db_path)
            Error(_) -> {
              io.println("Error: Could not create database file")
            }
          }
        }
      }
    }
    Error(_) -> {
      io.println("Error: Could not create directory " <> db_dir)
    }
  }
}

/// ------------------------------------------------------------
/// Read Stub
/// ------------------------------------------------------------
///
/// Reads a stub template file from the framework's priv
/// directory. The stub path is relative to priv/stubs/ and
/// returns an error if the file doesn't exist or can't be read.
///
fn read_stub(stub_path: String) -> Result(String, Nil) {
  case wisp.priv_directory("glimr") {
    Ok(priv_dir) -> {
      let full_path = priv_dir <> "/stubs/" <> stub_path
      simplifile.read(full_path)
      |> result.replace_error(Nil)
    }
    Error(_) -> Error(Nil)
  }
}

/// ------------------------------------------------------------
/// Ensure Directory Exists
/// ------------------------------------------------------------
///
/// Creates all parent directories for a given file path if they
/// don't already exist. Extracts the directory path from the
/// file path and uses create_directory_all to create the entire
/// directory tree.
///
fn ensure_directory_exists(
  file_path: String,
) -> Result(Nil, simplifile.FileError) {
  case get_directory_path(file_path) {
    "" -> Ok(Nil)
    dir -> simplifile.create_directory_all(dir)
  }
}

/// ------------------------------------------------------------
/// Get Directory Path
/// ------------------------------------------------------------
///
/// Extracts the directory portion of a file path by splitting
/// on slashes, removing the last segment (filename), and
/// rejoining the remaining parts. Returns an empty string if
/// there's no directory component.
///
fn get_directory_path(file_path: String) -> String {
  case string.split(file_path, "/") {
    [] -> ""
    parts -> {
      parts
      |> list.reverse
      |> list.drop(1)
      |> list.reverse
      |> string.join("/")
    }
  }
}

/// ------------------------------------------------------------
/// To Snake Case
/// ------------------------------------------------------------
///
/// Converts a string to snake_case by converting all characters
/// to lowercase. Used to normalize controller, middleware,
/// request, and rule names to follow Gleam naming conventions.
///
fn to_snake_case(name: String) -> String {
  name
  |> string.lowercase
}

/// ------------------------------------------------------------
/// Erlang Get Args
/// ------------------------------------------------------------
///
/// External call to Erlang's init:get_plain_arguments/0 which
/// returns command-line arguments as a list of charlists. Used
/// internally by get_args() to retrieve CLI arguments.
///
@external(erlang, "init", "get_plain_arguments")
fn erlang_get_args() -> List(charlist.Charlist)

/// ------------------------------------------------------------
/// Get Args
/// ------------------------------------------------------------
///
/// Retrieves command-line arguments as Gleam strings. Calls
/// the Erlang function to get raw charlists and converts them
/// to Gleam strings for easier processing.
///
fn get_args() -> List(String) {
  erlang_get_args()
  |> list.map(charlist.to_string)
}
