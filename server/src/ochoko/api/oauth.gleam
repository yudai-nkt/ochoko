//// OAuth 2 endpoints: the authorize/login page, token and revoke.

import argus
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleam/uri
import ochoko/api/apps.{oob}
import ochoko/api/params.{type Params}
import ochoko/context.{type Context}
import ochoko/db
import ochoko/store/oauth.{type App}
import wisp.{type Request, type Response}

const code_lifetime_seconds = 600

/// A validated authorization request.
type Authz {
  Authz(
    app: App,
    redirect_uri: String,
    scope: String,
    state: String,
    code_challenge: Option(String),
  )
}

pub fn authorize(req: Request, ctx: Context) -> Response {
  case req.method {
    Get -> {
      use p <- params.read(req)
      use authz <- validate_authz(ctx, p)
      login_page(authz, None, 200)
    }
    Post -> {
      use p <- params.read(req)
      use authz <- validate_authz(ctx, p)
      login(ctx, authz, params.get(p, "password"))
    }
    _ -> wisp.method_not_allowed([Get, Post])
  }
}

fn login(ctx: Context, authz: Authz, password: String) -> Response {
  let ok = case argus.verify(ctx.config.password_hash, password) {
    Ok(True) -> True
    Ok(False) | Error(_) -> False
  }
  case ok {
    False -> {
      process.sleep(ctx.login_failure_delay_ms)
      login_page(authz, Some("Incorrect password."), 401)
    }
    True -> {
      let code = oauth.random_secret()
      let stored =
        db.with_connection(ctx.db_path, oauth.insert_code(
          _,
          code,
          authz.app.id,
          authz.redirect_uri,
          authz.scope,
          authz.code_challenge,
          timestamp.add(ctx.now(), duration.seconds(code_lifetime_seconds)),
        ))
      case stored {
        Error(_) -> wisp.internal_server_error()
        Ok(Nil) ->
          case authz.redirect_uri == oob {
            True -> oob_page(code)
            False -> redirect_with_code(authz, code)
          }
      }
    }
  }
}

fn redirect_with_code(authz: Authz, code: String) -> Response {
  let extra = [
    #("code", code),
    ..case authz.state {
      "" -> []
      s -> [#("state", s)]
    }
  ]
  case uri.parse(authz.redirect_uri) {
    Error(Nil) -> wisp.bad_request("invalid redirect_uri")
    Ok(parsed) -> {
      let query = case parsed.query {
        Some(q) -> q <> "&" <> uri.query_to_string(extra)
        None -> uri.query_to_string(extra)
      }
      wisp.response(302)
      |> response.set_header(
        "location",
        uri.to_string(uri.Uri(..parsed, query: Some(query))),
      )
      |> response.set_header("cache-control", "no-store")
    }
  }
}

/// Check client, redirect URI, scope and PKCE parameters. Problems are shown
/// to the user as an error page; we never redirect to an unvalidated URI.
fn validate_authz(
  ctx: Context,
  p: Params,
  next: fn(Authz) -> Response,
) -> Response {
  let client_id = params.get(p, "client_id")
  case
    db.with_connection(ctx.db_path, oauth.get_app_by_client_id(_, client_id))
  {
    Error(_) -> wisp.internal_server_error()
    Ok(None) -> error_page("Unknown application.")
    Ok(Some(app)) -> {
      let redirect_uri = case params.get(p, "redirect_uri") {
        "" -> result.unwrap(list.first(app.redirect_uris), "")
        u -> u
      }
      let scope = case string.trim(params.get(p, "scope")) {
        "" -> app.scopes
        s -> s
      }
      let challenge = params.get(p, "code_challenge")
      let method = params.get(p, "code_challenge_method")
      let checks = [
        #(
          list.contains(app.redirect_uris, redirect_uri),
          "The redirect URI does not match the application.",
        ),
        #(
          params.get(p, "response_type") == "code",
          "Unsupported response_type.",
        ),
        #(
          scopes_subset(scope, app.scopes),
          "The requested scope is not allowed for this application.",
        ),
        #(
          challenge == "" || method == "S256",
          "Only the S256 code challenge method is supported.",
        ),
        #(
          challenge == "" || valid_challenge(challenge),
          "Invalid code challenge.",
        ),
      ]
      case list.find(checks, fn(check) { !check.0 }) {
        Ok(#(_, message)) -> error_page(message)
        Error(Nil) ->
          next(
            Authz(
              app:,
              redirect_uri:,
              scope:,
              state: params.get(p, "state"),
              code_challenge: case challenge {
                "" -> None
                c -> Some(c)
              },
            ),
          )
      }
    }
  }
}

fn scopes_subset(requested: String, allowed: String) -> Bool {
  let allowed = split_scopes(allowed)
  split_scopes(requested) |> list.all(list.contains(allowed, _))
}

fn split_scopes(s: String) -> List(String) {
  string.split(s, " ") |> list.filter(fn(x) { x != "" })
}

/// RFC 7636: 43 to 128 characters from the base64url alphabet.
fn valid_challenge(c: String) -> Bool {
  let n = string.length(c)
  n >= 43
  && n <= 128
  && string.to_graphemes(c)
  |> list.all(fn(g) {
    string.contains(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
      g,
    )
  })
}

// ---------------------------------------------------------------- pages

fn escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}

fn html_page(status: Int, title: String, body: String) -> Response {
  let html =
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
    <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    <> "<title>"
    <> escape(title)
    <> "</title><style>body{font-family:system-ui,sans-serif;max-width:24rem;margin:3rem auto;padding:0 1rem}"
    <> "input{width:100%;box-sizing:border-box;padding:.5rem;margin:.5rem 0}"
    <> "button{padding:.5rem 1rem}.error{color:#b00020}code{word-break:break-all}</style>"
    <> "</head><body>"
    <> body
    <> "</body></html>"
  wisp.response(status)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
  )
  |> response.set_header("x-frame-options", "DENY")
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("referrer-policy", "no-referrer")
  |> wisp.string_body(html)
}

fn error_page(message: String) -> Response {
  html_page(
    400,
    "Authorization error",
    "<h1>Authorization error</h1><p>" <> escape(message) <> "</p>",
  )
}

fn oob_page(code: String) -> Response {
  html_page(
    200,
    "Authorization code",
    "<h1>Authorization code</h1><p>Copy this code into the application:</p><p><code>"
      <> escape(code)
      <> "</code></p>",
  )
}

fn hidden(name: String, value: String) -> String {
  "<input type=\"hidden\" name=\""
  <> escape(name)
  <> "\" value=\""
  <> escape(value)
  <> "\">"
}

fn login_page(authz: Authz, error: Option(String), status: Int) -> Response {
  let fields =
    [
      hidden("client_id", authz.app.client_id),
      hidden("redirect_uri", authz.redirect_uri),
      hidden("response_type", "code"),
      hidden("scope", authz.scope),
      hidden("state", authz.state),
    ]
    |> list.append(case authz.code_challenge {
      Some(c) -> [
        hidden("code_challenge", c),
        hidden("code_challenge_method", "S256"),
      ]
      None -> []
    })
    |> string.join("")
  let error_html = case error {
    Some(e) -> "<p class=\"error\" role=\"alert\">" <> escape(e) <> "</p>"
    None -> ""
  }
  html_page(
    status,
    "Sign in",
    "<h1>Sign in</h1><p><strong>"
      <> escape(authz.app.name)
      <> "</strong> wants access to your account"
      <> " (scope: "
      <> escape(authz.scope)
      <> ").</p>"
      <> error_html
      <> "<form method=\"post\" action=\"/oauth/authorize\">"
      <> fields
      <> "<label>Password<input type=\"password\" name=\"password\""
      <> " autocomplete=\"current-password\" autofocus required></label>"
      <> "<button type=\"submit\">Authorize</button></form>",
  )
}

// ---------------------------------------------------------------- token

pub fn token(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use p <- params.read(req)
  use app <- authenticate_client(ctx, req, p)
  case params.get(p, "grant_type") {
    "authorization_code" -> exchange_code(ctx, app, p)
    "client_credentials" -> client_credentials(ctx, app, p)
    _ ->
      oauth_error(
        400,
        "unsupported_grant_type",
        "The grant type is not supported.",
      )
  }
}

fn exchange_code(ctx: Context, app: App, p: Params) -> Response {
  let invalid = fn(msg) { oauth_error(400, "invalid_grant", msg) }
  let now = ctx.now()
  let taken =
    db.with_connection(ctx.db_path, oauth.take_code(
      _,
      params.get(p, "code"),
      now,
    ))
  case taken {
    Error(_) -> wisp.internal_server_error()
    Ok(None) -> invalid("The authorization code is invalid or expired.")
    Ok(Some(code)) ->
      case
        code.app_id == app.id,
        code.redirect_uri == params.get(p, "redirect_uri")
      {
        False, _ ->
          invalid("The authorization code was issued to another client.")
        _, False -> invalid("The redirect URI does not match.")
        True, True ->
          case pkce_ok(code.code_challenge, params.get(p, "code_verifier")) {
            False -> invalid("The code verifier does not match the challenge.")
            True -> issue_token(ctx, app, oauth.UserKind, code.scopes)
          }
      }
  }
}

fn pkce_ok(challenge: Option(String), verifier: String) -> Bool {
  case challenge {
    None -> True
    Some(challenge) ->
      verifier != ""
      && crypto.secure_compare(
        bit_array.from_string(
          crypto.hash(crypto.Sha256, bit_array.from_string(verifier))
          |> bit_array.base64_url_encode(False),
        ),
        bit_array.from_string(challenge),
      )
  }
}

fn client_credentials(ctx: Context, app: App, p: Params) -> Response {
  let scope = case string.trim(params.get(p, "scope")) {
    "" -> "read"
    s -> s
  }
  case scopes_subset(scope, app.scopes) {
    False ->
      oauth_error(
        400,
        "invalid_scope",
        "The requested scope is not allowed for this application.",
      )
    True -> issue_token(ctx, app, oauth.AppKind, scope)
  }
}

fn issue_token(
  ctx: Context,
  app: App,
  kind: oauth.TokenKind,
  scope: String,
) -> Response {
  let now = ctx.now()
  case
    db.with_connection(ctx.db_path, oauth.create_token(
      _,
      app.id,
      kind,
      scope,
      now,
    ))
  {
    Error(_) -> wisp.internal_server_error()
    Ok(token) -> {
      let #(created_at, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
      json.object([
        #("access_token", json.string(token)),
        #("token_type", json.string("Bearer")),
        #("scope", json.string(scope)),
        #("created_at", json.int(created_at)),
      ])
      |> json.to_string
      |> wisp.json_response(200)
      |> no_store
    }
  }
}

pub fn revoke(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use p <- params.read(req)
  use app <- authenticate_client(ctx, req, p)
  let _ =
    db.with_connection(ctx.db_path, oauth.revoke_token(
      _,
      params.get(p, "token"),
      app.id,
    ))
  wisp.json_response("{}", 200)
}

/// Client credentials from HTTP Basic or the parameters. The secret is
/// compared in constant time.
fn authenticate_client(
  ctx: Context,
  req: Request,
  p: Params,
  next: fn(App) -> Response,
) -> Response {
  let #(client_id, secret) = case basic_credentials(req) {
    Ok(creds) -> creds
    Error(Nil) -> #(params.get(p, "client_id"), params.get(p, "client_secret"))
  }
  let found =
    db.with_connection(ctx.db_path, oauth.get_app_by_client_id(_, client_id))
  case found {
    Ok(Some(app)) ->
      case
        crypto.secure_compare(
          bit_array.from_string(app.client_secret),
          bit_array.from_string(secret),
        )
      {
        True -> next(app)
        False -> invalid_client()
      }
    Ok(None) -> invalid_client()
    Error(_) -> wisp.internal_server_error()
  }
}

fn basic_credentials(req: Request) -> Result(#(String, String), Nil) {
  use header <- result.try(request.get_header(req, "authorization"))
  use #(scheme, encoded) <- result.try(string.split_once(
    string.trim(header),
    " ",
  ))
  use <- bool_guard(string.lowercase(scheme) == "basic")
  use decoded <- result.try(bit_array.base64_decode(string.trim(encoded)))
  use text <- result.try(bit_array.to_string(decoded))
  string.split_once(text, ":")
}

fn bool_guard(ok: Bool, next: fn() -> Result(a, Nil)) -> Result(a, Nil) {
  case ok {
    True -> next()
    False -> Error(Nil)
  }
}

fn invalid_client() -> Response {
  oauth_error(401, "invalid_client", "Client authentication failed.")
}

fn oauth_error(status: Int, error: String, description: String) -> Response {
  json.object([
    #("error", json.string(error)),
    #("error_description", json.string(description)),
  ])
  |> json.to_string
  |> wisp.json_response(status)
  |> no_store
}

fn no_store(res: Response) -> Response {
  res
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("pragma", "no-cache")
}
