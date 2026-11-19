import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import ochoko/federation/note.{type InboundNote}
import ochoko_shared/mastodon.{Direct, Private, Public, Unlisted}
import simplifile

fn fixture(name: String) -> String {
  let assert Ok(body) = simplifile.read("test/fixtures/ap/" <> name)
  body
}

fn parse(body: String) -> Result(InboundNote, String) {
  let assert Ok(data) = json.parse(body, decode.dynamic)
  note.decode(data)
}

fn base(to: String, cc: String) -> String {
  "{\"id\":\"https://r.example/n/1\",\"type\":\"Note\",\"attributedTo\":\"https://r.example/users/a\",\"content\":\"hi\",\"to\":"
  <> to
  <> ",\"cc\":"
  <> cc
  <> "}"
}

fn decoded(to: String, cc: String) -> InboundNote {
  let assert Ok(n) = parse(base(to, cc))
  n
}

pub fn decode_mastodon_note_test() {
  let assert Ok(n) = parse(fixture("mastodon_note.json"))
  assert n.uri
    == "https://fosstodon.org/users/fosstodon/statuses/117377852752602059"
  assert n.attributed_to == "https://fosstodon.org/users/fosstodon"
  assert n.in_reply_to
    == Some("https://fosstodon.org/users/dusoft/statuses/117377719248493539")
  assert n.url == Some("https://fosstodon.org/@fosstodon/117377852752602059")
  assert n.language == Some("en")
  assert n.spoiler_text == ""
  assert !n.sensitive
  assert n.published == Some(timestamp.from_unix_seconds(1_791_043_895))
  assert string.contains(n.content_html, "will have a look")
  assert n.attachments == []
  assert n.to == ["https://www.w3.org/ns/activitystreams#Public"]
  assert note.visibility(
      n,
      Some("https://fosstodon.org/users/fosstodon/followers"),
    )
    == Public
}

pub fn decode_misskey_note_test() {
  let assert Ok(n) = parse(fixture("misskey_note.json"))
  assert n.uri == "https://misskey.io/notes/atr6idzsmo9z0bgc"
  assert n.attributed_to == "https://misskey.io/users/7rkrarq81i"
  assert n.in_reply_to == None
  assert n.url == None
  assert n.language == None
  assert n.published != None
  assert n.cc == ["https://misskey.io/users/7rkrarq81i/followers"]
}

pub fn decode_gotosocial_note_test() {
  let assert Ok(n) = parse(fixture("gotosocial_note.json"))
  assert n.spoiler_text == "introduction post"
  assert n.sensitive
  assert n.to == ["https://www.w3.org/ns/activitystreams#Public"]
  assert n.cc == ["http://localhost:8080/users/the_mighty_zork/followers"]
  assert n.content_html == "<p>hello everyone!</p>"
  assert n.published == Some(timestamp.from_unix_seconds(1_634_726_437))
  assert n.attachments == []
}

pub fn decode_akkoma_note_test() {
  let assert Ok(n) = parse(fixture("akkoma_note.json"))
  assert n.uri
    == "https://fedi.absturztau.be/objects/78a6a39f-ab18-4861-966c-bcccee6bee98"
  assert n.spoiler_text == ""
  assert !n.sensitive
  assert n.url == None
  assert n.attachments == []
}

pub fn decode_attachments_test() {
  let body =
    "{\"id\":\"https://r.example/n/1\",\"type\":\"Note\",\"attributedTo\":\"https://r.example/users/a\",\"attachment\":[{\"type\":\"Document\",\"mediaType\":\"image/png\",\"url\":\"https://r.example/m/1.png\",\"name\":\"alt\",\"blurhash\":\"LEHV6n\"},{\"type\":\"PropertyValue\"}]}"
  let assert Ok(n) = parse(body)
  assert n.attachments
    == [
      note.Attachment(
        "https://r.example/m/1.png",
        Some("image/png"),
        Some("alt"),
        Some("LEHV6n"),
      ),
    ]
}

pub fn decode_rejects_non_note_test() {
  let assert Error(_) =
    parse(
      "{\"id\":\"https://r.example/n/1\",\"type\":\"Person\",\"attributedTo\":\"https://r.example/users/a\"}",
    )
}

pub fn visibility_public_test() {
  let n = decoded("[\"https://www.w3.org/ns/activitystreams#Public\"]", "[]")
  assert note.visibility(n, None) == Public
}

pub fn visibility_unlisted_test() {
  let n =
    decoded(
      "[\"https://r.example/f\"]",
      "[\"https://www.w3.org/ns/activitystreams#Public\"]",
    )
  assert note.visibility(n, Some("https://r.example/f")) == Unlisted
}

pub fn visibility_private_test() {
  let n = decoded("[\"https://r.example/f\"]", "[]")
  assert note.visibility(n, Some("https://r.example/f")) == Private
}

pub fn visibility_direct_test() {
  let n = decoded("[\"https://ochoko.ynkt.me/me\"]", "[]")
  assert note.visibility(n, Some("https://r.example/f")) == Direct
  assert note.visibility(n, None) == Direct
}

pub fn visibility_accepts_short_public_forms_test() {
  assert note.visibility(decoded("[\"as:Public\"]", "[]"), None) == Public
  assert note.visibility(decoded("\"Public\"", "[]"), None) == Public
  assert note.visibility(decoded("[]", "[\"as:Public\"]"), None) == Unlisted
}

pub fn content_is_sanitized_test() {
  let assert Ok(n) =
    parse(
      "{\"id\":\"https://r.example/n/1\",\"type\":\"Note\",\"attributedTo\":\"https://r.example/users/a\",\"content\":\"<p>ok</p><script>alert(1)</script>\"}",
    )
  assert !string.contains(n.content_html, "script")
  assert string.contains(n.content_html, "<p>ok</p>")
}

pub fn content_map_fallback_test() {
  let assert Ok(n) =
    parse(
      "{\"id\":\"https://r.example/n/1\",\"type\":\"Note\",\"attributedTo\":\"https://r.example/users/a\",\"contentMap\":{\"ja\":\"<p>konnichiwa</p>\"}}",
    )
  assert n.content_html == "<p>konnichiwa</p>"
  assert n.language == Some("ja")
}
