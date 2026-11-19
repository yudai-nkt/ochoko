//// Public federation endpoints: WebFinger, actor and collections.

import gleam/http.{Get}
import gleam/http/response
import gleam/json
import gleam/list
import ochoko/config
import ochoko/context.{type Context}
import ochoko/crypto/rsa
import ochoko/db
import ochoko/federation/local_actor
import ochoko/store/follows
import ochoko/store/profile
import wisp.{type Request, type Response}

const activity_json = "application/activity+json; charset=utf-8"

const jrd_json = "application/jrd+json; charset=utf-8"

pub fn webfinger(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  case list.key_find(wisp.get_query(req), "resource") {
    Error(Nil) -> wisp.bad_request("missing resource")
    Ok(resource) -> {
      let c = ctx.config
      let known = [
        "acct:" <> c.handle <> "@" <> c.account_domain,
        "acct:" <> c.handle <> "@" <> c.host,
        config.actor_id(c),
      ]
      case list.contains(known, resource) {
        True ->
          wisp.ok()
          |> response.set_header("content-type", jrd_json)
          |> wisp.string_body(json.to_string(local_actor.webfinger_json(c)))
        False -> wisp.not_found()
      }
    }
  }
}

/// The actor document. Browsers are redirected to the profile page.
pub fn actor(req: Request, ctx: Context, wants_html: Bool) -> Response {
  use <- wisp.require_method(req, Get)
  case wants_html {
    True ->
      wisp.response(302)
      |> response.set_header(
        "location",
        "https://" <> ctx.config.host <> "/profile",
      )
    False ->
      case db.with_connection(ctx.db_path, profile.get) {
        Ok(p) ->
          local_actor.actor_json(ctx.config, p, rsa.public_pem(ctx.private_key))
          |> activity_response
        Error(_) -> wisp.internal_server_error()
      }
  }
}

pub fn followers(req: Request, ctx: Context) -> Response {
  collection(req, ctx, "/followers", follows.follower_count)
}

pub fn following(req: Request, ctx: Context) -> Response {
  collection(req, ctx, "/following", follows.following_count)
}

/// Statuses are not published yet, so the outbox is always empty.
pub fn outbox(req: Request, ctx: Context) -> Response {
  collection(req, ctx, "/outbox", fn(_) { Ok(0) })
}

fn collection(req, ctx: Context, suffix, count) -> Response {
  use <- wisp.require_method(req, Get)
  case db.with_connection(ctx.db_path, count) {
    Ok(n) ->
      local_actor.collection_json(config.actor_id(ctx.config) <> suffix, n)
      |> activity_response
    Error(_) -> wisp.internal_server_error()
  }
}

fn activity_response(body: json.Json) -> Response {
  wisp.ok()
  |> response.set_header("content-type", activity_json)
  |> wisp.string_body(json.to_string(body))
}
