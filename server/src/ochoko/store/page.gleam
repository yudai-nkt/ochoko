//// Cursor-pagination parameters shared by the API and the stores.

import gleam/option.{type Option}

pub type Page {
  Page(
    max_id: Option(Int),
    since_id: Option(Int),
    min_id: Option(Int),
    limit: Int,
  )
}
