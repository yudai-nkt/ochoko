import gleam/int
import gleam/result
import gleam/string
import simplifile
import tom

pub type Config {
  Config(
    account_domain: String,
    host: String,
    handle: String,
    listen_port: Int,
    database_path: String,
    private_key_path: String,
    password_hash: String,
    secret_key_base: String,
  )
}

pub fn parse(toml: String) -> Result(Config, String) {
  use doc <- result.try(
    tom.parse(toml)
    |> result.map_error(fn(e) { "invalid TOML: " <> describe_parse_error(e) }),
  )
  use account_domain <- result.try(get_string(doc, "account_domain"))
  use host <- result.try(get_string(doc, "host"))
  use handle <- result.try(get_string(doc, "handle"))
  use listen_port <- result.try(get_int(doc, "listen_port"))
  use database_path <- result.try(get_string(doc, "database_path"))
  use private_key_path <- result.try(get_string(doc, "private_key_path"))
  use password_hash <- result.try(get_string(doc, "password_hash"))
  use secret_key_base <- result.try(get_string(doc, "secret_key_base"))
  Ok(Config(
    account_domain:,
    host:,
    handle:,
    listen_port:,
    database_path:,
    private_key_path:,
    password_hash:,
    secret_key_base:,
  ))
}

pub fn load(path: String) -> Result(Config, String) {
  use contents <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) {
      "cannot read " <> path <> ": " <> simplifile.describe_error(e)
    }),
  )
  parse(contents)
}

// --- permanent URLs ------------------------------------------------------------
//
// Every URL we publish is built here. They are permanent: remote servers
// store them, so changing one breaks federation.

/// `https://{host}`, without a trailing slash.
pub fn base_url(c: Config) -> String {
  "https://" <> c.host
}

/// Our actor id.
pub fn actor_id(c: Config) -> String {
  base_url(c) <> "/me"
}

/// The id of our actor's (only) public key.
pub fn key_id(c: Config) -> String {
  actor_id(c) <> "#main-key"
}

pub fn inbox_uri(c: Config) -> String {
  actor_id(c) <> "/inbox"
}

pub fn shared_inbox_uri(c: Config) -> String {
  base_url(c) <> "/inbox"
}

pub fn outbox_uri(c: Config) -> String {
  actor_id(c) <> "/outbox"
}

/// Our followers collection.
pub fn followers_uri(c: Config) -> String {
  actor_id(c) <> "/followers"
}

pub fn following_uri(c: Config) -> String {
  actor_id(c) <> "/following"
}

/// The human-facing profile page (where browsers are sent).
pub fn profile_url(c: Config) -> String {
  base_url(c) <> "/profile"
}

/// The id of an activity we send; `id` is a generated id.
pub fn activity_uri(c: Config, id: Int) -> String {
  base_url(c) <> "/activities/" <> int.to_string(id)
}

/// The URI (and public URL) of our status `id`.
pub fn status_uri(c: Config, id: Int) -> String {
  base_url(c) <> "/statuses/" <> int.to_string(id)
}

/// A file under `priv/static`, e.g. `static_url(c, "avatar.png")`.
pub fn static_url(c: Config, file: String) -> String {
  base_url(c) <> "/static/" <> file
}

/// An absolute URL of ours for `path` (which starts with `/`), e.g. API
/// pagination links.
pub fn url(c: Config, path: String) -> String {
  base_url(c) <> path
}

pub fn acct(c: Config) -> String {
  c.handle <> "@" <> c.account_domain
}

fn get_string(doc, key: String) -> Result(String, String) {
  tom.get_string(doc, [key])
  |> result.map_error(fn(e) { describe_get_error(key, e) })
}

fn get_int(doc, key: String) -> Result(Int, String) {
  tom.get_int(doc, [key])
  |> result.map_error(fn(e) { describe_get_error(key, e) })
}

fn describe_get_error(key: String, e: tom.GetError) -> String {
  case e {
    tom.NotFound(_) -> "missing config key: " <> key
    tom.WrongType(_, expected, got) ->
      "config key " <> key <> " must be " <> expected <> ", got " <> got
  }
}

fn describe_parse_error(e: tom.ParseError) -> String {
  case e {
    tom.Unexpected(got, expected) ->
      "unexpected " <> got <> ", expected " <> expected
    tom.KeyAlreadyInUse(key) -> "duplicate key " <> string.join(key, ".")
  }
}
