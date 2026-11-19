//// OAuth apps, authorization codes and access tokens. Codes and tokens are
//// stored only as SHA-256 hashes.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import sqlight

pub type App {
  App(
    id: Int,
    client_id: String,
    client_secret: String,
    name: String,
    website: Option(String),
    redirect_uris: List(String),
    scopes: String,
  )
}

pub type Code {
  Code(
    app_id: Int,
    redirect_uri: String,
    scopes: String,
    code_challenge: Option(String),
    expires_at: Int,
  )
}

pub type TokenKind {
  UserKind
  AppKind
}

pub type TokenInfo {
  TokenInfo(app_id: Int, kind: TokenKind, scopes: String)
}

/// A fresh secret: 32 random bytes, base64url without padding.
pub fn random_secret() -> String {
  crypto.strong_random_bytes(32) |> bit_array.base64_url_encode(False)
}

/// Lowercase hex SHA-256 of a secret, as stored in the database.
pub fn hash_secret(secret: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(secret))
  |> bit_array.base16_encode
  |> string.lowercase
}

fn unix(now: Timestamp) -> Int {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  seconds
}

fn app_decoder() -> decode.Decoder(App) {
  use id <- decode.field(0, decode.int)
  use client_id <- decode.field(1, decode.string)
  use client_secret <- decode.field(2, decode.string)
  use name <- decode.field(3, decode.string)
  use website <- decode.field(4, decode.optional(decode.string))
  use uris <- decode.field(5, decode.string)
  use scopes <- decode.field(6, decode.string)
  decode.success(App(
    id:,
    client_id:,
    client_secret:,
    name:,
    website:,
    redirect_uris: string.split(uris, "\n"),
    scopes:,
  ))
}

const app_columns =
  "id, client_id, client_secret, name, website, redirect_uris, scopes"

pub fn create_app(
  conn: sqlight.Connection,
  name: String,
  website: Option(String),
  redirect_uris: List(String),
  scopes: String,
  now: Timestamp,
) -> Result(App, sqlight.Error) {
  let client_id = random_secret()
  let client_secret = random_secret()
  use rows <- result.try(sqlight.query(
    "INSERT INTO oauth_apps (client_id, client_secret, name, website, redirect_uris, scopes, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING "
      <> app_columns,
    on: conn,
    with: [
      sqlight.text(client_id),
      sqlight.text(client_secret),
      sqlight.text(name),
      sqlight.nullable(sqlight.text, website),
      sqlight.text(string.join(redirect_uris, "\n")),
      sqlight.text(scopes),
      sqlight.int(unix(now)),
    ],
    expecting: app_decoder(),
  ))
  let assert [app] = rows
  Ok(app)
}

pub fn get_app_by_client_id(
  conn: sqlight.Connection,
  client_id: String,
) -> Result(Option(App), sqlight.Error) {
  sqlight.query(
    "SELECT " <> app_columns <> " FROM oauth_apps WHERE client_id = ?",
    on: conn,
    with: [sqlight.text(client_id)],
    expecting: app_decoder(),
  )
  |> result.map(list.first)
  |> result.map(option.from_result)
}

pub fn get_app(
  conn: sqlight.Connection,
  id: Int,
) -> Result(Option(App), sqlight.Error) {
  sqlight.query(
    "SELECT " <> app_columns <> " FROM oauth_apps WHERE id = ?",
    on: conn,
    with: [sqlight.int(id)],
    expecting: app_decoder(),
  )
  |> result.map(list.first)
  |> result.map(option.from_result)
}

/// Store an authorization code (by hash) that expires at `expires_at`.
pub fn insert_code(
  conn: sqlight.Connection,
  code: String,
  app_id: Int,
  redirect_uri: String,
  scopes: String,
  code_challenge: Option(String),
  expires_at: Timestamp,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "INSERT INTO oauth_codes (code_hash, app_id, redirect_uri, scopes, code_challenge, expires_at)
     VALUES (?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(hash_secret(code)),
      sqlight.int(app_id),
      sqlight.text(redirect_uri),
      sqlight.text(scopes),
      sqlight.nullable(sqlight.text, code_challenge),
      sqlight.int(unix(expires_at)),
    ],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}

/// Atomically consume a code: it can be taken once, whatever happens next.
/// Expired codes are consumed but reported as absent.
pub fn take_code(
  conn: sqlight.Connection,
  code: String,
  now: Timestamp,
) -> Result(Option(Code), sqlight.Error) {
  use rows <- result.map(
    sqlight.query(
      "DELETE FROM oauth_codes WHERE code_hash = ?
     RETURNING app_id, redirect_uri, scopes, code_challenge, expires_at",
      on: conn,
      with: [sqlight.text(hash_secret(code))],
      expecting: {
        use app_id <- decode.field(0, decode.int)
        use redirect_uri <- decode.field(1, decode.string)
        use scopes <- decode.field(2, decode.string)
        use code_challenge <- decode.field(3, decode.optional(decode.string))
        use expires_at <- decode.field(4, decode.int)
        decode.success(Code(
          app_id:,
          redirect_uri:,
          scopes:,
          code_challenge:,
          expires_at:,
        ))
      },
    ),
  )
  let now_s = unix(now)
  case rows {
    [c, ..] if c.expires_at > now_s -> Some(c)
    _ -> None
  }
}

/// Create a token and return the raw secret (only its hash is stored).
pub fn create_token(
  conn: sqlight.Connection,
  app_id: Int,
  kind: TokenKind,
  scopes: String,
  now: Timestamp,
) -> Result(String, sqlight.Error) {
  let token = random_secret()
  sqlight.query(
    "INSERT INTO oauth_tokens (token_hash, app_id, kind, scopes, created_at)
     VALUES (?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(hash_secret(token)),
      sqlight.int(app_id),
      sqlight.text(case kind {
        UserKind -> "user"
        AppKind -> "app"
      }),
      sqlight.text(scopes),
      sqlight.int(unix(now)),
    ],
    expecting: decode.success(Nil),
  )
  |> result.replace(token)
}

pub fn find_token(
  conn: sqlight.Connection,
  token: String,
) -> Result(Option(TokenInfo), sqlight.Error) {
  sqlight.query(
    "SELECT app_id, kind, scopes FROM oauth_tokens WHERE token_hash = ?",
    on: conn,
    with: [sqlight.text(hash_secret(token))],
    expecting: {
      use app_id <- decode.field(0, decode.int)
      use kind <- decode.field(1, decode.string)
      use scopes <- decode.field(2, decode.string)
      decode.success(TokenInfo(
        app_id:,
        kind: case kind {
          "user" -> UserKind
          _ -> AppKind
        },
        scopes:,
      ))
    },
  )
  |> result.map(list.first)
  |> result.map(option.from_result)
}

/// Delete a token, but only if it belongs to `app_id`.
pub fn revoke_token(
  conn: sqlight.Connection,
  token: String,
  app_id: Int,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "DELETE FROM oauth_tokens WHERE token_hash = ? AND app_id = ?",
    on: conn,
    with: [sqlight.text(hash_secret(token)), sqlight.int(app_id)],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}
