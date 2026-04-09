import gleeunit/should
import glimr/vite.{Script, Stylesheet}

// ------------------------------------------------------------- render_tags

pub fn render_tags_script_only_test() {
  [Script(src: "/static/app.js")]
  |> vite.render_tags
  |> should.equal("<script type=\"module\" src=\"/static/app.js\"></script>")
}

pub fn render_tags_stylesheet_only_test() {
  [Stylesheet(href: "/static/app.css")]
  |> vite.render_tags
  |> should.equal("<link rel=\"stylesheet\" href=\"/static/app.css\">")
}

pub fn render_tags_mixed_test() {
  [
    Stylesheet(href: "/static/app.css"),
    Script(src: "/static/app.js"),
  ]
  |> vite.render_tags
  |> should.equal(
    "<link rel=\"stylesheet\" href=\"/static/app.css\">\n<script type=\"module\" src=\"/static/app.js\"></script>",
  )
}

pub fn render_tags_empty_test() {
  []
  |> vite.render_tags
  |> should.equal("")
}

pub fn render_tags_multiple_stylesheets_test() {
  [
    Stylesheet(href: "/static/vendor.css"),
    Stylesheet(href: "/static/app.css"),
    Script(src: "/static/app.js"),
  ]
  |> vite.render_tags
  |> should.equal(
    "<link rel=\"stylesheet\" href=\"/static/vendor.css\">\n<link rel=\"stylesheet\" href=\"/static/app.css\">\n<script type=\"module\" src=\"/static/app.js\"></script>",
  )
}
