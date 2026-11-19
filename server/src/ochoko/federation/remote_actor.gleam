//// Remote actors: decoding, fetching and the 24 hour cache.

import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri
import ochoko/context.{type Context}
import ochoko/db
import ochoko/federation/ap_decode
import ochoko/federation/remote_actor_types as types
import ochoko/http_client
import ochoko/store/remote_actors
import sqlight

pub type RemoteActor =
  types.RemoteActor

/// How long a stored actor is served without refetching, in seconds.
const cache_ttl_seconds = 86_400

// --- decoding ----------------------------------------------------------------

/// Decodes an actor document. `id` is 0 until the actor is stored.
pub fn decode(body: String) -> Result(RemoteActor, String) {
  decode_for_key(body, None)
}

/// Like `decode`, but when `publicKey` is an array picks the key whose `id`
/// is `key_id` (the first key if none matches or `key_id` is unknown).
pub fn decode_for_key(
  body: String,
  key_id: Option(String),
) -> Result(RemoteActor, String) {
  json.parse(body, actor_decoder(key_id))
  |> result.map_error(describe_json_error)
}

fn describe_json_error(e: json.DecodeError) -> String {
  case e {
    json.UnexpectedEndOfInput -> "invalid actor: unexpected end of input"
    json.UnexpectedByte(b) -> "invalid actor: unexpected byte " <> b
    json.UnexpectedSequence(s) -> "invalid actor: unexpected sequence " <> s
    json.UnableToDecode(errors) ->
      "invalid actor: "
      <> {
        errors
        |> list.map(fn(e) {
          "expected "
          <> e.expected
          <> " but found "
          <> e.found
          <> " at "
          <> string.join(e.path, ".")
        })
        |> string.join("; ")
      }
  }
}

fn lenient(decoder: Decoder(a), default: a) -> Decoder(a) {
  decode.one_of(decoder, [decode.success(default)])
}

fn first_iri(field: String) -> Decoder(Option(String)) {
  decode.optionally_at([field], [], ap_decode.iri_list())
  |> decode.map(fn(xs) { list.first(xs) |> option.from_result })
}

fn actor_decoder(wanted_key: Option(String)) -> Decoder(RemoteActor) {
  use uri <- decode.field("id", ap_decode.iri())
  use types <- decode.then(decode.optionally_at(
    ["type"],
    [],
    ap_decode.type_names() |> lenient([]),
  ))
  use preferred <- decode.then(decode.optionally_at(
    ["preferredUsername"],
    "",
    decode.string |> lenient(""),
  ))
  use name <- decode.then(ap_decode.localized("name"))
  use summary <- decode.then(ap_decode.localized("summary"))
  use avatar_url <- decode.then(decode.optionally_at(
    ["icon"],
    None,
    ap_decode.image_url(),
  ))
  use header_url <- decode.then(decode.optionally_at(
    ["image"],
    None,
    ap_decode.image_url(),
  ))
  use url <- decode.then(first_iri("url"))
  use inbox <- decode.field("inbox", ap_decode.iri())
  use endpoint_inbox <- decode.then(decode.optionally_at(
    ["endpoints", "sharedInbox"],
    None,
    decode.optional(ap_decode.iri()) |> lenient(None),
  ))
  use top_level_inbox <- decode.then(first_iri("sharedInbox"))
  use followers_uri <- decode.then(first_iri("followers"))
  use locked <- decode.then(decode.optionally_at(
    ["manuallyApprovesFollowers"],
    False,
    decode.bool |> lenient(False),
  ))
  use key <- decode.field("publicKey", public_key_decoder(wanted_key))
  let username = case preferred {
    "" -> last_segment(uri)
    name -> name
  }
  let display_name = case name {
    Some(n) if n != "" -> n
    _ -> username
  }
  decode.success(types.RemoteActor(
    id: 0,
    uri:,
    username:,
    domain: domain_of(uri),
    display_name:,
    summary_html: sanitize_summary(option.unwrap(summary, "")),
    avatar_url:,
    header_url:,
    url:,
    inbox:,
    shared_inbox: option.or(endpoint_inbox, top_level_inbox),
    followers_uri:,
    public_key_id: key.0,
    public_key_pem: key.1,
    bot: list.contains(types, "Service") || list.contains(types, "Application"),
    locked:,
  ))
}

/// The single place where remote profile HTML is cleaned.
/// TODO(task 10): pass through `html.sanitize` once it exists.
fn sanitize_summary(html: String) -> String {
  html
}

fn public_key_decoder(wanted: Option(String)) -> Decoder(#(String, String)) {
  let key = {
    use id <- decode.optional_field("id", "", decode.string)
    use pem <- decode.field("publicKeyPem", decode.string)
    decode.success(#(id, pem))
  }
  let pick = fn(keys: List(#(String, String))) {
    let matching = case wanted {
      Some(id) -> list.find(keys, fn(k) { k.0 == id })
      None -> Error(Nil)
    }
    case matching, keys {
      Ok(k), _ -> decode.success(k)
      Error(Nil), [first, ..] -> decode.success(first)
      Error(Nil), [] -> decode.failure(#("", ""), "PublicKey")
    }
  }
  decode.one_of(decode.list(key) |> decode.then(pick), [key])
}

fn last_segment(iri: String) -> String {
  case iri |> string.split("/") |> list.last {
    Ok(s) -> s
    Error(Nil) -> iri
  }
}

/// The authority of `iri` (host, plus `:port` when explicit).
fn domain_of(iri: String) -> String {
  case uri.parse(iri) {
    Ok(uri.Uri(host: Some(host), port: Some(port), ..)) ->
      string.lowercase(host) <> ":" <> int.to_string(port)
    Ok(uri.Uri(host: Some(host), ..)) -> string.lowercase(host)
    _ -> ""
  }
}

// --- fetching ----------------------------------------------------------------

fn now_seconds(ctx: Context) -> Int {
  timestamp.to_unix_seconds(ctx.now()) |> float.truncate
}

fn db_error(e: sqlight.Error) -> String {
  "database: " <> e.message
}

/// Returns the stored actor for `uri` when it was fetched within 24 hours
/// and (when given) carries the key `key_id`.
fn cached(
  ctx: Context,
  uri: String,
  key_id: Option(String),
) -> Result(Option(RemoteActor), String) {
  use row <- result.map(
    db.with_connection(ctx.db_path, remote_actors.get_cached(_, uri))
    |> result.map_error(db_error),
  )
  case row {
    Some(#(actor, fetched_at)) ->
      case
        now_seconds(ctx) - fetched_at < cache_ttl_seconds
        && key_matches(actor, key_id)
      {
        True -> Some(actor)
        False -> None
      }
    None -> None
  }
}

fn key_matches(actor: RemoteActor, key_id: Option(String)) -> Bool {
  case key_id {
    Some(id) -> actor.public_key_id == id
    None -> True
  }
}

/// Stores `actor`. Unless `domain` is given, an existing row keeps its domain
/// (it may have come from an acct lookup rather than from the actor URI).
fn store(
  ctx: Context,
  actor: RemoteActor,
  domain: Option(String),
) -> Result(RemoteActor, String) {
  db.with_connection(ctx.db_path, fn(conn) {
    use existing <- result.try(remote_actors.get_by_uri(conn, actor.uri))
    let domain = case domain, existing {
      Some(d), _ -> d
      None, Some(row) -> row.domain
      None, None -> actor.domain
    }
    remote_actors.upsert(
      conn,
      types.RemoteActor(..actor, domain:),
      now_seconds(ctx),
    )
  })
  |> result.map_error(db_error)
}

fn fetch_body(ctx: Context, uri: String) -> Result(String, String) {
  case http_client.signed_get(ctx, uri) {
    Error(e) ->
      Error("fetching " <> uri <> ": " <> http_client.describe_error(e))
    Ok(res) ->
      case res.status {
        200 -> Ok(res.body)
        status ->
          Error("fetching " <> uri <> ": HTTP " <> int.to_string(status))
      }
  }
}

/// Fetches and decodes the actor at `uri`; the document's `id` must be `uri`.
fn fetch_actor(
  ctx: Context,
  uri: String,
  key_id: Option(String),
) -> Result(RemoteActor, String) {
  use body <- result.try(fetch_body(ctx, uri))
  use actor <- result.try(decode_for_key(body, key_id))
  check_id(actor, uri)
}

fn check_id(actor: RemoteActor, uri: String) -> Result(RemoteActor, String) {
  case actor.uri == uri {
    True -> Ok(actor)
    False -> Error("actor id " <> actor.uri <> " does not match " <> uri)
  }
}

fn fetch_and_store(
  ctx: Context,
  uri: String,
  key_id: Option(String),
  domain: Option(String),
) -> Result(RemoteActor, String) {
  use actor <- result.try(fetch_actor(ctx, uri, key_id))
  store(ctx, actor, domain)
}

/// The actor at `uri`, from the cache when fetched within 24 hours.
pub fn get_or_fetch(ctx: Context, uri: String) -> Result(RemoteActor, String) {
  get_or_fetch_for_key(ctx, uri, None)
}

fn get_or_fetch_for_key(
  ctx: Context,
  uri: String,
  key_id: Option(String),
) -> Result(RemoteActor, String) {
  use hit <- result.try(cached(ctx, uri, key_id))
  case hit {
    Some(actor) -> Ok(actor)
    None -> fetch_and_store(ctx, uri, key_id, None)
  }
}

/// Fetches the actor at `uri` and refreshes the stored row.
pub fn refetch(ctx: Context, uri: String) -> Result(RemoteActor, String) {
  fetch_and_store(ctx, uri, None, None)
}

/// The actor owning the key `key_id`. The fragment is stripped and that
/// document fetched; if it is a bare key (`{owner, publicKeyPem}`) its
/// `owner` is fetched instead. The actor must actually list `key_id`.
pub fn by_key_id(ctx: Context, key_id: String) -> Result(RemoteActor, String) {
  let doc_uri = case string.split_once(key_id, "#") {
    Ok(#(before, _)) -> before
    Error(Nil) -> key_id
  }
  let wanted = Some(key_id)
  use hit <- result.try(cached(ctx, doc_uri, wanted))
  case hit {
    Some(actor) -> Ok(actor)
    None -> {
      use body <- result.try(fetch_body(ctx, doc_uri))
      case decode_for_key(body, wanted) {
        Ok(actor) -> {
          use actor <- result.try(check_id(actor, doc_uri))
          use actor <- result.try(require_key(actor, key_id))
          store(ctx, actor, None)
        }
        Error(_) -> {
          use owner <- result.try(
            json.parse(body, decode.at(["owner"], ap_decode.iri()))
            |> result.replace_error(
              "document at " <> doc_uri <> " is neither an actor nor a key",
            ),
          )
          use actor <- result.try(get_or_fetch_for_key(ctx, owner, wanted))
          require_key(actor, key_id)
        }
      }
    }
  }
}

fn require_key(
  actor: RemoteActor,
  key_id: String,
) -> Result(RemoteActor, String) {
  case actor.public_key_id == key_id {
    True -> Ok(actor)
    False -> Error("actor " <> actor.uri <> " does not list key " <> key_id)
  }
}

// --- WebFinger ---------------------------------------------------------------

type Link {
  Link(rel: String, type_: String, href: String)
}

fn link_decoder() -> Decoder(Link) {
  use rel <- decode.optional_field("rel", "", decode.string)
  use type_ <- decode.optional_field("type", "", decode.string)
  use href <- decode.optional_field("href", "", decode.string)
  decode.success(Link(rel:, type_:, href:))
}

fn is_activity_type(type_: String) -> Bool {
  string.contains(type_, "activity+json")
  || string.contains(type_, "https://www.w3.org/ns/activitystreams")
}

/// Resolves `username@domain` through WebFinger. The stored `domain` is the
/// acct domain, even when the actor lives on another host.
pub fn resolve_acct(
  ctx: Context,
  username: String,
  domain: String,
) -> Result(RemoteActor, String) {
  let domain = string.lowercase(domain)
  let url =
    "https://"
    <> domain
    <> "/.well-known/webfinger?resource=acct:"
    <> username
    <> "@"
    <> domain
  use res <- result.try(
    http_client.get(ctx, url, "application/jrd+json, application/json")
    |> result.map_error(fn(e) {
      "webfinger " <> url <> ": " <> http_client.describe_error(e)
    }),
  )
  use <- require_ok(res, "webfinger " <> url)
  use links <- result.try(
    json.parse(
      res.body,
      decode.optionally_at(["links"], [], decode.list(link_decoder())),
    )
    |> result.replace_error("webfinger " <> url <> ": invalid JSON"),
  )
  use self <- result.try(
    list.find(links, fn(l) {
      l.rel == "self" && is_activity_type(l.type_) && l.href != ""
    })
    |> result.replace_error("webfinger " <> url <> ": no ActivityPub self link"),
  )
  use actor <- result.try(fetch_actor(ctx, self.href, None))
  case string.lowercase(actor.username) == string.lowercase(username) {
    True -> store(ctx, actor, Some(domain))
    False ->
      Error(
        "actor "
        <> actor.uri
        <> " is "
        <> actor.username
        <> ", not "
        <> username,
      )
  }
}

fn require_ok(
  res: response.Response(String),
  what: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case res.status {
    200 -> next()
    status -> Error(what <> ": HTTP " <> int.to_string(status))
  }
}
