//// Redirect Helpers
////
//// Builder pattern for creating HTTP redirects with support
//// for flash messages and returning to previous pages. Use
//// the builder to construct redirects before sending.

import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import wisp.{type Request, type Response}

// ------------------------------------------------------------- Public Types

/// Redirect builder for constructing HTTP redirect responses.
/// Using this type constructor provides extra flexibility
/// like optionally flashing messages or using a helper
/// function to redirect back.
///
pub type Redirect {
  Redirect(path: String, flash_data: Dict(String, String))
}

// ------------------------------------------------------------- Public Functions

/// Creates a new redirect builder with empty path and flash
/// data. Use this to start building a redirect response.
///
/// *Example:*
/// 
/// ```gleam
/// redirect.build()
/// |> redirect.to("/contact/success")
/// |> redirect.go()
/// ```
///
pub fn build() -> Redirect {
  Redirect("", dict.from_list([]))
}

/// Sets the target path for the redirect. This is where the
/// user will be sent when the redirect executes.
///
/// *Example:*
/// 
/// ```gleam
/// redirect.build()
/// |> redirect.to("/dashboard")
/// |> redirect.go()
/// ```
///
pub fn to(redirect: Redirect, path: String) -> Redirect {
  Redirect(..redirect, path: normalize_path(path))
}

/// Sets the redirect path to the previous page from the Referer 
/// header. Panics if no referer is found. Useful for cancel or 
/// back buttons that must have a referrer.
///
/// *Example:*
/// 
/// ```gleam
/// redirect.build()
/// |> redirect.back(req.request)
/// |> redirect.go()
/// ```
///
pub fn back(redirect: Redirect, req: Request) -> Redirect {
  let assert Ok(path) = get_referer(req)

  Redirect(..redirect, path: path)
}

/// Adds a key-value pair to the flash data that will be stored 
/// in the session and available on the next request. Useful for 
/// success/error messages after redirects.
///
/// *Example:*
/// 
/// ```gleam
/// redirect.build()
/// |> redirect.to("/contact")
/// |> redirect.flash([#("success", "Message sent!")])
/// |> redirect.go()
/// ```
///
pub fn flash(
  redirect: Redirect,
  flash_data: List(#(String, String)),
) -> Redirect {
  let data = dict.merge(redirect.flash_data, dict.from_list(flash_data))
  Redirect(..redirect, flash_data: data)
}

/// Converts the redirect builder into an HTTP redirect response.
/// This finalizes the redirect and sends it to the client.
/// Flash data will be written to session when implemented.
///
/// *Example:*
/// 
/// ```gleam
/// redirect.build()
/// |> redirect.to("/contact/success")
/// |> redirect.go()
/// ```
///
pub fn go(redirect: Redirect) -> Response {
  // TODO: flash redirect.flash_data to session, etc.
  wisp.redirect(redirect.path)
}

// ------------------------------------------------------------- Private Functions

/// Extracts the Referer header from an HTTP request. Returns 
/// Ok(referer) if the header exists, or Error(Nil) if the 
/// referer header is not present.
///
fn get_referer(request: Request) -> Result(String, Nil) {
  request.headers
  |> list.key_find("referer")
}

/// Removes the final leading slash from the path if present.
/// Used to normalize file paths for consistent reading.
///
fn normalize_path(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> string.drop_end(path, 1)
    False -> path
  }
}
