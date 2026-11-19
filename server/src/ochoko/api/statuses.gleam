//// Status endpoints: post, show, delete and (empty) context.

import gleam/dict
import gleam/http.{Delete, Get, Post}
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import ochoko/api/accounts.{error_response, json_ok, not_found}
import ochoko/api/auth
import ochoko/api/params.{type Params}
import ochoko/api/present
import ochoko/context.{type Context}
import ochoko/db
import ochoko/federation/activities
import ochoko/html
import ochoko/store/deliveries
import ochoko/store/statuses.{type StatusRow}
import ochoko_shared/mastodon.{type Visibility, Public, Unlisted}
import sqlight
import wisp.{type Request, type Response}

/// Maximum length of a status, in graphemes (as advertised by the instance).
const max_characters = 500

fn server_error(_: sqlight.Error) -> Response {
  wisp.internal_server_error()
}

fn invalid(message: String) -> Response {
  error_response("Validation failed: " <> message, 422)
}

/// The presented status. Our own statuses always have a loadable author.
fn present_status(
  ctx: Context,
  conn: sqlight.Connection,
  row: StatusRow,
  text: Option(String),
) -> Response {
  case present.status(ctx, conn, row) {
    Ok(status) ->
      json_ok(mastodon.status_to_json(mastodon.Status(..status, text:)))
    Error(Nil) -> not_found()
  }
}

fn parse_visibility(raw: String) -> Result(Visibility, String) {
  case raw {
    "" | "public" -> Ok(Public)
    "unlisted" -> Ok(Unlisted)
    "private" | "direct" -> Error("visibility '" <> raw <> "' is not supported")
    _ -> Error("visibility is invalid")
  }
}

fn is_true(raw: String) -> Bool {
  list.contains(["true", "1", "on", "t", "yes"], string.lowercase(raw))
}

/// Parameters we accept but cannot honour.
fn unsupported(p: Params) -> Result(Nil, String) {
  let has_poll =
    dict.keys(p)
    |> list.any(fn(k) {
      string.starts_with(k, "poll") && params.get(p, k) != ""
    })
  case
    params.get(p, "in_reply_to_id") != "",
    params.get_list(p, "media_ids"),
    has_poll
  {
    True, _, _ -> Error("replies are not supported")
    _, [_, ..], _ -> Error("media attachments are not supported")
    _, _, True -> Error("polls are not supported")
    _, _, _ -> Ok(Nil)
  }
}

/// `POST /api/v1/statuses`
pub fn create(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use <- auth.require_user(ctx, req)
  use p <- params.read(req)
  let text = params.get(p, "status")
  let key = request.get_header(req, "idempotency-key") |> option.from_result
  case unsupported(p), parse_visibility(params.get(p, "visibility")) {
    Error(message), _ | _, Error(message) -> invalid(message)
    Ok(Nil), Ok(visibility) ->
      case string.trim(text) == "", string.length(text) > max_characters {
        True, _ -> invalid("text can't be blank")
        _, True ->
          invalid(
            "text is too long (maximum is "
            <> int.to_string(max_characters)
            <> " characters)",
          )
        False, False ->
          db.with_connection(ctx.db_path, fn(conn) {
            let language = case params.get(p, "language") {
              "" -> None
              code -> Some(code)
            }
            let post = fn() {
              insert_and_enqueue(
                ctx,
                conn,
                text,
                visibility,
                params.get(p, "spoiler_text"),
                is_true(params.get(p, "sensitive")),
                language,
                key,
              )
            }
            case db.transaction(conn, post) {
              Ok(row) -> present_status(ctx, conn, row, None)
              Error(e) -> server_error(e)
            }
          })
      }
  }
}

/// Within one transaction: reuse the status of a known idempotency key, or
/// store the new status and queue its `Create` for every follower.
fn insert_and_enqueue(
  ctx: Context,
  conn: sqlight.Connection,
  text: String,
  visibility: Visibility,
  spoiler: String,
  sensitive: Bool,
  language: Option(String),
  key: Option(String),
) -> Result(StatusRow, sqlight.Error) {
  let now = ctx.now()
  use existing <- result.try(case key {
    Some(k) -> statuses.find_by_idempotency_key(conn, k, now)
    None -> Ok(None)
  })
  case existing {
    Some(row) -> Ok(row)
    None -> {
      use row <- result.try(statuses.insert_own(
        conn,
        ctx.config,
        text,
        html.text_to_html(text),
        visibility,
        spoiler,
        sensitive,
        language,
        now,
      ))
      use _ <- result.try(case key {
        Some(k) -> statuses.remember_idempotency_key(conn, k, row.id, now)
        None -> Ok(Nil)
      })
      use _ <- result.map(deliveries.enqueue(
        conn,
        deliveries.inboxes_for_followers(conn),
        json.to_string(activities.create(ctx.config, row)),
        now,
      ))
      row
    }
  }
}

/// The live (not deleted) status with the textual id, if it exists.
fn find_live(
  conn: sqlight.Connection,
  id: String,
) -> Result(Option(StatusRow), sqlight.Error) {
  case int.parse(id) {
    Error(Nil) -> Ok(None)
    Ok(n) ->
      statuses.get(conn, n)
      |> result.map(
        option.then(_, fn(row) {
          case row.deleted_at {
            None -> Some(row)
            Some(_) -> None
          }
        }),
      )
  }
}

/// `GET /api/v1/statuses/:id`
pub fn show(req: Request, ctx: Context, id: String) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  db.with_connection(ctx.db_path, fn(conn) {
    case find_live(conn, id) {
      Error(e) -> server_error(e)
      Ok(None) -> not_found()
      Ok(Some(row)) -> present_status(ctx, conn, row, None)
    }
  })
}

/// `GET /api/v1/statuses/:id/context`: there are no threads yet.
pub fn context(req: Request, ctx: Context, id: String) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  db.with_connection(ctx.db_path, fn(conn) {
    case find_live(conn, id) {
      Error(e) -> server_error(e)
      Ok(None) -> not_found()
      Ok(Some(_)) ->
        json_ok(
          json.object([
            #("ancestors", json.preprocessed_array([])),
            #("descendants", json.preprocessed_array([])),
          ]),
        )
    }
  })
}

/// `DELETE /api/v1/statuses/:id`: our own statuses only. The response
/// carries the source `text`, so clients can offer "delete & redraft".
pub fn delete(req: Request, ctx: Context, id: String) -> Response {
  use <- wisp.require_method(req, Delete)
  use <- auth.require_user(ctx, req)
  db.with_connection(ctx.db_path, fn(conn) {
    case find_live(conn, id) {
      Error(e) -> server_error(e)
      Ok(Some(row)) if row.actor_id == None -> {
        let now = ctx.now()
        let removed =
          db.transaction(conn, fn() {
            use live <- result.try(find_live(conn, id))
            case live {
              None -> Ok(False)
              Some(_) -> {
                use _ <- result.try(statuses.mark_deleted(conn, row.id, now))
                use _ <- result.map(deliveries.enqueue(
                  conn,
                  deliveries.inboxes_for_followers(conn),
                  json.to_string(activities.delete(ctx.config, row)),
                  now,
                ))
                True
              }
            }
          })
        case removed {
          Ok(True) -> present_status(ctx, conn, row, row.text)
          Ok(False) -> not_found()
          Error(e) -> server_error(e)
        }
      }
      Ok(_) -> not_found()
    }
  })
}
