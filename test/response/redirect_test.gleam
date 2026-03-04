import gleam/http
import gleam/http/request
import gleam/list
import gleeunit/should
import glimr/http/context
import glimr/response/redirect
import wisp

@external(erlang, "erlang", "make_ref")
fn stub_connection() -> wisp.Connection

pub type TestApp {
  TestApp
}

pub fn back_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header("referer", "https://example.com/previous-page")
    |> request.set_body(stub_connection())
  let ctx = context.new(req, TestApp)

  let res = redirect.back(ctx)

  res.status
  |> should.equal(303)

  // Check location header exists
  res.headers
  |> list.contains(#("location", "https://example.com/previous-page"))
  |> should.be_true()
}

pub fn to_test() {
  let res = redirect.to("/success")

  res.status
  |> should.equal(303)

  // Check location header exists
  res.headers
  |> list.contains(#("location", "/success"))
  |> should.be_true()
}

pub fn to_with_normalization_test() {
  let res = redirect.to("success/")

  res.status
  |> should.equal(303)

  // Check location header exists and was normalized
  res.headers
  |> list.contains(#("location", "success"))
  |> should.be_true()
}

pub fn to_with_normalization_home_test() {
  let res = redirect.to("/")

  res.status
  |> should.equal(303)

  // Check location header exists and was normalized
  res.headers
  |> list.contains(#("location", "/"))
  |> should.be_true()
}

pub fn permanent_test() {
  let res = redirect.permanent("/success")

  res.status
  |> should.equal(308)

  // Check location header exists
  res.headers
  |> list.contains(#("location", "/success"))
  |> should.be_true()
}
