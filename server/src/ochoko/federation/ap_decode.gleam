//// Lenient decoders for ActivityStreams JSON as found in the wild. They read
//// compacted AS2 key names only and ignore unknown keys.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// An IRI given as `"x"`, `{"id": "x"}` or `{"href": "x"}`.
pub fn iri() -> Decoder(String) {
  decode.one_of(decode.string, [
    decode.at(["id"], decode.string),
    decode.at(["href"], decode.string),
  ])
}

/// `null`, a single IRI, or an array of IRIs (unusable elements are skipped).
pub fn iri_list() -> Decoder(List(String)) {
  let element = decode.one_of(iri() |> decode.map(Some), [decode.success(None)])
  decode.one_of(decode.list(element) |> decode.map(option.values), [
    iri() |> decode.map(fn(x) { [x] }),
    decode.optional(decode.success(Nil)) |> decode.map(fn(_) { [] }),
  ])
}

/// `"Note"` or `["Note", ...]`.
pub fn type_names() -> Decoder(List(String)) {
  decode.one_of(decode.list(decode.string), [
    decode.string |> decode.map(fn(x) { [x] }),
  ])
}

/// An image given as `"u"`, `{"url": "u" | {"href": "u"}}` or an array of
/// those, of which the first usable one is taken.
pub fn image_url() -> Decoder(Option(String)) {
  decode.recursive(fn() {
    decode.one_of(decode.string |> decode.map(Some), [
      decode.list(image_url())
        |> decode.map(fn(items) {
          items |> option.values |> list.first |> option.from_result
        }),
      decode.optionally_at(["url"], [], iri_list())
        |> decode.map(fn(urls) { list.first(urls) |> option.from_result }),
      decode.success(None),
    ])
  })
}

/// The string at `field`, else the first value of the language map
/// `field <> "Map"` (e.g. `content` / `contentMap`).
pub fn localized(field: String) -> Decoder(Option(String)) {
  let plain =
    decode.optionally_at(
      [field],
      None,
      decode.one_of(decode.string |> decode.map(Some), [decode.success(None)]),
    )
  use value <- decode.then(plain)
  case value {
    Some(_) -> decode.success(value)
    None ->
      decode.optionally_at(
        [field <> "Map"],
        None,
        decode.one_of(
          decode.dict(decode.string, decode.string)
            |> decode.map(fn(map) {
              map
              |> dict.to_list
              |> list.sort(fn(a, b) { string_compare(a.0, b.0) })
              |> list.first
              |> result.map(fn(pair) { pair.1 })
              |> option.from_result
            }),
          [decode.success(None)],
        ),
      )
  }
}

fn string_compare(a: String, b: String) {
  string.compare(a, b)
}
