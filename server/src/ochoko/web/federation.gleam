//// Public federation endpoints: WebFinger, actor and collections.

import gleam/http.{Get}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import ochoko/config
import ochoko/context.{type Context}
import ochoko/crypto/rsa
import ochoko/db
import ochoko/federation/activities
import ochoko/federation/inbox
import ochoko/federation/local_actor
import ochoko/store/follows
import ochoko/store/profile
import ochoko/store/statuses
import sqlight
import wisp.{type Request, type Response}

const activity_json = "application/activity+json; charset=utf-8"

const jrd_json = "application/jrd+json; charset=utf-8"

pub fn webfinger(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  case list.key_find(wisp.get_query(req), "resource") {
    Error(Nil) -> wisp.bad_request("missing resource")
    Ok(resource) ->
      case is_our_resource(ctx.config, resource) {
        True ->
          wisp.ok()
          |> response.set_header("content-type", jrd_json)
          |> wisp.string_body(
            json.to_string(local_actor.webfinger_json(ctx.config)),
          )
        False -> wisp.not_found()
      }
  }
}

/// `acct:user@domain` (scheme optional, compared case-insensitively) for our
/// handle at the account domain or the host, or our actor URL.
fn is_our_resource(c: config.Config, resource: String) -> Bool {
  let resource = string.trim(resource)
  let lowered = string.lowercase(resource)
  let acct = case string.starts_with(lowered, "acct:") {
    True -> string.drop_start(lowered, 5)
    False -> lowered
  }
  let acct = case string.starts_with(acct, "@") {
    True -> string.drop_start(acct, 1)
    False -> acct
  }
  let handle = string.lowercase(c.handle)
  resource == config.actor_id(c)
  || list.contains(
    [
      handle <> "@" <> string.lowercase(c.account_domain),
      handle <> "@" <> string.lowercase(c.host),
    ],
    acct,
  )
}

/// The actor document. Browsers are redirected to the profile page.
pub fn actor(req: Request, ctx: Context, wants_html: Bool) -> Response {
  use <- wisp.require_method(req, Get)
  case wants_html {
    True ->
      wisp.response(302)
      |> response.set_header("location", config.profile_url(ctx.config))
    False ->
      case db.with_connection(ctx.db_path, profile.get) {
        Ok(p) ->
          local_actor.actor_json(ctx.config, p, rsa.public_pem(ctx.private_key))
          |> activity_response
        Error(e) -> server_error(e)
      }
  }
}

pub fn followers(req: Request, ctx: Context) -> Response {
  collection(req, ctx, config.followers_uri, follows.follower_count)
}

pub fn following(req: Request, ctx: Context) -> Response {
  collection(req, ctx, config.following_uri, follows.following_count)
}

pub fn inbox(req: Request, ctx: Context) -> Response {
  inbox.handle(ctx, req)
}

/// The outbox exposes only the number of our live statuses.
pub fn outbox(req: Request, ctx: Context) -> Response {
  collection(req, ctx, config.outbox_uri, statuses.count_by_actor(_, None))
}

/// One of our statuses as a `Note`. Deleted ones are gone (410); remote and
/// unknown ones are not ours to serve (404).
pub fn status(req: Request, ctx: Context, id: String) -> Response {
  use <- wisp.require_method(req, Get)
  let found = case int.parse(id) {
    Error(Nil) -> Ok(None)
    Ok(n) -> db.with_connection(ctx.db_path, statuses.get(_, n))
  }
  case found {
    Error(e) -> server_error(e)
    Ok(Some(row)) if row.actor_id == None ->
      case row.deleted_at {
        Some(_) ->
          wisp.response(410)
          |> response.set_header("content-type", activity_json)
          |> wisp.string_body(json.to_string(activities.tombstone_json(row)))
        None -> activity_response(activities.note_json(ctx.config, row))
      }
    Ok(_) -> wisp.not_found()
  }
}

fn collection(
  req: Request,
  ctx: Context,
  id: fn(config.Config) -> String,
  count: fn(sqlight.Connection) -> Result(Int, sqlight.Error),
) -> Response {
  use <- wisp.require_method(req, Get)
  case db.with_connection(ctx.db_path, count) {
    Ok(n) ->
      local_actor.collection_json(id(ctx.config), n)
      |> activity_response
    Error(e) -> server_error(e)
  }
}

fn server_error(e: sqlight.Error) -> Response {
  wisp.log_error("federation: database error: " <> e.message)
  wisp.internal_server_error()
}

fn activity_response(body: json.Json) -> Response {
  wisp.ok()
  |> response.set_header("content-type", activity_json)
  |> wisp.string_body(json.to_string(body))
}
