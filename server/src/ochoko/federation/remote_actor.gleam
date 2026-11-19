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
import ochoko/html
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
  use url <- decode.then(
    decode.optionally_at(["url"], [], ap_decode.iri_list())
    |> decode.map(ap_decode.first_web_url),
  )
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
fn sanitize_summary(raw: String) -> String {
  html.sanitize(raw)
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

/// Why an actor could not be obtained. Database failures are kept apart so
/// that the inbox can answer 500 (and the sender retry) instead of 401.
pub type ActorError {
  FetchError(String)
  DatabaseError(String)
}

pub fn describe_error(e: ActorError) -> String {
  case e {
    FetchError(reason) -> reason
    DatabaseError(reason) -> "database: " <> reason
  }
}

fn now_seconds(ctx: Context) -> Int {
  timestamp.to_unix_seconds(ctx.now()) |> float.truncate
}

fn db_error(e: sqlight.Error) -> ActorError {
  DatabaseError(e.message)
}

fn is_fresh(ctx: Context, fetched_at: Int) -> Bool {
  now_seconds(ctx) - fetched_at < cache_ttl_seconds
}

/// Returns the stored actor for `uri` when it was fetched within 24 hours
/// and (when given) carries the key `key_id`.
fn cached(
  ctx: Context,
  uri: String,
  key_id: Option(String),
) -> Result(Option(RemoteActor), ActorError) {
  use row <- result.map(
    db.with_connection(ctx.db_path, remote_actors.get_cached(_, uri))
    |> result.map_error(db_error),
  )
  case row {
    Some(#(actor, fetched_at)) ->
      case is_fresh(ctx, fetched_at) && key_matches(actor, key_id) {
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

/// The stored actor holding the key `key_id`: the actor at the key's
/// document URI (`…#main-key`), else one on the key's own host that lists
/// it (GoToSocial's `…/main-key`). Requiring the same host stops an actor
/// elsewhere from claiming somebody else's key id in the cache. With
/// `fresh_only`, rows older than 24 hours are ignored.
fn stored_for_key(
  ctx: Context,
  key_id: String,
  fresh_only: Bool,
) -> Result(Option(RemoteActor), ActorError) {
  let usable = fn(row: #(RemoteActor, Int)) {
    { !fresh_only || is_fresh(ctx, row.1) } && row.0.public_key_id == key_id
  }
  let doc_uri = strip_fragment(key_id)
  let host = domain_of(key_id)
  use #(by_uri, by_key) <- result.map(
    db.with_connection(ctx.db_path, fn(conn) {
      use by_uri <- result.try(remote_actors.get_cached(conn, doc_uri))
      use by_key <- result.map(remote_actors.get_cached_by_key_id(conn, key_id))
      #(by_uri, by_key)
    })
    |> result.map_error(db_error),
  )
  let candidates =
    list.append(
      option.to_result(by_uri, Nil)
        |> result.map(fn(r) { [r] })
        |> result.unwrap([]),
      list.filter(by_key, fn(row) { host != "" && domain_of(row.0.uri) == host }),
    )
  list.find(candidates, usable)
  |> result.map(fn(row) { row.0 })
  |> option.from_result
}

fn strip_fragment(iri: String) -> String {
  case string.split_once(iri, "#") {
    Ok(#(before, _)) -> before
    Error(Nil) -> iri
  }
}

/// Stores `actor`. Unless `domain` is given, an existing row keeps its domain
/// (it may have come from an acct lookup rather than from the actor URI).
fn store(
  ctx: Context,
  actor: RemoteActor,
  domain: Option(String),
) -> Result(RemoteActor, ActorError) {
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

fn fetch_body(ctx: Context, uri: String) -> Result(String, ActorError) {
  case http_client.signed_get(ctx, uri) {
    Error(e) ->
      Error(FetchError(
        "fetching " <> uri <> ": " <> http_client.describe_error(e),
      ))
    Ok(res) ->
      case res.status {
        200 -> Ok(res.body)
        status ->
          Error(FetchError(
            "fetching " <> uri <> ": HTTP " <> int.to_string(status),
          ))
      }
  }
}

/// Fetches and decodes the actor at `uri`; the document's `id` must be `uri`.
fn fetch_actor(
  ctx: Context,
  uri: String,
  key_id: Option(String),
) -> Result(RemoteActor, ActorError) {
  use body <- result.try(fetch_body(ctx, uri))
  use actor <- result.try(
    decode_for_key(body, key_id) |> result.map_error(FetchError),
  )
  check_id(actor, uri)
}

fn check_id(
  actor: RemoteActor,
  uri: String,
) -> Result(RemoteActor, ActorError) {
  case actor.uri == uri {
    True -> Ok(actor)
    False ->
      Error(FetchError("actor id " <> actor.uri <> " does not match " <> uri))
  }
}

fn fetch_and_store(
  ctx: Context,
  uri: String,
  key_id: Option(String),
  domain: Option(String),
) -> Result(RemoteActor, ActorError) {
  use actor <- result.try(fetch_actor(ctx, uri, key_id))
  store(ctx, actor, domain)
}

/// The actor at `uri`, from the cache when fetched within 24 hours.
pub fn get_or_fetch(
  ctx: Context,
  uri: String,
) -> Result(RemoteActor, ActorError) {
  get_or_fetch_for_key(ctx, uri, None)
}

fn get_or_fetch_for_key(
  ctx: Context,
  uri: String,
  key_id: Option(String),
) -> Result(RemoteActor, ActorError) {
  use hit <- result.try(cached(ctx, uri, key_id))
  case hit {
    Some(actor) -> Ok(actor)
    None -> fetch_and_store(ctx, uri, key_id, None)
  }
}

/// Fetches the actor at `uri` and refreshes the stored row.
pub fn refetch(ctx: Context, uri: String) -> Result(RemoteActor, ActorError) {
  fetch_and_store(ctx, uri, None, None)
}

/// Fetches the actor at `uri`, which must list the key `key_id` (picked out
/// of a `publicKey` array), and refreshes the stored row.
pub fn refetch_for_key(
  ctx: Context,
  uri: String,
  key_id: String,
) -> Result(RemoteActor, ActorError) {
  use actor <- result.try(fetch_actor(ctx, uri, Some(key_id)))
  use actor <- result.try(require_key(actor, key_id))
  store(ctx, actor, None)
}

/// The stored actor holding `key_id`, however old. Used to authenticate a
/// `Delete` from an actor that can no longer be fetched.
pub fn stale_by_key_id(
  ctx: Context,
  key_id: String,
) -> Result(Option(RemoteActor), ActorError) {
  stored_for_key(ctx, key_id, False)
}

/// The actor owning the key `key_id`.
///
/// A cached actor (fetched within 24 hours) holding the key is used if there
/// is one. Otherwise the key id without its fragment is fetched:
/// - an actor document with that very id is used directly (Mastodon's
///   `…/users/x#main-key`);
/// - else the document's owner is taken from `publicKey.owner` (the
///   `publicKey` entry whose `id` is `key_id`, as in GoToSocial's
///   `…/users/x/main-key` stub) or from a bare key's top-level `owner`, and
///   the owner's actor document is fetched (or taken from the cache).
/// In every case the actor must itself list `key_id`.
pub fn by_key_id(
  ctx: Context,
  key_id: String,
) -> Result(RemoteActor, ActorError) {
  let doc_uri = strip_fragment(key_id)
  let wanted = Some(key_id)
  use hit <- result.try(stored_for_key(ctx, key_id, True))
  case hit {
    Some(actor) -> Ok(actor)
    None -> {
      use body <- result.try(fetch_body(ctx, doc_uri))
      case decode_for_key(body, wanted) {
        Ok(actor) if actor.uri == doc_uri -> {
          use actor <- result.try(require_key(actor, key_id))
          store(ctx, actor, None)
        }
        _ -> {
          use owner <- result.try(
            json.parse(body, key_owner_decoder(key_id))
            |> result.replace_error(FetchError(
              "document at " <> doc_uri <> " is neither an actor nor a key",
            )),
          )
          use actor <- result.try(get_or_fetch_for_key(ctx, owner, wanted))
          require_key(actor, key_id)
        }
      }
    }
  }
}

/// The owner of `key_id` as stated by a fetched key document: the `owner`
/// of the `publicKey` entry with that id (falling back to the document's
/// own id), or the top-level `owner` of a bare key whose id it is.
fn key_owner_decoder(key_id: String) -> Decoder(String) {
  let entry = {
    use id <- decode.optional_field("id", "", decode.string)
    use owner <- decode.optional_field(
      "owner",
      None,
      ap_decode.iri() |> decode.map(Some),
    )
    decode.success(#(id, owner))
  }
  let entries =
    decode.one_of(decode.list(entry), [entry |> decode.map(fn(e) { [e] })])
  let from_public_key = {
    use doc_id <- decode.field("id", ap_decode.iri())
    use keys <- decode.field("publicKey", entries)
    case list.find(keys, fn(k) { k.0 == key_id }) {
      Ok(#(_, Some(owner))) -> decode.success(owner)
      Ok(#(_, None)) -> decode.success(doc_id)
      Error(Nil) -> decode.failure("", "publicKey with id " <> key_id)
    }
  }
  let bare_key = {
    use id <- decode.field("id", ap_decode.iri())
    use owner <- decode.field("owner", ap_decode.iri())
    case id == key_id {
      True -> decode.success(owner)
      False -> decode.failure("", "key " <> key_id)
    }
  }
  decode.one_of(from_public_key, [bare_key])
}

fn require_key(
  actor: RemoteActor,
  key_id: String,
) -> Result(RemoteActor, ActorError) {
  case actor.public_key_id == key_id {
    True -> Ok(actor)
    False ->
      Error(FetchError("actor " <> actor.uri <> " does not list key " <> key_id))
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

/// How many redirects a WebFinger lookup follows.
const max_webfinger_redirects = 3

/// GETs `url`, following up to `hops_left` redirects. Every hop goes through
/// `http_client.get`, so each target must pass the same https and host
/// checks.
fn get_following_redirects(
  ctx: Context,
  url: String,
  accept: String,
  hops_left: Int,
) -> Result(response.Response(String), ActorError) {
  use res <- result.try(
    http_client.get(ctx, url, accept)
    |> result.map_error(fn(e) {
      FetchError("webfinger " <> url <> ": " <> http_client.describe_error(e))
    }),
  )
  case is_redirect(res.status), response.get_header(res, "location") {
    True, Ok(location) if hops_left > 0 -> {
      use next <- result.try(
        resolve_reference(url, location)
        |> result.replace_error(FetchError(
          "webfinger " <> url <> ": invalid redirect " <> location,
        )),
      )
      get_following_redirects(ctx, next, accept, hops_left - 1)
    }
    True, _ ->
      Error(FetchError("webfinger " <> url <> ": too many or bad redirects"))
    False, _ -> Ok(res)
  }
}

fn is_redirect(status: Int) -> Bool {
  list.contains([301, 302, 303, 307, 308], status)
}

fn resolve_reference(base: String, location: String) -> Result(String, Nil) {
  use base <- result.try(uri.parse(base))
  use relative <- result.try(uri.parse(string.trim(location)))
  uri.merge(base, relative) |> result.map(uri.to_string)
}

/// Resolves `username@domain` through WebFinger (following up to three
/// redirects). The stored `domain` is the acct domain, even when the actor
/// lives on another host.
pub fn resolve_acct(
  ctx: Context,
  username: String,
  domain: String,
) -> Result(RemoteActor, ActorError) {
  let domain = string.lowercase(domain)
  let url =
    "https://"
    <> domain
    <> "/.well-known/webfinger?resource=acct:"
    <> username
    <> "@"
    <> domain
  use res <- result.try(get_following_redirects(
    ctx,
    url,
    "application/jrd+json, application/json",
    max_webfinger_redirects,
  ))
  use <- require_ok(res, "webfinger " <> url)
  use links <- result.try(
    json.parse(
      res.body,
      decode.optionally_at(["links"], [], decode.list(link_decoder())),
    )
    |> result.replace_error(FetchError("webfinger " <> url <> ": invalid JSON")),
  )
  use self <- result.try(
    list.find(links, fn(l) {
      l.rel == "self" && is_activity_type(l.type_) && l.href != ""
    })
    |> result.replace_error(FetchError(
      "webfinger " <> url <> ": no ActivityPub self link",
    )),
  )
  use actor <- result.try(fetch_actor(ctx, self.href, None))
  case string.lowercase(actor.username) == string.lowercase(username) {
    True -> store(ctx, actor, Some(domain))
    False ->
      Error(FetchError(
        "actor "
        <> actor.uri
        <> " is "
        <> actor.username
        <> ", not "
        <> username,
      ))
  }
}

fn require_ok(
  res: response.Response(String),
  what: String,
  next: fn() -> Result(a, ActorError),
) -> Result(a, ActorError) {
  case res.status {
    200 -> next()
    status -> Error(FetchError(what <> ": HTTP " <> int.to_string(status)))
  }
}
