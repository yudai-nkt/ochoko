//// Notification endpoints. Only `follow` notifications exist, so the
//// `types[]` / `exclude_types[]` filters either keep or drop everything.

import gleam/http.{Get, Post}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import ochoko/api/accounts
import ochoko/api/auth
import ochoko/api/pagination
import ochoko/api/params
import ochoko/api/present
import ochoko/api/timelines
import ochoko/context.{type Context}
import ochoko/db
import ochoko/store/notifications.{type NotificationRow}
import ochoko/store/remote_actors
import ochoko_shared/mastodon
import sqlight
import wisp.{type Request, type Response}

fn to_entity(
  ctx: Context,
  conn: sqlight.Connection,
  row: NotificationRow,
) -> Result(mastodon.Notification, Nil) {
  case remote_actors.get(conn, row.actor_id) {
    Ok(Some(actor)) ->
      Ok(mastodon.Notification(
        id: int.to_string(row.id),
        kind: mastodon.FollowNotification,
        created_at: row.created_at,
        account: present.remote_account(ctx, actor, conn),
        status: None,
      ))
    _ -> Error(Nil)
  }
}

/// Whether `follow` notifications pass the `types[]` / `exclude_types[]`
/// filters.
fn follow_wanted(p: params.Params) -> Bool {
  let types = params.get_list(p, "types")
  let excluded = params.get_list(p, "exclude_types")
  { types == [] || list.contains(types, "follow") }
  && !list.contains(excluded, "follow")
}

pub fn index(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  use p <- params.read(req)
  let page = pagination.parse(req)
  db.with_connection(ctx.db_path, fn(conn) {
    let rows = case follow_wanted(p) {
      True -> notifications.list(conn, page)
      False -> Ok([])
    }
    case rows {
      Error(_) -> wisp.internal_server_error()
      Ok(rows) ->
        accounts.json_ok(
          rows
          |> list.filter_map(to_entity(ctx, conn, _))
          |> json.array(mastodon.notification_to_json),
        )
        |> timelines.with_link(
          ctx,
          "/api/v1/notifications",
          page.limit,
          list.map(rows, fn(r) { r.id }),
        )
    }
  })
}

pub fn show(req: Request, ctx: Context, id: String) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  db.with_connection(ctx.db_path, fn(conn) {
    let found =
      int.parse(id)
      |> result.replace_error(Nil)
      |> result.try(fn(n) {
        case notifications.get(conn, n) {
          Ok(Some(row)) -> to_entity(ctx, conn, row)
          _ -> Error(Nil)
        }
      })
    case found {
      Ok(n) -> accounts.json_ok(mastodon.notification_to_json(n))
      Error(Nil) -> accounts.not_found()
    }
  })
}

pub fn clear(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use <- auth.require_user(ctx, req)
  db.with_connection(ctx.db_path, fn(conn) {
    case notifications.clear(conn) {
      Ok(Nil) -> accounts.json_ok(json.object([]))
      Error(_) -> wisp.internal_server_error()
    }
  })
}

pub fn dismiss(req: Request, ctx: Context, id: String) -> Response {
  use <- wisp.require_method(req, Post)
  use <- auth.require_user(ctx, req)
  db.with_connection(ctx.db_path, fn(conn) {
    case int.parse(id) {
      Error(Nil) -> accounts.not_found()
      Ok(n) ->
        case notifications.dismiss(conn, n) {
          Ok(Nil) -> accounts.json_ok(json.object([]))
          Error(_) -> wisp.internal_server_error()
        }
    }
  })
}
