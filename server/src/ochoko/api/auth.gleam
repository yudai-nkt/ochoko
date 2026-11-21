//// Bearer-token authentication for the Mastodon API.

import gleam/http/request
import gleam/option.{None, Some}
import gleam/string
import ochoko/api/respond
import ochoko/context.{type Context}
import ochoko/db
import ochoko/store/oauth
import wisp.{type Request, type Response}

pub type Auth {
  UserToken
  AppToken
}

/// Require a token issued through the login flow (not a `client_credentials`
/// app token).
pub fn require_user(
  ctx: Context,
  req: Request,
  next: fn() -> Response,
) -> Response {
  use auth, _ <- require_any(ctx, req)
  case auth {
    UserToken -> next()
    AppToken -> invalid_token()
  }
}

/// Require any valid token; the callback gets its kind and owning app id.
pub fn require_any(
  ctx: Context,
  req: Request,
  next: fn(Auth, Int) -> Response,
) -> Response {
  case authenticate(ctx, req) {
    Ok(#(auth, app_id)) -> next(auth, app_id)
    Error(Nil) -> invalid_token()
  }
}

/// The auth kind and owning app id of the request's bearer token.
fn authenticate(ctx: Context, req: Request) -> Result(#(Auth, Int), Nil) {
  case bearer_token(req) {
    Error(Nil) -> Error(Nil)
    Ok(token) ->
      case db.with_connection(ctx.db_path, oauth.find_token(_, token)) {
        Ok(Some(info)) ->
          Ok(#(
            case info.kind {
              oauth.UserKind -> UserToken
              oauth.AppKind -> AppToken
            },
            info.app_id,
          ))
        Ok(None) | Error(_) -> Error(Nil)
      }
  }
}

fn bearer_token(req: Request) -> Result(String, Nil) {
  case request.get_header(req, "authorization") {
    Error(Nil) -> Error(Nil)
    Ok(value) ->
      case string.split_once(string.trim(value), " ") {
        Ok(#(scheme, token)) ->
          case string.lowercase(scheme), string.trim(token) {
            "bearer", "" -> Error(Nil)
            "bearer", token -> Ok(token)
            _, _ -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
  }
}

fn invalid_token() -> Response {
  respond.error("The access token is invalid", 401)
}
