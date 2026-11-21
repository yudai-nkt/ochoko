//// `GET /api/v2/search`: accounts only. Statuses and hashtags are always
//// empty.

import gleam/http.{Get}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import ochoko/api/accounts
import ochoko/api/auth
import ochoko/api/pagination
import ochoko/api/params
import ochoko/api/present
import ochoko/api/respond
import ochoko/config
import ochoko/context.{type Context}
import ochoko/db
import ochoko/federation/remote_actor
import ochoko/federation/remote_actor_types.{type RemoteActor}
import ochoko/store/remote_actors
import ochoko_shared/mastodon
import sqlight
import wisp.{type Request, type Response}

pub fn search(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  use <- auth.require_user(ctx, req)
  use p <- params.read(req)
  let q = string.trim(params.get(p, "q"))
  let resolve = params.get(p, "resolve") == "true"
  let limit =
    int.parse(params.get(p, "limit"))
    |> result.unwrap(pagination.default_limit)
    |> int.clamp(1, pagination.max_limit)
  let wants_accounts = case params.get(p, "type") {
    "" | "accounts" -> True
    _ -> False
  }
  let accounts = case wants_accounts && q != "" {
    False -> []
    True ->
      db.with_connection(ctx.db_path, fn(conn) {
        find_accounts(ctx, conn, q, resolve, limit)
        |> list.unique
        |> list.map(fn(found) {
          case found {
            Local -> present.local_account(ctx, conn)
            Remote(actor) -> present.remote_account(ctx, actor, conn)
          }
        })
      })
  }
  mastodon.SearchResults(accounts:, statuses: [], hashtags: [])
  |> mastodon.search_results_to_json
  |> respond.json_ok
}

type Found {
  Local
  Remote(RemoteActor)
}

fn is_url(q: String) -> Bool {
  string.starts_with(q, "https://") || string.starts_with(q, "http://")
}

fn find_accounts(
  ctx: Context,
  conn: sqlight.Connection,
  q: String,
  resolve: Bool,
  limit: Int,
) -> List(Found) {
  case is_url(q) {
    True -> find_by_url(ctx, conn, q, resolve)
    False -> {
      let stripped = case string.starts_with(q, "@") {
        True -> string.drop_start(q, 1)
        False -> q
      }
      let exact = case string.split_once(stripped, "@") {
        Ok(#(user, domain)) if user != "" && domain != "" ->
          case accounts.is_local_acct(ctx, user, domain) {
            True -> Ok(Local)
            False ->
              accounts.find_remote(ctx, conn, user, domain, resolve)
              |> result.map(Remote)
          }
        _ -> Error(Nil)
      }
      case exact {
        Ok(found) -> [found]
        Error(Nil) -> {
          let cached =
            remote_actors.search_prefix(conn, stripped, limit)
            |> result.unwrap([])
            |> list.map(Remote)
          case local_matches(ctx, stripped) {
            True -> [Local, ..cached]
            False -> cached
          }
        }
      }
    }
  }
}

fn local_matches(ctx: Context, prefix: String) -> Bool {
  let prefix = string.lowercase(prefix)
  prefix != ""
  && {
    string.starts_with(string.lowercase(ctx.config.handle), prefix)
    || string.starts_with(string.lowercase(config.acct(ctx.config)), prefix)
  }
}

fn find_by_url(
  ctx: Context,
  conn: sqlight.Connection,
  url: String,
  resolve: Bool,
) -> List(Found) {
  case url == config.actor_id(ctx.config) {
    True -> [Local]
    False ->
      case resolve {
        True ->
          case remote_actor.get_or_fetch(ctx, url) {
            Ok(actor) -> [Remote(actor)]
            Error(_) -> []
          }
        False ->
          case remote_actors.get_by_uri(conn, url) {
            Ok(Some(actor)) -> [Remote(actor)]
            _ -> []
          }
      }
  }
}
