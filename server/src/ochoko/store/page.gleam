//// Cursor-pagination parameters shared by the API and the stores.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sqlight

pub type Page {
  Page(
    max_id: Option(Int),
    since_id: Option(Int),
    min_id: Option(Int),
    limit: Int,
  )
}

/// SQL conditions (each prefixed with ` AND `) and their arguments for the
/// cursors of `page`, applied to the `id` column.
pub fn bounds(page: Page) -> #(String, List(sqlight.Value)) {
  [
    #("id < ?", page.max_id),
    #("id > ?", page.since_id),
    #("id > ?", page.min_id),
  ]
  |> list.filter_map(fn(bound) {
    case bound.1 {
      Some(n) -> Ok(#(" AND " <> bound.0, sqlight.int(n)))
      None -> Error(Nil)
    }
  })
  |> list.unzip
  |> fn(parts) { #(string.concat(parts.0), parts.1) }
}

/// The `ORDER BY ... LIMIT ?` tail: `min_id` pages forward, so its window is
/// read ascending (and must be reversed afterwards, see `finish`).
pub fn order_limit(page: Page) -> String {
  case option.is_some(page.min_id) {
    True -> " ORDER BY id ASC LIMIT ?"
    False -> " ORDER BY id DESC LIMIT ?"
  }
}

/// Puts rows read with `order_limit` back into newest-first order.
pub fn finish(page: Page, rows: List(a)) -> List(a) {
  case option.is_some(page.min_id) {
    True -> list.reverse(rows)
    False -> rows
  }
}
