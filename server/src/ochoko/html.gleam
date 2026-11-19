//// HTML helpers: turning the owner's plain text into HTML, and sanitising
//// HTML received from remote servers. `sanitize` is an XSS boundary: it only
//// ever emits elements and attributes from explicit allowlists, and escapes
//// all text and attribute values on output.

import gleam/list
import gleam/string

type Node {
  Element(tag: String, attrs: List(#(String, String)), children: List(Node))
  Text(String)
}

@external(erlang, "ochoko_html_ffi", "parse")
fn parse(html: String) -> Result(Node, Nil)

// --- escaping ----------------------------------------------------------------

fn escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}

// --- own text to HTML --------------------------------------------------------

/// Converts plain text to HTML: paragraphs on blank lines, `<br>` on single
/// newlines, and `http(s)://` URLs turned into links.
pub fn text_to_html(text: String) -> String {
  text
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  |> string.split("\n\n")
  |> list.filter(fn(p) { string.trim(p) != "" })
  |> list.map(fn(p) {
    let lines =
      p
      |> string.trim
      |> string.split("\n")
      |> list.map(linkify_line)
    "<p>" <> string.join(lines, "<br>") <> "</p>"
  })
  |> string.concat
}

fn linkify_line(line: String) -> String {
  line
  |> string.split(" ")
  |> list.map(linkify_word)
  |> string.join(" ")
}

fn linkify_word(word: String) -> String {
  case
    string.starts_with(word, "http://"),
    string.starts_with(word, "https://")
  {
    False, False -> escape(word)
    _, _ -> {
      let url =
        word
        |> string.to_graphemes
        |> list.take_while(fn(c) {
          !list.contains(["<", ">", "\"", "'", "\t"], c)
        })
        |> string.concat
        |> trim_trailing_punctuation
      let rest = string.drop_start(word, string.length(url))
      case url == "http://" || url == "https://" {
        True -> escape(word)
        False ->
          "<a href=\""
          <> escape(url)
          <> "\" rel=\"nofollow noopener noreferrer\" target=\"_blank\">"
          <> escape(url)
          <> "</a>"
          <> escape(rest)
      }
    }
  }
}

fn trim_trailing_punctuation(url: String) -> String {
  case string.last(url) {
    Ok(c) ->
      case list.contains([".", ",", ";", ":", "!", "?", ")"], c) {
        True -> trim_trailing_punctuation(string.drop_end(url, 1))
        False -> url
      }
    Error(Nil) -> url
  }
}

// --- sanitising remote HTML --------------------------------------------------

const allowed_tags = [
  "p", "br", "a", "span", "strong", "em", "b", "i", "u", "s", "del", "code",
  "pre", "blockquote", "ul", "ol", "li",
]

const dropped_with_contents = [
  "script", "style", "iframe", "object", "embed", "template",
]

const allowed_classes = [
  "mention", "hashtag", "u-url", "h-card", "invisible", "ellipsis",
]

/// Parses `html` and re-serialises only allowlisted markup. Input the parser
/// rejects degrades to escaped plain text.
pub fn sanitize(html: String) -> String {
  case parse("<div>" <> html <> "</div>") {
    Ok(Element(_, _, children)) -> render_children(children)
    Ok(Text(t)) -> escape(t)
    Error(Nil) -> escape(html)
  }
}

fn render_children(nodes: List(Node)) -> String {
  nodes |> list.map(render) |> string.concat
}

fn render(node: Node) -> String {
  case node {
    Text(t) -> escape(t)
    Element(tag, attrs, children) ->
      case list.contains(dropped_with_contents, tag) {
        True -> ""
        False ->
          case list.contains(allowed_tags, tag) {
            False -> render_children(children)
            True -> render_allowed(tag, attrs, children)
          }
      }
  }
}

fn render_allowed(
  tag: String,
  attrs: List(#(String, String)),
  children: List(Node),
) -> String {
  case tag {
    "br" -> "<br>"
    _ -> {
      let open = "<" <> tag <> render_attrs(tag, attrs) <> ">"
      open <> render_children(children) <> "</" <> tag <> ">"
    }
  }
}

fn render_attrs(tag: String, attrs: List(#(String, String))) -> String {
  let class = case tag {
    "a" | "span" -> class_attr(attrs)
    _ -> ""
  }
  case tag {
    "a" ->
      href_attr(attrs)
      <> class
      <> " rel=\"nofollow noopener noreferrer\" target=\"_blank\""
    _ -> class
  }
}

fn find_attr(
  attrs: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  list.find(attrs, fn(a) { string.lowercase(a.0) == name })
  |> result_map_second
}

fn result_map_second(r: Result(#(String, String), Nil)) -> Result(String, Nil) {
  case r {
    Ok(#(_, v)) -> Ok(v)
    Error(Nil) -> Error(Nil)
  }
}

fn class_attr(attrs: List(#(String, String))) -> String {
  case find_attr(attrs, "class") {
    Error(Nil) -> ""
    Ok(value) ->
      case
        value
        |> string.split(" ")
        |> list.flat_map(string.split(_, "\t"))
        |> list.flat_map(string.split(_, "\n"))
        |> list.filter(list.contains(allowed_classes, _))
      {
        [] -> ""
        kept -> " class=\"" <> escape(string.join(kept, " ")) <> "\""
      }
  }
}

fn href_attr(attrs: List(#(String, String))) -> String {
  case find_attr(attrs, "href") {
    Error(Nil) -> ""
    Ok(value) -> {
      let trimmed = string.trim(value)
      let lower = string.lowercase(trimmed)
      case
        string.starts_with(lower, "http://")
        || string.starts_with(lower, "https://")
      {
        True -> " href=\"" <> escape(trimmed) <> "\""
        False -> ""
      }
    }
  }
}

// --- plain text --------------------------------------------------------------

/// Reduces HTML to plain text: markup is dropped, `<br>` and block elements
/// become newlines, and script/style contents are discarded.
pub fn to_plain_text(html: String) -> String {
  case parse("<div>" <> html <> "</div>") {
    Ok(node) -> node |> plain |> string.trim
    Error(Nil) -> string.trim(html)
  }
}

fn plain(node: Node) -> String {
  case node {
    Text(t) -> t
    Element(tag, _, children) ->
      case tag {
        _ if tag == "script" || tag == "style" -> ""
        "br" -> "\n"
        "p" | "div" | "blockquote" | "pre" | "ul" | "ol" | "li" ->
          "\n" <> { children |> list.map(plain) |> string.concat } <> "\n"
        _ -> children |> list.map(plain) |> string.concat
      }
  }
}
