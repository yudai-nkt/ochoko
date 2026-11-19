import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import ochoko/html
import simplifile

pub fn text_escapes_test() {
  html.text_to_html("a < b & c")
  |> should.equal("<p>a &lt; b &amp; c</p>")
}

pub fn text_empty_test() {
  html.text_to_html("") |> should.equal("")
}

pub fn text_paragraphs_and_breaks_test() {
  html.text_to_html("l1\nl2\n\nl3")
  |> should.equal("<p>l1<br>l2</p><p>l3</p>")
}

pub fn text_linkifies_test() {
  html.text_to_html("see https://example.com/a?b=1&c=2. ok")
  |> should.equal(
    "<p>see <a href=\"https://example.com/a?b=1&amp;c=2\" rel=\"nofollow noopener noreferrer\" target=\"_blank\">https://example.com/a?b=1&amp;c=2</a>. ok</p>",
  )
}

pub fn text_does_not_linkify_other_schemes_test() {
  html.text_to_html("javascript:alert(1)")
  |> should.equal("<p>javascript:alert(1)</p>")
}

pub fn sanitize_removes_script_test() {
  html.sanitize("<p>hi<script>alert(1)</script></p>")
  |> should.equal("<p>hi</p>")
}

pub fn sanitize_drops_js_href_test() {
  html.sanitize("<a href=\"javascript:alert(1)\">x</a>")
  |> should.equal(
    "<a rel=\"nofollow noopener noreferrer\" target=\"_blank\">x</a>",
  )
}

pub fn sanitize_drops_obfuscated_js_href_test() {
  html.sanitize("<a href=\" JaVaScRiPt:alert(1)\">x</a>")
  |> string.contains("href")
  |> should.be_false
}

pub fn sanitize_keeps_http_href_case_insensitively_test() {
  html.sanitize("<a href=\" HTTPS://x/\">x</a>")
  |> should.equal(
    "<a href=\"HTTPS://x/\" rel=\"nofollow noopener noreferrer\" target=\"_blank\">x</a>",
  )
}

pub fn sanitize_escapes_attribute_quotes_test() {
  html.sanitize("<a href='https://x/\"onmouseover=\"alert(1)'>x</a>")
  |> should.equal(
    "<a href=\"https://x/&quot;onmouseover=&quot;alert(1)\" rel=\"nofollow noopener noreferrer\" target=\"_blank\">x</a>",
  )
}

pub fn sanitize_drops_event_handlers_and_style_test() {
  html.sanitize("<p onclick=\"x\" style=\"y\">t</p>")
  |> should.equal("<p>t</p>")
}

pub fn sanitize_keeps_mastodon_mention_markup_test() {
  html.sanitize(
    "<span class=\"h-card\"><a href=\"https://m/@a\" class=\"u-url mention\">@<span>a</span></a></span>",
  )
  |> should.equal(
    "<span class=\"h-card\"><a href=\"https://m/@a\" class=\"u-url mention\" rel=\"nofollow noopener noreferrer\" target=\"_blank\">@<span>a</span></a></span>",
  )
}

pub fn sanitize_filters_classes_test() {
  html.sanitize(
    "<span class=\"mention evil\">x</span><p class=\"mention\">y</p>",
  )
  |> should.equal("<span class=\"mention\">x</span><p>y</p>")
}

pub fn sanitize_unwraps_unknown_test() {
  html.sanitize("<marquee>t</marquee>") |> should.equal("t")
}

pub fn sanitize_escapes_text_and_entities_test() {
  html.sanitize("<p>a &lt;script&gt; &amp; b</p>")
  |> should.equal("<p>a &lt;script&gt; &amp; b</p>")
}

pub fn sanitize_plain_text_outside_tags_test() {
  html.sanitize("hello <b>w</b>") |> should.equal("hello <b>w</b>")
}

pub fn sanitize_drops_comments_and_dangerous_elements_test() {
  html.sanitize("a<!-- c --><iframe src=x>f</iframe><style>p{}</style>b")
  |> should.equal("ab")
}

pub fn sanitize_garbage_does_not_crash_test() {
  let _ = html.sanitize("<<<>>><a href=\"><p")
  let _ = html.sanitize("")
  Nil
}

pub fn to_plain_text_test() {
  html.to_plain_text("<p>a<br>b</p><script>x</script>")
  |> should.equal("a\nb")
}

pub fn sanitize_fixture_notes_test() {
  ["mastodon", "akkoma", "gotosocial", "misskey"]
  |> list.each(fn(name) {
    let assert Ok(body) =
      simplifile.read("test/fixtures/ap/" <> name <> "_note.json")
    let assert Ok(content) =
      json.parse(body, {
        use content <- decode.field("content", decode.string)
        decode.success(content)
      })
    let out = html.sanitize(content)
    string.contains(string.lowercase(out), "<script") |> should.be_false
  })
}
