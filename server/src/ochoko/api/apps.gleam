//// `POST /api/v1/apps` and `GET /api/v1/apps/verify_credentials`.

import gleam/http.{Get, Post}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import ochoko/api/auth
import ochoko/api/params
import ochoko/context.{type Context}
import ochoko/db
import ochoko/store/oauth
import wisp.{type Request, type Response}

pub const oob = "urn:ietf:wg:oauth:2.0:oob"

pub fn create(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use p <- params.read(req)
  let name = string.trim(params.get(p, "client_name"))
  let uris = params.get_list(p, "redirect_uris")
  let scopes = case string.trim(params.get(p, "scopes")) {
    "" -> "read"
    s -> s
  }
  let website = case string.trim(params.get(p, "website")) {
    "" -> None
    w -> Some(w)
  }
  case name, uris {
    "", _ -> unprocessable("client_name is required")
    _, [] -> unprocessable("redirect_uris is required")
    _, _ ->
      case list.all(uris, valid_redirect_uri) {
        False -> unprocessable("redirect_uris contains an invalid URI")
        True -> {
          let created =
            db.with_connection(ctx.db_path, oauth.create_app(
              _,
              name,
              website,
              uris,
              scopes,
              ctx.now(),
            ))
          case created {
            Error(_) -> wisp.internal_server_error()
            Ok(app) ->
              json.object([
                #("id", json.string(int.to_string(app.id))),
                #("name", json.string(app.name)),
                #("website", json.nullable(app.website, json.string)),
                #("redirect_uri", json.string(string.join(uris, "\n"))),
                #("redirect_uris", json.array(uris, json.string)),
                #("client_id", json.string(app.client_id)),
                #("client_secret", json.string(app.client_secret)),
                #("vapid_key", json.string("")),
              ])
              |> json.to_string
              |> wisp.json_response(200)
          }
        }
      }
  }
}

pub fn verify_credentials(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  use _ <- auth.require_any(ctx, req)
  let assert Ok(#(_, app_id)) = auth.authenticate(ctx, req)
  case db.with_connection(ctx.db_path, oauth.get_app(_, app_id)) {
    Ok(Some(app)) ->
      json.object([
        #("name", json.string(app.name)),
        #("website", json.nullable(app.website, json.string)),
      ])
      |> json.to_string
      |> wisp.json_response(200)
    _ -> wisp.internal_server_error()
  }
}

/// Out-of-band, or an absolute URI with a scheme that cannot run script and
/// no whitespace or control characters (URIs are stored newline-separated).
fn valid_redirect_uri(u: String) -> Bool {
  let clean =
    string.to_utf_codepoints(u)
    |> list.all(fn(cp) {
      let n = string.utf_codepoint_to_int(cp)
      n > 0x20 && n != 0x7F
    })
  case clean, u == oob {
    _, True -> True
    False, _ -> False
    True, False ->
      case uri.parse(u) {
        Ok(parsed) ->
          case parsed.scheme {
            Some(scheme) ->
              !list.contains(
                ["javascript", "data", "vbscript", "file", "blob"],
                string.lowercase(scheme),
              )
            None -> False
          }
        Error(Nil) -> False
      }
  }
}

fn unprocessable(msg: String) -> Response {
  json.object([#("error", json.string(msg))])
  |> json.to_string
  |> wisp.json_response(422)
}
