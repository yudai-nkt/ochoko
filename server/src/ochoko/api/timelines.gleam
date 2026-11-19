//// `GET /api/v1/timelines/home`.

import gleam/http.{Get}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import ochoko/api/auth
import ochoko/api/pagination
import ochoko/api/present
import ochoko/api/respond
import ochoko/context.{type Context}
import ochoko/db
import ochoko/store/statuses
import ochoko_shared/mastodon
import wisp.{type Request, type Response}

/// Adds the `Link` header for a page whose items have ids `ids`, newest
/// first, keeping `limit` in the URLs.
pub fn with_link(
  res: Response,
  ctx: Context,
  path: String,
  limit: Int,
  ids: List(Int),
) -> Response {
  let base =
    "https://" <> ctx.config.host <> path <> "?limit=" <> int.to_string(limit)
  case
    pagination.link_header(
      base,
      option.from_result(list.first(ids)),
      option.from_result(list.last(ids)),
    )
  {
    Some(link) -> response.set_header(res, "link", link)
    None -> res
  }
}

pub fn home(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  let page = pagination.parse(req)
  db.with_connection(ctx.db_path, fn(conn) {
    case statuses.home_timeline(conn, page) {
      Error(e) -> respond.server_error(e)
      Ok(rows) ->
        wisp.json_response(
          rows
            |> list.filter_map(present.status(ctx, conn, _))
            |> json.array(mastodon.status_to_json)
            |> json.to_string,
          200,
        )
        |> with_link(
          ctx,
          "/api/v1/timelines/home",
          page.limit,
          list.map(rows, fn(r) { r.id }),
        )
    }
  })
}
