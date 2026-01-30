//// Annotation Parser
////
//// Parses route annotations from controller files. Extracts
//// HTTP method routes, middleware, and redirects from doc
//// comments preceding handler functions.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ------------------------------------------------------------- Public Types

/// Represents a function parameter with its name and type.
/// This is used to track handler signature for flexible 
/// parameter ordering.
///
pub type FunctionParam {
  FunctionParam(name: String, param_type: String)
}

/// Represents a parsed route from controller annotations.
/// Contains method, path, handler function name, middleware,
/// optional validator, and optional redirect configuration.
///
pub type ParsedRoute {
  ParsedRoute(
    method: String,
    path: String,
    handler: String,
    middleware: List(String),
    validator: Option(String),
    params: List(FunctionParam),
  )
  ParsedRedirect(from: String, to: String, status: Int)
}

/// Result of parsing a controller file. Contains group-level
/// middleware that applies to all routes, and the list of
/// parsed routes.
///
pub type ParseResult {
  ParseResult(group_middleware: List(String), routes: List(ParsedRoute))
}

// ------------------------------------------------------------- Public Functions

/// Parses a controller file for route annotations. Extracts
/// group middleware from file-level comments and routes from
/// doc comments preceding handler functions.
///
pub fn parse(content: String) -> Result(ParseResult, String) {
  let group_middleware = extract_group_middleware(content)
  let routes = extract_routes(content, group_middleware)

  Ok(ParseResult(group_middleware:, routes:))
}

// ------------------------------------------------------------- Private Functions

/// Extracts group middleware from file-level comments. Looks
/// for `// @group_middleware "path"` at the top of the file
/// before any function definitions.
///
fn extract_group_middleware(content: String) -> List(String) {
  content
  |> string.split("\n")
  |> list.take_while(fn(line) {
    let trimmed = string.trim(line)
    !string.starts_with(trimmed, "pub fn")
    && !string.starts_with(trimmed, "fn ")
  })
  |> list.filter_map(fn(line) {
    let trimmed = string.trim(line)
    case string.starts_with(trimmed, "// @group_middleware ") {
      True -> extract_quoted_arg(trimmed, "// @group_middleware ")
      False -> Error(Nil)
    }
  })
}

/// Extracts routes from doc comments in the content. Scans
/// for `/// @method "path"` patterns followed by `pub fn`
/// declarations.
///
fn extract_routes(
  content: String,
  group_middleware: List(String),
) -> List(ParsedRoute) {
  let lines = string.split(content, "\n")
  parse_lines(lines, group_middleware, None, [])
}

/// Extracts a quoted string argument from an annotation.
/// Parses `@annotation "value"` to get just the value.
/// Returns Error if no valid quoted string is found.
///
fn extract_quoted_arg(line: String, prefix: String) -> Result(String, Nil) {
  let after_prefix = string.drop_start(line, string.length(prefix))

  case string.starts_with(after_prefix, "\"") {
    True -> {
      let after_quote = string.drop_start(after_prefix, 1)
      case string.split_once(after_quote, "\"") {
        Ok(#(arg, _)) -> Ok(arg)
        Error(_) -> Error(Nil)
      }
    }
    False -> Error(Nil)
  }
}

/// State for tracking annotations while parsing lines.
/// Accumulates method, path, middleware, validator, and
/// redirects until a pub fn declaration completes the route.
///
type AnnotationState {
  AnnotationState(
    method: Option(String),
    path: Option(String),
    middleware: List(String),
    validator: Option(String),
    redirects: List(#(String, Int)),
  )
}

/// Recursively parses lines to extract routes. Accumulates
/// annotations from doc comments and creates routes when
/// a pub fn declaration is found.
///
fn parse_lines(
  lines: List(String),
  group_middleware: List(String),
  current: Option(AnnotationState),
  acc: List(ParsedRoute),
) -> List(ParsedRoute) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] -> {
      let trimmed = string.trim(line)

      // Check if this is a doc comment with annotation
      case string.starts_with(trimmed, "///") {
        True -> {
          let state = case current {
            Some(s) -> s
            None ->
              AnnotationState(
                method: None,
                path: None,
                middleware: [],
                validator: None,
                redirects: [],
              )
          }
          let new_state = parse_annotation_line(trimmed, state)
          parse_lines(rest, group_middleware, Some(new_state), acc)
        }
        False -> {
          // Check if this is a pub fn declaration
          case string.starts_with(trimmed, "pub fn ") {
            True -> {
              case current {
                Some(state) -> {
                  let fn_name = extract_fn_name(trimmed)
                  // Collect full signature (may span multiple lines)
                  let #(signature, remaining) =
                    collect_signature(line, rest, "")
                  let params = extract_fn_params(signature)
                  let new_routes =
                    create_routes_from_state(
                      state,
                      fn_name,
                      params,
                      group_middleware,
                    )
                  parse_lines(
                    remaining,
                    group_middleware,
                    None,
                    list.append(list.reverse(new_routes), acc),
                  )
                }
                None -> parse_lines(rest, group_middleware, None, acc)
              }
            }
            False -> {
              // Not a doc comment or pub fn, reset state if we hit
              // non-empty non-comment line
              case trimmed == "" || string.starts_with(trimmed, "//") {
                True -> parse_lines(rest, group_middleware, current, acc)
                False -> parse_lines(rest, group_middleware, None, acc)
              }
            }
          }
        }
      }
    }
  }
}

/// Collects the full function signature which may span multiple 
/// lines. Continues reading until the closing brace { is found
/// indicating the end of of the function signature.
///
fn collect_signature(
  current_line: String,
  remaining: List(String),
  acc: String,
) -> #(String, List(String)) {
  let new_acc = acc <> " " <> string.trim(current_line)

  // Check if we have the complete signature (contains the opening brace)
  case string.contains(new_acc, "{") {
    True -> #(new_acc, remaining)
    False -> {
      case remaining {
        [] -> #(new_acc, [])
        [next, ..rest] -> collect_signature(next, rest, new_acc)
      }
    }
  }
}

/// Parses a single annotation line and updates state. Handles
/// method annotations, middleware, validators, and redirects.
/// Returns updated state with any new annotation values added.
///
fn parse_annotation_line(
  line: String,
  state: AnnotationState,
) -> AnnotationState {
  let after_slashes = string.drop_start(line, 3) |> string.trim_start

  // Check for HTTP method annotations
  let methods = ["get", "post", "put", "patch", "delete", "head", "options"]
  let method_match =
    list.find(methods, fn(method) {
      string.starts_with(after_slashes, "@" <> method <> " ")
    })

  case method_match {
    Ok(method) -> {
      let prefix = "@" <> method <> " "
      case extract_quoted_arg(after_slashes, prefix) {
        Ok(path) ->
          AnnotationState(..state, method: Some(method), path: Some(path))
        Error(_) -> state
      }
    }
    Error(_) -> {
      // Check for middleware
      case string.starts_with(after_slashes, "@middleware ") {
        True -> {
          case extract_quoted_arg(after_slashes, "@middleware ") {
            Ok(mw) ->
              AnnotationState(
                ..state,
                middleware: list.append(state.middleware, [mw]),
              )
            Error(_) -> state
          }
        }
        False -> {
          // Check for validator
          case string.starts_with(after_slashes, "@validator ") {
            True -> {
              case extract_quoted_arg(after_slashes, "@validator ") {
                Ok(v) -> AnnotationState(..state, validator: Some(v))
                Error(_) -> state
              }
            }
            False -> {
              // Check for redirect_permanent
              case string.starts_with(after_slashes, "@redirect_permanent ") {
                True -> {
                  case
                    extract_quoted_arg(after_slashes, "@redirect_permanent ")
                  {
                    Ok(path) ->
                      AnnotationState(
                        ..state,
                        redirects: list.append(state.redirects, [#(path, 308)]),
                      )
                    Error(_) -> state
                  }
                }
                False -> {
                  // Check for redirect
                  case string.starts_with(after_slashes, "@redirect ") {
                    True -> {
                      case extract_quoted_arg(after_slashes, "@redirect ") {
                        Ok(path) ->
                          AnnotationState(
                            ..state,
                            redirects: list.append(state.redirects, [
                              #(path, 303),
                            ]),
                          )
                        Error(_) -> state
                      }
                    }
                    False -> state
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Extracts the function name from a pub fn declaration.
/// Parses `pub fn name(` to get just the name portion.
/// Trims whitespace and stops at the opening parenthesis.
///
fn extract_fn_name(line: String) -> String {
  let after_pub_fn = string.drop_start(line, 7)
  case string.split_once(after_pub_fn, "(") {
    Ok(#(name, _)) -> string.trim(name)
    Error(_) -> after_pub_fn |> string.trim
  }
}

/// Extracts function parameters from a function signature.
/// Parses `pub fn name(param1: Type1, param2: Type2) -> ReturnType`
/// and returns a list of FunctionParam with name and type.
///
fn extract_fn_params(signature: String) -> List(FunctionParam) {
  // Extract content between first ( and last ) before ->
  case string.split_once(signature, "(") {
    Ok(#(_, after_paren)) -> {
      // Find the closing paren - need to handle nested types like Option(String)
      let params_str = extract_params_string(after_paren, 0, "")
      parse_params_string(params_str)
    }
    Error(_) -> []
  }
}

/// Extracts the parameters string by finding matching closing
/// paren. Handles nested parentheses in types like 
/// Option(String). Returns the accumulated string up to the 
/// matching close paren.
///
fn extract_params_string(s: String, depth: Int, acc: String) -> String {
  case string.pop_grapheme(s) {
    Ok(#("(", rest)) -> extract_params_string(rest, depth + 1, acc <> "(")
    Ok(#(")", rest)) -> {
      case depth {
        0 -> acc
        _ -> extract_params_string(rest, depth - 1, acc <> ")")
      }
    }
    Ok(#(char, rest)) -> extract_params_string(rest, depth, acc <> char)
    Error(_) -> acc
  }
}

/// Parses a comma-separated parameter string into 
/// FunctionParams. Handles types with commas in generics like 
/// Dict(String, Int). Filters out empty parameter strings from 
/// the result.
///
fn parse_params_string(params_str: String) -> List(FunctionParam) {
  split_params(params_str, 0, "", [])
  |> list.filter_map(fn(param_str) {
    let trimmed = string.trim(param_str)
    case trimmed {
      "" -> Error(Nil)
      _ -> parse_single_param(trimmed)
    }
  })
}

/// Splits parameters by comma, respecting nested parentheses.
/// Only splits on commas at depth zero to preserve generic types.
/// Example: "a: Int, b: Option(String)" -> ["a: Int", "b: ..."]
///
fn split_params(
  s: String,
  depth: Int,
  current: String,
  acc: List(String),
) -> List(String) {
  case string.pop_grapheme(s) {
    Ok(#("(", rest)) -> split_params(rest, depth + 1, current <> "(", acc)
    Ok(#(")", rest)) -> split_params(rest, depth - 1, current <> ")", acc)
    Ok(#(",", rest)) -> {
      case depth {
        0 -> split_params(rest, 0, "", [current, ..acc])
        _ -> split_params(rest, depth, current <> ",", acc)
      }
    }
    Ok(#(char, rest)) -> split_params(rest, depth, current <> char, acc)
    Error(_) -> list.reverse([current, ..acc])
  }
}

/// Parses a single parameter like "name: Type" or "_name: Type".
/// Returns the parameter name and type as a FunctionParam 
/// record. Returns Error for empty parameter strings.
///
fn parse_single_param(param: String) -> Result(FunctionParam, Nil) {
  case string.split_once(param, ":") {
    Ok(#(name, type_str)) -> {
      let clean_name = string.trim(name)
      let clean_type = string.trim(type_str)
      Ok(FunctionParam(name: clean_name, param_type: clean_type))
    }
    Error(_) -> {
      // No type annotation - just a param name
      let clean_name = string.trim(param)
      case clean_name {
        "" -> Error(Nil)
        _ -> Ok(FunctionParam(name: clean_name, param_type: ""))
      }
    }
  }
}

/// Creates routes from accumulated annotation state. Generates
/// the main route and any redirect routes pointing to it.
/// Combines group middleware with route-specific middleware.
///
fn create_routes_from_state(
  state: AnnotationState,
  fn_name: String,
  params: List(FunctionParam),
  group_middleware: List(String),
) -> List(ParsedRoute) {
  case state.method, state.path {
    Some(method), Some(path) -> {
      let all_middleware = list.append(group_middleware, state.middleware)
      let main_route =
        ParsedRoute(
          method:,
          path:,
          handler: fn_name,
          middleware: all_middleware,
          validator: state.validator,
          params:,
        )

      // Create redirect routes
      let redirect_routes =
        list.map(state.redirects, fn(r) {
          let #(from, status) = r
          ParsedRedirect(from:, to: path, status:)
        })

      [main_route, ..redirect_routes]
    }
    _, _ -> []
  }
}

/// Extracts the module name from a controller file path.
/// Converts `src/app/http/controllers/user_controller.gleam`
/// to `app/http/controllers/user_controller`.
///
pub fn module_from_path(path: String) -> Result(String, Nil) {
  path
  |> string.replace(".gleam", "")
  |> string.split_once("src/")
  |> result.map(fn(parts) { parts.1 })
}
