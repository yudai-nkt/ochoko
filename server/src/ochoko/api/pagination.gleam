//// Mastodon-style cursor pagination: `max_id`, `since_id`, `min_id`, `limit`
//// query parameters and the `Link` response header.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import ochoko/store/page.{type Page, Page}
import wisp.{type Request}

pub const default_limit = 20

pub const max_limit = 40

/// Reads the pagination parameters; `limit` defaults to 20 and is clamped to
/// 1..40. Unparseable cursors are ignored.
pub fn parse(req: Request) -> Page {
  let query = wisp.get_query(req)
  let number = fn(key) {
    list.key_find(query, key)
    |> result.try(int.parse)
    |> option.from_result
  }
  let limit =
    number("limit")
    |> option.unwrap(default_limit)
    |> int.clamp(1, max_limit)
  Page(
    max_id: number("max_id"),
    since_id: number("since_id"),
    min_id: number("min_id"),
    limit:,
  )
}

/// The `Link` header value: `next` (older, `max_id=last`) and `prev` (newer,
/// `min_id=first`). `None` when there are no items.
pub fn link_header(
  base_url: String,
  first: Option(Int),
  last: Option(Int),
) -> Option(String) {
  let separator = case string.contains(base_url, "?") {
    True -> "&"
    False -> "?"
  }
  let link = fn(param, id, rel) {
    "<"
    <> base_url
    <> separator
    <> param
    <> "="
    <> int.to_string(id)
    <> ">; rel=\""
    <> rel
    <> "\""
  }
  let parts =
    list.append(
      case last {
        Some(id) -> [link("max_id", id, "next")]
        None -> []
      },
      case first {
        Some(id) -> [link("min_id", id, "prev")]
        None -> []
      },
    )
  case parts {
    [] -> None
    _ -> Some(string.join(parts, ", "))
  }
}
