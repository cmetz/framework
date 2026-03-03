//// HTTP Kernel
////
//// The framework's core HTTP types live here so the rest of
//// the codebase never imports wisp directly. If we ever swap
//// wisp for another HTTP library, this module is the only
//// thing that changes — controllers, middleware, and the route
//// compiler all reference these types instead.

import wisp

// ------------------------------------------------------------- Public Types

/// Controllers and middleware import Request from here rather
/// than from wisp. This indirection means swapping the HTTP
/// library only requires changing this alias, not every file
/// that handles requests.
///
pub type Request =
  wisp.Request

/// Same idea as Request — the response type is re-exported here
/// so controllers and middleware never depend on wisp directly.
/// Keeps the HTTP library as a swappable implementation detail.
///
pub type Response =
  wisp.Response

// ------------------------------------------------------------- Public Functions

/// Wisp's logger setup needs to run before the HTTP server
/// starts or you get raw Erlang crash reports instead of
/// readable request logs. Wrapping it here keeps the boot
/// sequence free of direct wisp imports.
///
pub fn configure_logger() -> Nil {
  wisp.configure_logger()
}

/// Middleware functions receive a `next` callback they can call
/// to continue the chain. Naming this signature avoids
/// repeating `fn(Request, context) -> Response` in every
/// middleware definition and makes it clear what `next`
/// actually is when you're reading middleware code.
///
pub type Next(context) =
  fn(Request, context) -> Response

/// The shape of a middleware function — takes a request,
/// context, and the next handler in the chain. Having a named
/// type for this means the route compiler can generate
/// middleware wiring code without spelling out the full
/// function signature every time.
///
pub type Middleware(context) =
  fn(Request, context, Next(context)) -> Response

/// Web routes need HTML error pages and static file serving,
/// API routes need JSON errors and CORS headers — lumping them
/// together means one group gets the wrong defaults. Splitting
/// into groups lets the route compiler wire the right
/// middleware stack automatically based on what the developer
/// declared in their route annotations.
///
pub type MiddlewareGroup {
  Web
  Api
  Custom(String)
}
