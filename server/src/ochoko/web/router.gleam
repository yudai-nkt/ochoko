import gleam/http.{Options}
import gleam/http/request
import gleam/http/response
import gleam/string
import ochoko/context.{type Context}
import ochoko/web/federation
import wisp.{type Request, type Response}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use <- cors(req)
  case wisp.path_segments(req) {
    ["health"] -> wisp.ok() |> wisp.string_body("ok")
    [".well-known", "webfinger"] -> federation.webfinger(req, ctx)
    ["me"] -> federation.actor(req, ctx, wants_html(req))
    ["me", "followers"] -> federation.followers(req, ctx)
    ["me", "following"] -> federation.following(req, ctx)
    ["me", "outbox"] -> federation.outbox(req, ctx)
    _ -> wisp.not_found()
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
