//// Account endpoints: verify_credentials, lookup, statuses, followers,
//// following, relationships and the follow actions.

import gleam/http.{Get, Post}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import ochoko/api/auth
import ochoko/api/pagination
import ochoko/api/params
import ochoko/api/present
import ochoko/context.{type Context}
import ochoko/db
import ochoko/federation/activities
import ochoko/federation/remote_actor
import ochoko/federation/remote_actor_types.{type RemoteActor}
import ochoko/store/deliveries
import ochoko/store/follows
import ochoko/store/remote_actors
import ochoko/store/statuses
import ochoko_shared/mastodon
import sqlight
import wisp.{type Request, type Response}

/// What an account id in a URL refers to.
type Target {
  Local
  Remote(RemoteActor)
}

pub fn json_ok(body: json.Json) -> Response {
  wisp.json_response(json.to_string(body), 200)
}

fn error_response(message: String, status: Int) -> Response {
  wisp.json_response(
    json.to_string(mastodon.error_to_json(mastodon.Error(message, None))),
    status,
  )
}

pub fn not_found() -> Response {
  error_response("Record not found", 404)
}

fn server_error(_: sqlight.Error) -> Response {
  wisp.internal_server_error()
}

fn find_target(conn: sqlight.Connection, id: String) -> Result(Target, Nil) {
  case id {
    "0" -> Ok(Local)
    _ ->
      case int.parse(id) {
        Ok(n) ->
          case remote_actors.get(conn, n) {
            Ok(Some(actor)) -> Ok(Remote(actor))
            _ -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
  }
}

fn with_target(
  ctx: Context,
  id: String,
  next: fn(sqlight.Connection, Target) -> Response,
) -> Response {
  db.with_connection(ctx.db_path, fn(conn) {
    case find_target(conn, id) {
      Ok(target) -> next(conn, target)
      Error(Nil) -> not_found()
    }
  })
}

fn account_json(
  ctx: Context,
  conn: sqlight.Connection,
  target: Target,
) -> json.Json {
  mastodon.account_to_json(case target {
    Local -> present.local_account(ctx, conn)
    Remote(actor) -> present.remote_account(ctx, actor, conn)
  })
}

pub fn verify_credentials(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  db.with_connection(ctx.db_path, fn(conn) {
    present.credential_account(ctx, conn)
    |> mastodon.credential_account_to_json
    |> json_ok
  })
}

pub fn show(req: Request, ctx: Context, id: String) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  use conn, target <- with_target(ctx, id)
  json_ok(account_json(ctx, conn, target))
}

/// A cached actor `user@domain` (exact match), else, if `resolve`, one
/// resolved through WebFinger.
pub fn find_remote(
  ctx: Context,
  conn: sqlight.Connection,
  user: String,
  domain: String,
  resolve: Bool,
) -> Result(RemoteActor, Nil) {
  let wanted = string.lowercase(user <> "@" <> domain)
  let cached =
    remote_actors.search_prefix(conn, wanted, 20)
    |> result.unwrap([])
    |> list.find(fn(a) {
      string.lowercase(a.username <> "@" <> a.domain) == wanted
    })
  case cached, resolve {
    Ok(actor), _ -> Ok(actor)
    Error(Nil), True ->
      remote_actor.resolve_acct(ctx, user, domain) |> result.replace_error(Nil)
    Error(Nil), False -> Error(Nil)
  }
}

/// True when `user@domain` names our own account.
pub fn is_local_acct(ctx: Context, user: String, domain: String) -> Bool {
  string.lowercase(user) == string.lowercase(ctx.config.handle)
  && list.contains(
    [ctx.config.account_domain, ctx.config.host] |> list.map(string.lowercase),
    string.lowercase(domain),
  )
}

pub fn lookup(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  use p <- params.read(req)
  let acct = string.trim(params.get(p, "acct"))
  let acct = case string.starts_with(acct, "@") {
    True -> string.drop_start(acct, 1)
    False -> acct
  }
  db.with_connection(ctx.db_path, fn(conn) {
    let found = case string.split_once(acct, "@") {
      Ok(#(user, domain)) if user != "" && domain != "" ->
        case is_local_acct(ctx, user, domain) {
          True -> Ok(Local)
          False ->
            find_remote(ctx, conn, user, domain, True) |> result.map(Remote)
        }
      _ ->
        case
          acct != ""
          && string.lowercase(acct) == string.lowercase(ctx.config.handle)
        {
          True -> Ok(Local)
          False -> Error(Nil)
        }
    }
    case found {
      Ok(target) -> json_ok(account_json(ctx, conn, target))
      Error(Nil) -> not_found()
    }
  })
}

pub fn statuses(req: Request, ctx: Context, id: String) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  use conn, target <- with_target(ctx, id)
  let actor_id = case target {
    Local -> None
    Remote(actor) -> Some(actor.id)
  }
  let page = pagination.parse(req)
  let pinned = list.key_find(wisp.get_query(req), "pinned") == Ok("true")
  case pinned {
    True -> json_ok(json.preprocessed_array([]))
    False ->
      case statuses.list_by_actor(conn, actor_id, page) {
        Error(e) -> server_error(e)
        Ok(rows) -> {
          let ids = list.map(rows, fn(r) { r.id })
          let base =
            "https://"
            <> ctx.config.host
            <> "/api/v1/accounts/"
            <> id
            <> "/statuses?limit="
            <> int.to_string(page.limit)
          let res =
            json_ok(
              rows
              |> list.filter_map(present.status(ctx, conn, _))
              |> json.array(mastodon.status_to_json),
            )
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
      }
  }
}

/// Followers and following of our own account; remote accounts' lists are
/// unknown and empty. Not paginated.
pub fn followers(req: Request, ctx: Context, id: String) -> Response {
  relations(req, ctx, id, follows.followers)
}

pub fn following(req: Request, ctx: Context, id: String) -> Response {
  relations(req, ctx, id, follows.following)
}

fn relations(
  req: Request,
  ctx: Context,
  id: String,
  list_ids: fn(sqlight.Connection) -> Result(List(Int), sqlight.Error),
) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  use conn, target <- with_target(ctx, id)
  case target {
    Remote(_) -> json_ok(json.preprocessed_array([]))
    Local ->
      case list_ids(conn) {
        Error(e) -> server_error(e)
        Ok(ids) ->
          ids
          |> list.filter_map(fn(id) {
            case remote_actors.get(conn, id) {
              Ok(Some(actor)) -> Ok(present.remote_account(ctx, actor, conn))
              _ -> Error(Nil)
            }
          })
          |> json.array(mastodon.account_to_json)
          |> json_ok
      }
  }
}

pub fn relationships(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  use p <- params.read(req)
  db.with_connection(ctx.db_path, fn(conn) {
    params.get_list(p, "id")
    |> list.filter_map(fn(id) {
      case find_target(conn, id) {
        Ok(Remote(actor)) -> Ok(present.relationship(conn, actor.id))
        _ -> Error(Nil)
      }
    })
    |> json.array(mastodon.relationship_to_json)
    |> json_ok
  })
}

/// Runs `action` against a remote account and answers with the resulting
/// relationship. Following ourselves is a validation error.
fn remote_action(
  req: Request,
  ctx: Context,
  id: String,
  action: fn(sqlight.Connection, RemoteActor) -> Result(Nil, sqlight.Error),
) -> Response {
  use <- wisp.require_method(req, Post)
  use <- auth.require_user(ctx, req)
  use conn, target <- with_target(ctx, id)
  case target {
    Local -> error_response("Validation failed: can't target yourself", 422)
    Remote(actor) ->
      case action(conn, actor) {
        Error(e) -> server_error(e)
        Ok(Nil) ->
          present.relationship(conn, actor.id)
          |> mastodon.relationship_to_json
          |> json_ok
      }
  }
}

pub fn follow(req: Request, ctx: Context, id: String) -> Response {
  use conn, actor <- remote_action(req, ctx, id)
  use state <- result.try(follows.is_following(conn, actor.id))
  case state {
    Some(_) -> Ok(Nil)
    None -> {
      let #(follow_id, body) = activities.follow(ctx.config, actor.uri)
      use _ <- result.try(follows.add_following(
        conn,
        actor.id,
        follow_id,
        ctx.now(),
      ))
      deliveries.enqueue(conn, [actor.inbox], json.to_string(body), ctx.now())
    }
  }
}

pub fn unfollow(req: Request, ctx: Context, id: String) -> Response {
  use conn, actor <- remote_action(req, ctx, id)
  use follow_uri <- result.try(follows.following_follow_uri(conn, actor.id))
  case follow_uri {
    None -> Ok(Nil)
    Some(follow_uri) -> {
      let undo =
        activities.undo(
          ctx.config,
          activities.sent_follow(ctx.config, follow_uri, actor.uri),
        )
      use _ <- result.try(deliveries.enqueue(
        conn,
        [actor.inbox],
        json.to_string(undo),
        ctx.now(),
      ))
      follows.remove_following(conn, actor.id)
    }
  }
}

pub fn remove_from_followers(
  req: Request,
  ctx: Context,
  id: String,
) -> Response {
  use conn, actor <- remote_action(req, ctx, id)
  use follow_uri <- result.try(follows.follower_follow_uri(conn, actor.id))
  case follow_uri {
    None -> Ok(Nil)
    Some(follow_uri) -> {
      let reject = activities.reject(ctx.config, follow_uri, actor.uri)
      use _ <- result.try(deliveries.enqueue(
        conn,
        [actor.inbox],
        json.to_string(reject),
        ctx.now(),
      ))
      follows.remove_follower(conn, actor.id)
    }
  }
}
