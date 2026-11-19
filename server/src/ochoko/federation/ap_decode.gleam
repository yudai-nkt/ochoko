//// Lenient decoders for ActivityStreams JSON as found in the wild. They read
//// compacted AS2 key names only and ignore unknown keys.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

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

/// `s` when it is an absolute `http` or `https` URL with a host (scheme
/// compared case-insensitively, surrounding whitespace trimmed); remote URLs
/// end up as links and images in clients, so any other scheme is dropped.
pub fn web_url(s: String) -> Option(String) {
  let s = string.trim(s)
  case uri.parse(s) {
    Ok(uri.Uri(scheme: Some(scheme), host: Some(host), ..)) if host != "" ->
      case string.lowercase(scheme) {
        "http" | "https" -> Some(s)
        _ -> None
      }
    _ -> None
  }
}

/// The first of `urls` that is a `web_url`.
pub fn first_web_url(urls: List(String)) -> Option(String) {
  list.find_map(urls, fn(u) { web_url(u) |> option.to_result(Nil) })
  |> option.from_result
}

/// `"Note"` or `["Note", ...]`.
pub fn type_names() -> Decoder(List(String)) {
  decode.one_of(decode.list(decode.string), [
    decode.string |> decode.map(fn(x) { [x] }),
  ])
}

/// An image given as `"u"`, `{"url": "u" | {"href": "u"}}` or an array of
/// those, of which the first usable one is taken. Only `web_url`s count.
pub fn image_url() -> Decoder(Option(String)) {
  decode.recursive(fn() {
    decode.one_of(decode.string |> decode.map(web_url), [
      decode.list(image_url())
        |> decode.map(fn(items) {
          items |> option.values |> list.first |> option.from_result
        }),
      decode.optionally_at(["url"], [], iri_list())
        |> decode.map(first_web_url),
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
