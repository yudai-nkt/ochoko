import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleam/uri
import ochoko/api/auth
import ochoko/context.{type Context, Context}
import ochoko/db
import ochoko/login_lock
import ochoko/store/oauth
import ochoko/web/router
import sqlight
import support
import wisp
import wisp/simulate

const redirect = "https://elk.example/oauth/callback"

const rfc_verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

const rfc_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

fn setup() -> #(String, Context) {
  let path = support.temp_db_path()
  #(path, support.login_context(path))
}

fn body_string(res: wisp.Response) -> String {
  simulate.read_body(res)
}

fn json_field(res: wisp.Response, key: String) -> String {
  let assert Ok(v) =
    json.parse(body_string(res), decode.at([key], decode.string))
  v
}

/// Registers an app through the API; returns #(client_id, client_secret).
fn register(ctx: Context, scopes: String) -> #(String, String) {
  register_as(ctx, "Elk", redirect, scopes)
}

fn register_as(
  ctx: Context,
  name: String,
  redirect_uri: String,
  scopes: String,
) -> #(String, String) {
  let res =
    router.handle_request(
      simulate.request(http.Post, "/api/v1/apps")
        |> simulate.json_body(
          json.object([
            #("client_name", json.string(name)),
            #("redirect_uris", json.string(redirect_uri)),
            #("scopes", json.string(scopes)),
            #("website", json.string("https://elk.example")),
          ]),
        ),
      ctx,
    )
  assert res.status == 200
  #(json_field(res, "client_id"), json_field(res, "client_secret"))
}

fn authorize_form(
  ctx: Context,
  fields: List(#(String, String)),
) -> wisp.Response {
  router.handle_request(
    simulate.request(http.Post, "/oauth/authorize")
      |> simulate.form_body(fields),
    ctx,
  )
}

fn login_fields(
  client_id: String,
  password: String,
) -> List(#(String, String)) {
  [
    #("client_id", client_id),
    #("redirect_uri", redirect),
    #("response_type", "code"),
    #("scope", "read write"),
    #("state", "xyz"),
    #("password", password),
  ]
}

fn location_params(res: wisp.Response) -> List(#(String, String)) {
  let assert Ok(loc) = response.get_header(res, "location")
  let assert Ok(parsed) = uri.parse(loc)
  let assert Some(q) = parsed.query
  let assert Ok(pairs) = uri.parse_query(q)
  pairs
}

fn get_code(ctx: Context, fields: List(#(String, String))) -> String {
  let res = authorize_form(ctx, fields)
  assert res.status == 302
  let assert Ok(code) = list.key_find(location_params(res), "code")
  code
}

fn token_request(
  ctx: Context,
  fields: List(#(String, String)),
) -> wisp.Response {
  router.handle_request(
    simulate.request(http.Post, "/oauth/token") |> simulate.form_body(fields),
    ctx,
  )
}

fn exchange_fields(
  id: String,
  secret: String,
  code: String,
) -> List(#(String, String)) {
  [
    #("grant_type", "authorization_code"),
    #("client_id", id),
    #("client_secret", secret),
    #("code", code),
    #("redirect_uri", redirect),
  ]
}

fn user_token(ctx: Context) -> String {
  let #(id, secret) = register(ctx, "read write")
  let code = get_code(ctx, login_fields(id, support.test_password))
  let res = token_request(ctx, exchange_fields(id, secret, code))
  assert res.status == 200
  json_field(res, "access_token")
}

fn bearer(path: String, token: String) -> wisp.Request {
  simulate.request(http.Get, path)
  |> simulate.header("authorization", "Bearer " <> token)
}

pub fn register_app_test() {
  let #(_, ctx) = setup()
  let res =
    router.handle_request(
      simulate.request(http.Post, "/api/v1/apps")
        |> simulate.form_body([
          #("client_name", "Elk"),
          #("redirect_uris", redirect),
          #("website", "https://elk.example"),
        ]),
      ctx,
    )
  assert res.status == 200
  let assert Ok(#(name, uris, id, secret, vapid)) =
    json.parse(body_string(res), {
      use name <- decode.field("name", decode.string)
      use uris <- decode.field("redirect_uris", decode.list(decode.string))
      use id <- decode.field("client_id", decode.string)
      use secret <- decode.field("client_secret", decode.string)
      use vapid <- decode.field("vapid_key", decode.string)
      decode.success(#(name, uris, id, secret, vapid))
    })
  assert name == "Elk"
  assert uris == [redirect]
  assert json_field(res, "redirect_uri") == redirect
  assert json_field(res, "website") == "https://elk.example"
  assert vapid == ""
  // 32 random bytes in unpadded base64url is 43 characters.
  assert string.length(id) == 43
  assert string.length(secret) == 43
  assert id != secret
}

pub fn register_app_rejects_script_redirect_test() {
  let #(_, ctx) = setup()
  let res =
    router.handle_request(
      simulate.request(http.Post, "/api/v1/apps")
        |> simulate.form_body([
          #("client_name", "Evil"),
          #("redirect_uris", "javascript:alert(1)"),
        ]),
      ctx,
    )
  assert res.status == 422
}

pub fn verify_credentials_test() {
  let #(_, ctx) = setup()
  let token = user_token(ctx)
  let res =
    router.handle_request(bearer("/api/v1/apps/verify_credentials", token), ctx)
  assert res.status == 200
  assert json_field(res, "name") == "Elk"
  let res =
    router.handle_request(
      simulate.request(http.Get, "/api/v1/apps/verify_credentials"),
      ctx,
    )
  assert res.status == 401
}

pub fn authorize_unknown_client_400_test() {
  let #(_, ctx) = setup()
  let res =
    router.handle_request(
      simulate.request(
        http.Get,
        "/oauth/authorize?response_type=code&client_id=nope&redirect_uri="
          <> uri.percent_encode(redirect),
      ),
      ctx,
    )
  assert res.status == 400
  assert response.get_header(res, "location") == Error(Nil)
}

pub fn authorize_redirect_mismatch_400_test() {
  let #(_, ctx) = setup()
  let #(id, _) = register(ctx, "read")
  let res =
    router.handle_request(
      simulate.request(
        http.Get,
        "/oauth/authorize?response_type=code&scope=read&client_id="
          <> id
          <> "&redirect_uri="
          <> uri.percent_encode("https://evil.example/cb"),
      ),
      ctx,
    )
  assert res.status == 400
  assert response.get_header(res, "location") == Error(Nil)
}

pub fn authorize_rejects_plain_pkce_test() {
  let #(_, ctx) = setup()
  let #(id, _) = register(ctx, "read")
  let res =
    authorize_form(ctx, [
      #("code_challenge", rfc_challenge),
      #("code_challenge_method", "plain"),
      ..login_fields(id, support.test_password)
    ])
  assert res.status == 400
}

pub fn authorize_renders_form_test() {
  let #(_, ctx) = setup()
  let #(id, _) = register(ctx, "read write")
  let res =
    router.handle_request(
      simulate.request(
        http.Get,
        "/oauth/authorize?response_type=code&scope=read&state=%22%3E%3Cscript%3E&client_id="
          <> id
          <> "&redirect_uri="
          <> uri.percent_encode(redirect),
      ),
      ctx,
    )
  assert res.status == 200
  let body = body_string(res)
  assert string.contains(body, "type=\"password\"")
  assert string.contains(body, "name=\"client_id\" value=\"" <> id <> "\"")
  // Reflected values are escaped.
  assert string.contains(body, "&quot;&gt;&lt;script&gt;")
  assert !string.contains(body, "<script>")
  assert response.get_header(res, "x-frame-options") == Ok("DENY")
  // The post-login 302 to the client must not be blocked by form-action.
  assert response.get_header(res, "content-security-policy")
    == Ok(
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https://elk.example",
    )
  assert string.contains(body, "(redirects to elk.example)")
}

pub fn csp_form_action_custom_scheme_and_port_test() {
  let #(_, ctx) = setup()
  let #(id, _) = register_as(ctx, "N", "app.example://cb", "read")
  let csp = csp_of(ctx, id, "app.example://cb")
  assert string.ends_with(csp, "form-action 'self' app.example:")
  let #(id, _) = register_as(ctx, "P", "http://127.0.0.1:8080/cb", "read")
  let csp = csp_of(ctx, id, "http://127.0.0.1:8080/cb")
  assert string.ends_with(csp, "form-action 'self' http://127.0.0.1:8080")
}

fn csp_of(ctx: Context, id: String, redirect_uri: String) -> String {
  let res =
    router.handle_request(
      simulate.request(
        http.Get,
        "/oauth/authorize?response_type=code&scope=read&client_id="
          <> id
          <> "&redirect_uri="
          <> uri.percent_encode(redirect_uri),
      ),
      ctx,
    )
  assert res.status == 200
  let assert Ok(csp) = response.get_header(res, "content-security-policy")
  csp
}

pub fn tampered_redirect_on_post_issues_no_code_test() {
  let #(path, ctx) = setup()
  let #(id, _) = register(ctx, "read write")
  let res =
    authorize_form(ctx, [
      #("redirect_uri", "https://evil.example/cb"),
      ..list.filter(login_fields(id, support.test_password), fn(f) {
        f.0 != "redirect_uri"
      })
    ])
  assert res.status == 400
  assert response.get_header(res, "location") == Error(Nil)
  assert count_rows(path, "oauth_codes") == 0
}

fn count_rows(path: String, table: String) -> Int {
  let assert Ok([n]) =
    db.with_connection(path, fn(conn) {
      sqlight.query(
        "SELECT COUNT(*) FROM " <> table,
        on: conn,
        with: [],
        expecting: decode.at([0], decode.int),
      )
    })
  n
}

pub fn code_of_app_a_rejected_for_app_b_test() {
  let #(_, ctx) = setup()
  let #(id_a, _) = register(ctx, "read write")
  let #(id_b, secret_b) = register(ctx, "read write")
  let code = get_code(ctx, login_fields(id_a, support.test_password))
  let res = token_request(ctx, exchange_fields(id_b, secret_b, code))
  assert res.status == 400
  assert json_field(res, "error") == "invalid_grant"
}

pub fn redirect_with_existing_query_test() {
  let #(_, ctx) = setup()
  let target = "https://elk.example/cb?x=1"
  let #(id, _) = register_as(ctx, "Elk", target, "read write")
  let res =
    authorize_form(ctx, [
      #("redirect_uri", target),
      ..list.filter(login_fields(id, support.test_password), fn(f) {
        f.0 != "redirect_uri"
      })
    ])
  assert res.status == 302
  let assert Ok(loc) = response.get_header(res, "location")
  assert string.starts_with(loc, target <> "&code=")
  assert string.ends_with(loc, "&state=xyz")
}

pub fn wrong_password_rerender_escapes_test() {
  let #(_, ctx) = setup()
  let #(id, _) = register_as(ctx, "<b>\"Evil\"</b>", redirect, "read write")
  let res =
    authorize_form(ctx, [
      #("state", "\"><script>alert(1)</script>"),
      ..list.filter(login_fields(id, "wrong"), fn(f) { f.0 != "state" })
    ])
  assert res.status == 401
  let body = body_string(res)
  assert !string.contains(body, "<b>")
  assert !string.contains(body, "<script>")
  assert string.contains(body, "&lt;b&gt;&quot;Evil&quot;&lt;/b&gt;")
  assert string.contains(body, "&quot;&gt;&lt;script&gt;")
}

pub fn wrong_password_401_test() {
  let #(_, ctx) = setup()
  let #(id, _) = register(ctx, "read write")
  let res = authorize_form(ctx, login_fields(id, "wrong"))
  assert res.status == 401
  assert string.contains(body_string(res), "type=\"password\"")
  assert response.get_header(res, "location") == Error(Nil)
}

pub fn login_redirects_with_code_and_state_test() {
  let #(_, ctx) = setup()
  let #(id, _) = register(ctx, "read write")
  let res = authorize_form(ctx, login_fields(id, support.test_password))
  assert res.status == 302
  let assert Ok(loc) = response.get_header(res, "location")
  assert string.starts_with(loc, redirect <> "?")
  let params = location_params(res)
  assert list.key_find(params, "state") == Ok("xyz")
  let assert Ok(code) = list.key_find(params, "code")
  assert string.length(code) == 43
}

pub fn oob_renders_code_test() {
  let #(path, ctx) = setup()
  let res =
    router.handle_request(
      simulate.request(http.Post, "/api/v1/apps")
        |> simulate.form_body([
          #("client_name", "CLI"),
          #("redirect_uris", "urn:ietf:wg:oauth:2.0:oob"),
        ]),
      ctx,
    )
  let id = json_field(res, "client_id")
  let res =
    authorize_form(ctx, [
      #("client_id", id),
      #("redirect_uri", "urn:ietf:wg:oauth:2.0:oob"),
      #("response_type", "code"),
      #("password", support.test_password),
    ])
  assert res.status == 200
  let assert Ok(codes) =
    db.with_connection(path, fn(conn) {
      sqlight.query(
        "SELECT COUNT(*) FROM oauth_codes",
        on: conn,
        with: [],
        expecting: decode.at([0], decode.int),
      )
    })
  assert codes == [1]
}

pub fn token_exchange_test() {
  let #(_, ctx) = setup()
  let #(id, secret) = register(ctx, "read write")
  let code = get_code(ctx, login_fields(id, support.test_password))
  let res = token_request(ctx, exchange_fields(id, secret, code))
  assert res.status == 200
  assert json_field(res, "token_type") == "Bearer"
  assert json_field(res, "scope") == "read write"
  let assert Ok(created) =
    json.parse(body_string(res), decode.at(["created_at"], decode.int))
  assert created == 1_700_000_000
}

pub fn token_wrong_secret_401_test() {
  let #(_, ctx) = setup()
  let #(id, _) = register(ctx, "read write")
  let code = get_code(ctx, login_fields(id, support.test_password))
  let res = token_request(ctx, exchange_fields(id, "nope", code))
  assert res.status == 401
  assert json_field(res, "error") == "invalid_client"
}

pub fn code_is_single_use_test() {
  let #(_, ctx) = setup()
  let #(id, secret) = register(ctx, "read write")
  let code = get_code(ctx, login_fields(id, support.test_password))
  assert token_request(ctx, exchange_fields(id, secret, code)).status == 200
  let res = token_request(ctx, exchange_fields(id, secret, code))
  assert res.status == 400
  assert json_field(res, "error") == "invalid_grant"
}

pub fn expired_code_rejected_test() {
  let #(_, ctx) = setup()
  let #(id, secret) = register(ctx, "read write")
  let code = get_code(ctx, login_fields(id, support.test_password))
  let later =
    Context(..ctx, now: fn() { timestamp.add(ctx.now(), duration.seconds(601)) })
  let res = token_request(later, exchange_fields(id, secret, code))
  assert res.status == 400
  assert json_field(res, "error") == "invalid_grant"
}

pub fn redirect_uri_mismatch_at_exchange_test() {
  let #(_, ctx) = setup()
  let #(id, secret) = register(ctx, "read write")
  let code = get_code(ctx, login_fields(id, support.test_password))
  let res =
    token_request(ctx, [
      #("redirect_uri", "https://evil.example/cb"),
      ..list.filter(exchange_fields(id, secret, code), fn(f) {
        f.0 != "redirect_uri"
      })
    ])
  assert res.status == 400
}

fn pkce_login(id: String) -> List(#(String, String)) {
  [
    #("code_challenge", rfc_challenge),
    #("code_challenge_method", "S256"),
    ..login_fields(id, support.test_password)
  ]
}

pub fn pkce_s256_test() {
  let #(_, ctx) = setup()
  let #(id, secret) = register(ctx, "read write")
  let code = get_code(ctx, pkce_login(id))
  let res =
    token_request(ctx, [
      #("code_verifier", rfc_verifier),
      ..exchange_fields(id, secret, code)
    ])
  assert res.status == 200
}

pub fn pkce_wrong_verifier_rejected_test() {
  let #(_, ctx) = setup()
  let #(id, secret) = register(ctx, "read write")
  let code = get_code(ctx, pkce_login(id))
  let res =
    token_request(ctx, [
      #("code_verifier", "wrong-verifier-wrong-verifier-wrong-verifier"),
      ..exchange_fields(id, secret, code)
    ])
  assert res.status == 400
  assert json_field(res, "error") == "invalid_grant"
}

pub fn pkce_missing_verifier_rejected_test() {
  let #(_, ctx) = setup()
  let #(id, secret) = register(ctx, "read write")
  let code = get_code(ctx, pkce_login(id))
  let res = token_request(ctx, exchange_fields(id, secret, code))
  assert res.status == 400
}

pub fn client_credentials_app_token_test() {
  let #(_, ctx) = setup()
  let #(id, secret) = register(ctx, "read")
  let res =
    token_request(ctx, [
      #("grant_type", "client_credentials"),
      #("client_id", id),
      #("client_secret", secret),
    ])
  assert res.status == 200
  assert json_field(res, "scope") == "read"
  let token = json_field(res, "access_token")
  // An app token is accepted where any token is.
  let res =
    router.handle_request(bearer("/api/v1/apps/verify_credentials", token), ctx)
  assert res.status == 200
}

pub fn require_user_rejects_app_token_test() {
  let #(_, ctx) = setup()
  let #(id, secret) = register(ctx, "read")
  let res =
    token_request(ctx, [
      #("grant_type", "client_credentials"),
      #("client_id", id),
      #("client_secret", secret),
    ])
  let token = json_field(res, "access_token")
  assert require_user_status(ctx, Some(token)) == 401
  let user = user_token(ctx)
  assert require_user_status(ctx, Some(user)) == 200
}

pub fn require_user_rejects_missing_token_test() {
  let #(_, ctx) = setup()
  assert require_user_status(ctx, None) == 401
  assert require_user_status(ctx, Some("garbage")) == 401
}

fn require_user_status(ctx: Context, token: option.Option(String)) -> Int {
  let req = simulate.request(http.Get, "/")
  let req = case token {
    Some(t) -> simulate.header(req, "authorization", "Bearer " <> t)
    None -> req
  }
  let res = {
    use <- auth.require_user(ctx, req)
    wisp.ok()
  }
  case res.status == 401 {
    True -> {
      assert body_string(res) == "{\"error\":\"The access token is invalid\"}"
      Nil
    }
    False -> Nil
  }
  res.status
}

pub fn revoke_invalidates_token_test() {
  let #(_, ctx) = setup()
  let #(id, secret) = register(ctx, "read write")
  let code = get_code(ctx, login_fields(id, support.test_password))
  let token =
    json_field(
      token_request(ctx, exchange_fields(id, secret, code)),
      "access_token",
    )
  assert require_user_status(ctx, Some(token)) == 200
  let res =
    router.handle_request(
      simulate.request(http.Post, "/oauth/revoke")
        |> simulate.form_body([
          #("client_id", id),
          #("client_secret", secret),
          #("token", token),
        ]),
      ctx,
    )
  assert res.status == 200
  assert body_string(res) == "{}"
  assert require_user_status(ctx, Some(token)) == 401
}

pub fn tokens_stored_hashed_test() {
  let #(path, ctx) = setup()
  let #(id, secret) = register(ctx, "read write")
  let code = get_code(ctx, login_fields(id, support.test_password))
  let column = fn(sql) {
    db.with_connection(path, fn(conn) {
      let assert Ok(rows) =
        sqlight.query(
          sql,
          on: conn,
          with: [],
          expecting: decode.at([0], decode.string),
        )
      rows
    })
  }
  // Before the exchange the code is stored as its hash only.
  assert column("SELECT code_hash FROM oauth_codes")
    == [oauth.hash_secret(code)]
  let token =
    json_field(
      token_request(ctx, exchange_fields(id, secret, code)),
      "access_token",
    )
  assert column("SELECT token_hash FROM oauth_tokens")
    == [oauth.hash_secret(token)]
  assert oauth.hash_secret(token) != token
  assert oauth.hash_secret(code) != code
  // Raw strings appear nowhere in the tables.
  let like = fn(table, col, raw) {
    column(
      "SELECT "
      <> col
      <> " FROM "
      <> table
      <> " WHERE "
      <> col
      <> " = '"
      <> raw
      <> "'",
    )
  }
  assert like("oauth_tokens", "token_hash", token) == []
  assert like("oauth_codes", "code_hash", code) == []
  assert column("SELECT code_hash FROM oauth_codes") == []
}

// --- login concurrency ---------------------------------------------------------

/// Starts a process that takes the login lock and holds it until the
/// returned subject is sent `Nil`; `on_release` runs before letting go.
fn hold_login_lock(on_release: fn() -> Nil) -> process.Subject(Nil) {
  let started = process.new_subject()
  process.spawn(fn() {
    login_lock.run(0, fn() {
      let release = process.new_subject()
      process.send(started, release)
      let _ = process.receive(release, 10_000)
      on_release()
    })
  })
  let assert Ok(release) = process.receive(started, 5000)
  release
}

pub fn concurrent_login_is_turned_away_test() {
  let #(_, ctx) = setup()
  let #(client_id, _) = register(ctx, "read write")
  let release = hold_login_lock(fn() { Nil })
  let res = authorize_form(ctx, login_fields(client_id, support.test_password))
  assert res.status == 503
  assert response.get_header(res, "retry-after") == Ok("1")
  process.send(release, Nil)
  // Once the lock is free the next attempt verifies normally.
  let res = authorize_form(ctx, login_fields(client_id, support.test_password))
  assert res.status == 302
}

pub fn login_lock_serializes_test() {
  // A second holder runs only after the first has finished.
  let log = process.new_subject()
  let release = hold_login_lock(fn() { process.send(log, "first done") })
  process.spawn(fn() {
    let _ = login_lock.run(5000, fn() { process.send(log, "second ran") })
    Nil
  })
  process.send(release, Nil)
  assert process.receive(log, 5000) == Ok("first done")
  assert process.receive(log, 5000) == Ok("second ran")
}
