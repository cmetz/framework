//// Gleam Source Parser
////
//// Parses Gleam source files to extract type definitions and
//// imports. Used by the template compiler to understand view
//// data structures for code generation.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

// ------------------------------------------------------------- Public Types

/// Represents the parsed contents of a view file. Contains
/// the extracted field definitions from the Data type and
/// all import statements found in the file.
///
pub type ParsedViewFile {
  ParsedViewFile(fields: List(#(String, String)), imports: List(String))
}

// ------------------------------------------------------------- Public Functions

/// Parses a view file to extract its Data type fields and
/// imports. Returns the parsed structure or Error if the
/// file cannot be read.
///
pub fn parse_view_file(path: String) -> Result(ParsedViewFile, Nil) {
  case simplifile.read(path) {
    Error(_) -> Error(Nil)
    Ok(content) -> {
      let imports = extract_imports(content)
      let fields =
        extract_type_fields(content, "Data")
        |> result.unwrap([])
      Ok(ParsedViewFile(fields: fields, imports: imports))
    }
  }
}

// ------------------------------------------------------------- Private Functions

/// Extracts all import statements from the source content.
/// Filters lines that start with "import " and returns them
/// as a list of import strings.
///
fn extract_imports(content: String) -> List(String) {
  content
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    let trimmed = string.trim(line)
    case string.starts_with(trimmed, "import ") {
      True -> Ok(trimmed)
      False -> Error(Nil)
    }
  })
}

/// Extracts fields from a named type definition. Looks for
/// the pattern "pub type {name} {" and parses the constructor
/// fields into name-type pairs.
///
fn extract_type_fields(
  content: String,
  type_name: String,
) -> Result(List(#(String, String)), Nil) {
  // Look for "pub type Data {"
  let pattern = "pub type " <> type_name <> " {"

  case string.split_once(content, pattern) {
    Error(_) -> Error(Nil)
    Ok(#(_, after_type)) -> {
      // Find the constructor: "Data("
      case string.split_once(after_type, type_name <> "(") {
        Error(_) -> {
          // Empty type like `pub type Data { Data }`
          Ok([])
        }
        Ok(#(_, after_constructor)) -> {
          // Extract until closing paren
          case find_matching_paren(after_constructor, 0, "") {
            None -> Error(Nil)
            Some(fields_str) -> Ok(parse_fields(fields_str))
          }
        }
      }
    }
  }
}

/// Finds content within balanced parentheses. Tracks nesting
/// depth and returns the content when the matching closing
/// paren is found at depth zero.
///
fn find_matching_paren(input: String, depth: Int, acc: String) -> Option(String) {
  case string.pop_grapheme(input) {
    Error(_) -> None
    Ok(#(char, rest)) -> {
      case char {
        "(" -> find_matching_paren(rest, depth + 1, acc <> char)
        ")" -> {
          case depth {
            0 -> Some(acc)
            _ -> find_matching_paren(rest, depth - 1, acc <> char)
          }
        }
        _ -> find_matching_paren(rest, depth, acc <> char)
      }
    }
  }
}

/// Parses a comma-separated field string into name-type pairs.
/// Handles nested types by splitting only at top-level commas
/// and extracting the name and type from each field.
///
fn parse_fields(fields_str: String) -> List(#(String, String)) {
  fields_str
  |> split_on_commas_at_depth_zero
  |> list.filter_map(fn(field) {
    let field = string.trim(field)
    case string.split_once(field, ":") {
      Error(_) -> Error(Nil)
      Ok(#(name, type_str)) -> {
        let name = string.trim(name)
        let type_str = string.trim(type_str)
        case name, type_str {
          "", _ -> Error(Nil)
          _, "" -> Error(Nil)
          _, _ -> Ok(#(name, type_str))
        }
      }
    }
  })
}

/// Splits a string on commas, but only at nesting depth zero.
/// Ignores commas inside parentheses to handle nested type
/// parameters like List(#(String, Int)).
///
fn split_on_commas_at_depth_zero(input: String) -> List(String) {
  split_on_commas_helper(input, 0, "", [])
}

/// Recursive helper for comma splitting. Tracks parenthesis
/// depth and accumulates characters until a comma at depth
/// zero triggers a split into the result list.
///
fn split_on_commas_helper(
  input: String,
  depth: Int,
  current: String,
  acc: List(String),
) -> List(String) {
  case string.pop_grapheme(input) {
    Error(_) -> {
      // End of input - add current field if non-empty
      case string.trim(current) {
        "" -> list.reverse(acc)
        _ -> list.reverse([current, ..acc])
      }
    }
    Ok(#(char, rest)) -> {
      case char {
        "(" -> split_on_commas_helper(rest, depth + 1, current <> char, acc)
        ")" -> split_on_commas_helper(rest, depth - 1, current <> char, acc)
        "," if depth == 0 ->
          split_on_commas_helper(rest, depth, "", [current, ..acc])
        _ -> split_on_commas_helper(rest, depth, current <> char, acc)
      }
    }
  }
}
