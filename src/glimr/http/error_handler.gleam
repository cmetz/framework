//// Error Handler
////
//// Provides default error response handlers for HTML and JSON
//// formats. Intercepts error status codes and replaces empty
//// responses with user-friendly error messages.

import gleam/bool
import gleam/json
import glimr/response/response
import wisp.{type Response}

// ------------------------------------------------------------- Public Functions

/// Middleware that adds HTML error messages to error responses.
/// Wraps the request handler and checks the response status.
/// Success responses (2xx) pass through unchanged. Error status
/// codes receive default HTML error pages. Can be overridden by
/// implementing custom error handlers in your application.
///
pub fn default_html_responses(handle_request: fn() -> Response) -> Response {
  let res = handle_request()

  use <- bool.guard(
    // Return the response as is if it's not an error response.
    when: res.status >= 200 && res.status < 300,
    return: res,
  )

  case res.status {
    404 | 405 | 400 | 422 | 413 | 500 -> response.error(res.status)
    _ -> res
  }
}

/// Middleware that adds JSON error messages to error responses.
/// Wraps the request handler and checks the response status.
/// Success responses (2xx) pass through unchanged. Error status
/// codes receive JSON error objects with an "error" field. Used
/// for API routes to ensure consistent JSON error formatting.
///
pub fn default_json_responses(handle_request: fn() -> Response) -> Response {
  let res = handle_request()

  use <- bool.guard(
    // Return the response as is if it's not an error response.
    when: res.status >= 200 && res.status < 300,
    return: res,
  )

  case res.status {
    404 ->
      json.object([
        #("error", json.string("Not Found")),
      ])
      |> response.json(res.status)

    405 ->
      json.object([
        #("error", json.string("Method Not Allowed")),
      ])
      |> response.json(res.status)

    400 ->
      json.object([
        #("error", json.string("Bad Request")),
      ])
      |> response.json(res.status)

    422 ->
      json.object([
        #("error", json.string("Bad Request")),
      ])
      |> response.json(res.status)

    413 ->
      json.object([
        #("error", json.string("Request Entity Too Large")),
      ])
      |> response.json(res.status)

    500 ->
      json.object([
        #("error", json.string("Internal Server Error")),
      ])
      |> response.json(res.status)

    _ -> res
  }
}
