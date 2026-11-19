//// Client-compat stubs: endpoints Elk calls on startup that we answer with a
//// valid empty body. All of them require a user token.

import gleam/http.{type Method, Get, Post}
import gleam/list
import gleam/string
import ochoko/api/auth
import ochoko/api/respond
import ochoko/context.{type Context}
import wisp.{type Request, type Response}

/// `#(method, path pattern, body)`. In a pattern, `:name` matches one
/// segment and a trailing `*` matches the rest.
pub const table: List(#(Method, String, String)) = [
  #(Get, "/api/v1/custom_emojis", "[]"),
  #(Get, "/api/v1/filters", "[]"),
  #(Get, "/api/v2/filters", "[]"),
  #(Get, "/api/v1/lists", "[]"),
  #(Get, "/api/v1/markers", "{}"),
  #(Post, "/api/v1/markers", "{}"),
  #(
    Get,
    "/api/v1/preferences",
    "{\"posting:default:visibility\":\"public\",\"posting:default:sensitive\":false,\"posting:default:language\":null,\"reading:expand:media\":\"default\",\"reading:expand:spoilers\":false}",
  ),
  #(Get, "/api/v1/announcements", "[]"),
  #(Get, "/api/v1/trends/*", "[]"),
  #(Get, "/api/v1/followed_tags", "[]"),
  #(Get, "/api/v1/conversations", "[]"),
  #(Get, "/api/v1/timelines/public", "[]"),
  #(Get, "/api/v1/timelines/tag/:tag", "[]"),
  #(Get, "/api/v1/favourites", "[]"),
  #(Get, "/api/v1/bookmarks", "[]"),
  #(Get, "/api/v1/blocks", "[]"),
  #(Get, "/api/v1/mutes", "[]"),
  #(Get, "/api/v1/domain_blocks", "[]"),
  #(Get, "/api/v1/follow_requests", "[]"),
  #(Get, "/api/v1/featured_tags", "[]"),
  #(Get, "/api/v1/accounts/:id/featured_tags", "[]"),
  #(Get, "/api/v1/accounts/:id/lists", "[]"),
  #(Get, "/api/v1/push/subscription", "{\"error\":\"Record not found\"}"),
]

/// Replaces every `:name` segment and the trailing `*` of `pattern` with
/// `value`, giving a concrete path.
pub fn fill(pattern: String, value: String) -> String {
  pattern
  |> string.split("/")
  |> list.map(fn(segment) {
    case segment == "*" || string.starts_with(segment, ":") {
      True -> value
      False -> segment
    }
  })
  |> string.join("/")
}

fn matches(pattern: List(String), path: List(String)) -> Bool {
  case pattern, path {
    [], [] -> True
    ["*"], [_, ..] -> True
    [p, ..pattern], [s, ..path] ->
      { string.starts_with(p, ":") || p == s } && matches(pattern, path)
    _, _ -> False
  }
}

/// Answers the request from the stub table, or a JSON 404 if no stub
/// matches (this also covers every unknown `/api/*` path).
pub fn handle(req: Request, ctx: Context) -> Response {
  let path = wisp.path_segments(req)
  let found =
    list.find(table, fn(stub) {
      stub.0 == req.method
      && matches(
        string.split(stub.1, "/") |> list.filter(fn(s) { s != "" }),
        path,
      )
    })
  case found {
    Error(Nil) -> respond.not_found()
    Ok(#(_, _, body)) -> {
      use <- auth.require_user(ctx, req)
      let status = case string.contains(body, "\"error\"") {
        True -> 404
        False -> 200
      }
      wisp.json_response(body, status)
    }
  }
}
