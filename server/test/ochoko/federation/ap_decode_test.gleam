import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import ochoko/federation/ap_decode
import simplifile

fn parse(json: String, decoder: decode.Decoder(a)) -> a {
  let assert Ok(value) = json.parse(json, decoder)
  value
}

pub fn iri_accepts_string_id_and_href_test() {
  assert parse("\"https://a\"", ap_decode.iri()) == "https://a"
  assert parse("{\"id\":\"https://a\"}", ap_decode.iri()) == "https://a"
  assert parse("{\"href\":\"https://a\"}", ap_decode.iri()) == "https://a"
}

pub fn iri_rejects_other_shapes_test() {
  assert json.parse("42", ap_decode.iri()) |> option.from_result == None
}

pub fn iri_list_null_test() {
  assert parse("null", ap_decode.iri_list()) == []
}

pub fn iri_list_string_test() {
  assert parse("\"https://a\"", ap_decode.iri_list()) == ["https://a"]
}

pub fn iri_list_mixed_array_test() {
  assert parse(
      "[\"https://a\", {\"id\":\"https://b\"}, {\"href\":\"https://c\"}, 7]",
      ap_decode.iri_list(),
    )
    == ["https://a", "https://b", "https://c"]
}

pub fn type_names_test() {
  assert parse("\"Note\"", ap_decode.type_names()) == ["Note"]
  assert parse("[\"Note\", \"Foo\"]", ap_decode.type_names()) == ["Note", "Foo"]
}

pub fn image_url_string_test() {
  assert parse("\"https://i/1.png\"", ap_decode.image_url())
    == Some("https://i/1.png")
}

pub fn image_url_object_test() {
  assert parse(
      "{\"type\":\"Image\",\"url\":\"https://i/1.png\"}",
      ap_decode.image_url(),
    )
    == Some("https://i/1.png")
  assert parse(
      "{\"url\":{\"href\":\"https://i/2.png\"}}",
      ap_decode.image_url(),
    )
    == Some("https://i/2.png")
}

pub fn image_url_array_takes_first_test() {
  assert parse(
      "[{\"url\":\"https://i/1.png\"},{\"url\":\"https://i/2.png\"}]",
      ap_decode.image_url(),
    )
    == Some("https://i/1.png")
}

pub fn image_url_null_and_empty_test() {
  assert parse("null", ap_decode.image_url()) == None
  assert parse("[]", ap_decode.image_url()) == None
  assert parse("{}", ap_decode.image_url()) == None
}

pub fn localized_prefers_plain_field_test() {
  assert parse(
      "{\"content\":\"plain\",\"contentMap\":{\"en\":\"mapped\"}}",
      ap_decode.localized("content"),
    )
    == Some("plain")
}

pub fn localized_falls_back_to_map_test() {
  assert parse(
      "{\"content\":null,\"contentMap\":{\"en\":\"mapped\"}}",
      ap_decode.localized("content"),
    )
    == Some("mapped")
  assert parse(
      "{\"contentMap\":{\"ja\":\"こんにちは\"}}",
      ap_decode.localized("content"),
    )
    == Some("こんにちは")
}

pub fn localized_missing_test() {
  assert parse("{}", ap_decode.localized("content")) == None
}

fn fixture(name: String) -> String {
  let assert Ok(body) = simplifile.read("test/fixtures/ap/" <> name)
  body
}

pub fn gotosocial_note_to_is_a_bare_string_test() {
  let to =
    parse(
      fixture("gotosocial_note.json"),
      decode.at(["to"], ap_decode.iri_list()),
    )
  assert to == ["https://www.w3.org/ns/activitystreams#Public"]
  assert parse(
      fixture("misskey_note.json"),
      decode.at(["cc"], ap_decode.iri_list()),
    )
    == ["https://misskey.io/users/7rkrarq81i/followers"]
}

pub fn fixture_note_types_test() {
  assert parse(
      fixture("mastodon_note.json"),
      decode.at(["type"], ap_decode.type_names()),
    )
    == ["Note"]
}

pub fn web_url_test() {
  assert ap_decode.web_url("https://a.example/x") == Some("https://a.example/x")
  assert ap_decode.web_url(" HTTP://a.example/ ") == Some("HTTP://a.example/")
  assert ap_decode.web_url("javascript:alert(1)") == None
  assert ap_decode.web_url(" JavaScript:alert(1)") == None
  assert ap_decode.web_url("data:text/html,x") == None
  assert ap_decode.web_url("//a.example/x") == None
  assert ap_decode.web_url("https://") == None
}

pub fn image_url_skips_non_web_test() {
  assert parse("\"javascript:x\"", ap_decode.image_url()) == None
  assert parse(
      "[{\"url\":\"javascript:x\"},{\"url\":\"https://a/i.png\"}]",
      ap_decode.image_url(),
    )
    == Some("https://a/i.png")
}
