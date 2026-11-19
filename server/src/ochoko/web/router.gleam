import gleam/http.{Options}
import gleam/http/request
import gleam/http/response
import gleam/string
import ochoko/api/accounts
import ochoko/api/apps
import ochoko/api/instance
import ochoko/api/notifications
import ochoko/api/oauth
import ochoko/api/search
import ochoko/api/statuses
import ochoko/api/stubs
import ochoko/api/timelines
import ochoko/context.{type Context}
import ochoko/web/federation
import wisp.{type Request, type Response}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use <- cors(req)
  use <- serve_static(req)
  case wisp.path_segments(req) {
    ["health"] -> wisp.ok() |> wisp.string_body("ok")
    [".well-known", "webfinger"] -> federation.webfinger(req, ctx)
    ["me"] -> federation.actor(req, ctx, wants_html(req))
    ["me", "followers"] -> federation.followers(req, ctx)
    ["me", "following"] -> federation.following(req, ctx)
    ["me", "inbox"] | ["inbox"] -> federation.inbox(req, ctx)
    ["me", "outbox"] -> federation.outbox(req, ctx)
    ["api", "v1", "apps"] -> apps.create(req, ctx)
    ["api", "v1", "apps", "verify_credentials"] ->
      apps.verify_credentials(req, ctx)
    ["api", "v1", "instance"] -> instance.v1(req, ctx)
    ["api", "v2", "instance"] -> instance.v2(req, ctx)
    ["api", "v2", "search"] -> search.search(req, ctx)
    ["api", "v1", "accounts", "verify_credentials"] ->
      accounts.verify_credentials(req, ctx)
    ["api", "v1", "accounts", "lookup"] -> accounts.lookup(req, ctx)
    ["api", "v1", "accounts", "relationships"] ->
      accounts.relationships(req, ctx)
    ["api", "v1", "accounts", id] -> accounts.show(req, ctx, id)
    ["api", "v1", "accounts", id, "statuses"] -> accounts.statuses(req, ctx, id)
    ["api", "v1", "accounts", id, "followers"] ->
      accounts.followers(req, ctx, id)
    ["api", "v1", "accounts", id, "following"] ->
      accounts.following(req, ctx, id)
    ["api", "v1", "accounts", id, "follow"] -> accounts.follow(req, ctx, id)
    ["api", "v1", "accounts", id, "unfollow"] -> accounts.unfollow(req, ctx, id)
    ["api", "v1", "accounts", id, "remove_from_followers"] ->
      accounts.remove_from_followers(req, ctx, id)
    ["api", "v1", "statuses"] -> statuses.create(req, ctx)
    ["api", "v1", "statuses", id] ->
      case req.method {
        http.Delete -> statuses.delete(req, ctx, id)
        _ -> statuses.show(req, ctx, id)
      }
    ["api", "v1", "statuses", id, "context"] -> statuses.context(req, ctx, id)
    ["api", "v1", "timelines", "home"] -> timelines.home(req, ctx)
    ["api", "v1", "notifications"] -> notifications.index(req, ctx)
    ["api", "v1", "notifications", "clear"] -> notifications.clear(req, ctx)
    ["api", "v1", "notifications", id] -> notifications.show(req, ctx, id)
    ["api", "v1", "notifications", id, "dismiss"] ->
      notifications.dismiss(req, ctx, id)
    ["statuses", id] -> federation.status(req, ctx, id)
    ["oauth", "authorize"] -> oauth.authorize(req, ctx)
    ["oauth", "token"] -> oauth.token(req, ctx)
    ["oauth", "revoke"] -> oauth.revoke(req, ctx)
    ["api", ..] -> stubs.handle(req, ctx)
    _ -> wisp.not_found()
  }
}

/// Serve `priv/static` under `/static`.
fn serve_static(req: Request, next: fn() -> Response) -> Response {
  case wisp.priv_directory("ochoko") {
    Ok(priv) ->
      wisp.serve_static(req, under: "/static", from: priv <> "/static", next:)
    Error(Nil) -> next()
  }
}

/// Answer preflight requests with 204 and add CORS headers to every response.
pub fn cors(req: Request, next: fn() -> Response) -> Response {
  let res = case req.method {
    Options -> wisp.response(204)
    _ -> next()
  }
  res
  |> response.set_header("access-control-allow-origin", "*")
  |> response.set_header(
    "access-control-allow-methods",
    "GET, POST, PUT, PATCH, DELETE, OPTIONS",
  )
  |> response.set_header(
    "access-control-allow-headers",
    "Authorization, Content-Type, Idempotency-Key",
  )
  |> response.set_header("access-control-expose-headers", "Link")
}

/// True for browsers: `Accept` mentions `text/html` but no ActivityPub type.
pub fn wants_html(req: Request) -> Bool {
  case request.get_header(req, "accept") {
    Error(Nil) -> False
    Ok(accept) -> {
      let accept = string.lowercase(accept)
      string.contains(accept, "text/html")
      && !string.contains(accept, "activity+json")
      && !string.contains(accept, "ld+json")
    }
  }
}
