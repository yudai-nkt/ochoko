//// Remote notes (`Note`, `Question`, `Article`, `Page`) as received over
//// ActivityPub.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import ochoko/federation/ap_decode
import ochoko/html
import ochoko_shared/mastodon.{
  type Visibility, Direct, Private, Public, Unlisted,
}

pub type Attachment {
  Attachment(
    url: String,
    media_type: Option(String),
    description: Option(String),
    blurhash: Option(String),
  )
}

pub type InboundNote {
  InboundNote(
    uri: String,
    attributed_to: String,
    content_html: String,
    spoiler_text: String,
    sensitive: Bool,
    url: Option(String),
    in_reply_to: Option(String),
    language: Option(String),
    published: Option(Timestamp),
    to: List(String),
    cc: List(String),
    attachments: List(Attachment),
  )
}

const note_types = ["Note", "Question", "Article", "Page"]

/// Decodes a note-like object. The HTML content is sanitised here; the
/// spoiler text (`summary`) is kept as plain text.
pub fn decode(data: Dynamic) -> Result(InboundNote, String) {
  decode.run(data, decoder())
  |> result.map_error(fn(_) { "not a usable note" })
}

fn lenient(path: List(String), default: a, decoder: Decoder(a)) -> Decoder(a) {
  decode.optionally_at(
    path,
    default,
    decode.one_of(decoder, [decode.success(default)]),
  )
}

fn first(items: List(String)) -> Option(String) {
  list.first(items) |> option.from_result
}

fn decoder() -> Decoder(InboundNote) {
  use types <- decode.field("type", ap_decode.type_names())
  use <- guard_type(types)
  use uri <- decode.field("id", ap_decode.iri())
  use attributed_to <- decode.field("attributedTo", ap_decode.iri_list())
  use content <- decode.then(localized("content"))
  use summary <- decode.then(localized("summary"))
  use sensitive <- decode.then(lenient(["sensitive"], False, decode.bool))
  use url <- decode.then(lenient(["url"], [], ap_decode.iri_list()))
  use in_reply_to <- decode.then(lenient(
    ["inReplyTo"],
    [],
    ap_decode.iri_list(),
  ))
  use language <- decode.then(language())
  use published <- decode.then(lenient(["published"], None, published()))
  use to <- decode.then(lenient(["to"], [], ap_decode.iri_list()))
  use cc <- decode.then(lenient(["cc"], [], ap_decode.iri_list()))
  use attachments <- decode.then(lenient(["attachment"], [], attachments()))
  case first(attributed_to) {
    None -> decode.failure(empty(), "attributedTo")
    Some(attributed_to) ->
      decode.success(InboundNote(
        uri:,
        attributed_to:,
        content_html: html.sanitize(content),
        spoiler_text: summary,
        sensitive:,
        url: ap_decode.first_web_url(url),
        in_reply_to: ap_decode.first_web_url(in_reply_to),
        language:,
        published:,
        to:,
        cc:,
        attachments:,
      ))
  }
}

fn empty() -> InboundNote {
  InboundNote("", "", "", "", False, None, None, None, None, [], [], [])
}

fn guard_type(
  types: List(String),
  next: fn() -> Decoder(InboundNote),
) -> Decoder(InboundNote) {
  case list.any(types, list.contains(note_types, _)) {
    True -> next()
    False -> decode.failure(empty(), "Note")
  }
}

fn localized(field: String) -> Decoder(String) {
  ap_decode.localized(field) |> decode.map(option.unwrap(_, ""))
}

fn language() -> Decoder(Option(String)) {
  lenient(
    ["contentMap"],
    None,
    decode.dict(decode.string, decode.string)
      |> decode.map(fn(map) {
        dict.keys(map) |> list.sort(string.compare) |> first
      }),
  )
}

fn published() -> Decoder(Option(Timestamp)) {
  decode.string
  |> decode.map(fn(s) { timestamp.parse_rfc3339(s) |> option.from_result })
}

fn attachments() -> Decoder(List(Attachment)) {
  let one = {
    use url <- decode.then(ap_decode.image_url())
    use media_type <- decode.then(lenient(
      ["mediaType"],
      None,
      decode.string |> decode.map(Some),
    ))
    use description <- decode.then(lenient(
      ["name"],
      None,
      decode.string |> decode.map(Some),
    ))
    use blurhash <- decode.then(lenient(
      ["blurhash"],
      None,
      decode.string |> decode.map(Some),
    ))
    decode.success(case url {
      Some(url) -> Some(Attachment(url:, media_type:, description:, blurhash:))
      None -> None
    })
  }
  decode.one_of(decode.list(one) |> decode.map(option.values), [
    one |> decode.map(fn(x) { option.values([x]) }),
  ])
}

const public_forms = [
  "https://www.w3.org/ns/activitystreams#Public", "as:Public", "Public",
]

fn is_public(iri: String) -> Bool {
  list.contains(public_forms, iri)
}

/// Mastodon's audience rules: Public if addressed `to` the public
/// collection, Unlisted if in `cc`, Private if only addressed to the
/// author's followers, otherwise Direct.
pub fn visibility(n: InboundNote, followers_uri: Option(String)) -> Visibility {
  case list.any(n.to, is_public), list.any(n.cc, is_public) {
    True, _ -> Public
    _, True -> Unlisted
    _, _ ->
      case followers_uri {
        Some(f) ->
          case list.contains(n.to, f) || list.contains(n.cc, f) {
            True -> Private
            False -> Direct
          }
        None -> Direct
      }
  }
}
