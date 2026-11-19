import gleam/dynamic/decode
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import ochoko/context
import ochoko/crypto/rsa
import ochoko/db
import ochoko/federation/remote_actor
import ochoko/http_client
import ochoko/signature
import simplifile
import sqlight
import support

fn fixture(name: String) -> String {
  let assert Ok(body) = simplifile.read("test/fixtures/ap/" <> name)
  body
}

pub fn decode_mastodon_actor_test() {
  let assert Ok(a) = remote_actor.decode(fixture("mastodon_actor.json"))
  assert a.id == 0
  assert a.uri == "https://fosstodon.org/users/fosstodon"
  assert a.username == "fosstodon"
  assert a.domain == "fosstodon.org"
  assert a.inbox == "https://fosstodon.org/users/fosstodon/inbox"
  assert a.shared_inbox == Some("https://fosstodon.org/inbox")
  assert a.public_key_id == "https://fosstodon.org/users/fosstodon#main-key"
  assert string.starts_with(a.public_key_pem, "-----BEGIN PUBLIC KEY-----")
  assert a.url == Some("https://fosstodon.org/@fosstodon")
  assert a.followers_uri
    == Some("https://fosstodon.org/users/fosstodon/followers")
  assert option.is_some(a.avatar_url)
  assert option.is_some(a.header_url)
  assert !a.bot
  assert !a.locked
  assert a.summary_html != ""
}

pub fn decode_misskey_actor_test() {
  let assert Ok(a) = remote_actor.decode(fixture("misskey_actor.json"))
  assert a.uri == "https://misskey.io/users/7rkrarq81i"
  assert a.username == "syuilo"
  assert a.domain == "misskey.io"
  assert a.inbox == "https://misskey.io/users/7rkrarq81i/inbox"
  assert a.shared_inbox == Some("https://misskey.io/inbox")
  assert a.public_key_pem != ""
  assert a.url == Some("https://misskey.io/@syuilo")
}

pub fn decode_gotosocial_actor_test() {
  let assert Ok(a) = remote_actor.decode(fixture("gotosocial_actor.json"))
  assert a.uri == "http://localhost:8080/users/the_mighty_zork"
  assert a.username == "the_mighty_zork"
  assert a.domain == "localhost:8080"
  assert a.inbox == "http://localhost:8080/users/the_mighty_zork/inbox"
  assert a.shared_inbox == None
  assert a.public_key_id
    == "http://localhost:8080/users/the_mighty_zork/main-key"
  assert a.public_key_pem != ""
  assert a.display_name == "original zork (he/they)"
  assert a.summary_html == "<p>hey yo this is my profile!</p>"
  assert !a.locked
}

pub fn decode_akkoma_actor_test() {
  let assert Ok(a) = remote_actor.decode(fixture("akkoma_actor.json"))
  assert a.uri == "https://fedi.absturztau.be/users/mauthausengusen"
  assert a.username == "mauthausengusen"
  assert a.inbox == "https://fedi.absturztau.be/users/mauthausengusen/inbox"
  assert a.shared_inbox == Some("https://fedi.absturztau.be/inbox")
  assert a.public_key_pem != ""
  assert a.bot
}

fn actor_json(extra: List(#(String, json.Json))) -> String {
  let base = [
    #("id", json.string("https://r.example/users/a")),
    #("type", json.string("Person")),
    #("preferredUsername", json.string("a")),
  ]
  let base =
    list.filter(base, fn(pair) { result.is_error(list.key_find(extra, pair.0)) })
  json.object(list.append(base, extra))
  |> json.to_string
}

fn key(id: String, pem: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("owner", json.string("https://r.example/users/a")),
    #("publicKeyPem", json.string(pem)),
  ])
}

pub fn decode_publickey_array_test() {
  let body =
    actor_json([
      #("inbox", json.string("https://r.example/users/a/inbox")),
      #(
        "publicKey",
        json.preprocessed_array([
          key("https://r.example/users/a#k1", "PEM1"),
          key("https://r.example/users/a#k2", "PEM2"),
        ]),
      ),
    ])
  let assert Ok(first) = remote_actor.decode(body)
  assert first.public_key_id == "https://r.example/users/a#k1"
  assert first.public_key_pem == "PEM1"
  let assert Ok(second) =
    remote_actor.decode_for_key(body, Some("https://r.example/users/a#k2"))
  assert second.public_key_pem == "PEM2"
}

pub fn decode_missing_inbox_error_test() {
  let body =
    actor_json([
      #("publicKey", key("https://r.example/users/a#k", "PEM")),
    ])
  let assert Error(_) = remote_actor.decode(body)
}

pub fn decode_locked_and_bot_test() {
  let body =
    actor_json([
      #("type", json.array(["Application"], json.string)),
      #("manuallyApprovesFollowers", json.bool(True)),
      #("inbox", json.string("https://r.example/users/a/inbox")),
      #("publicKey", key("https://r.example/users/a#k", "PEM")),
    ])
  let assert Ok(a) = remote_actor.decode(body)
  assert a.bot
  assert a.locked
  assert a.display_name == "a"
}

// --- fetching ---------------------------------------------------------------

const actor_uri = "https://fosstodon.org/users/fosstodon"

fn mastodon_routes() {
  [#(actor_uri, support.json_response(fixture("mastodon_actor.json")))]
}

pub fn get_or_fetch_caches_test() {
  let #(send, requests) =
    support.recording_send(support.fake_send(mastodon_routes()))
  let ctx = support.test_context_with_send(support.temp_db_path(), send)
  let assert Ok(first) = remote_actor.get_or_fetch(ctx, actor_uri)
  let assert Ok(second) = remote_actor.get_or_fetch(ctx, actor_uri)
  assert first.id > 0
  assert second.id == first.id
  assert second.username == "fosstodon"
  assert list.length(requests()) == 1
}

pub fn get_or_fetch_refetches_after_24_hours_test() {
  let #(send, requests) =
    support.recording_send(support.fake_send(mastodon_routes()))
  let path = support.temp_db_path()
  let ctx = support.test_context_with_send(path, send)
  let assert Ok(first) = remote_actor.get_or_fetch(ctx, actor_uri)
  let later =
    context.Context(..ctx, now: fn() {
      timestamp.from_unix_seconds(1_700_000_000 + 86_401)
    })
  let assert Ok(second) = remote_actor.get_or_fetch(later, actor_uri)
  assert second.id == first.id
  assert list.length(requests()) == 2
}

pub fn get_or_fetch_error_on_404_test() {
  let ctx = support.test_context(support.temp_db_path())
  let assert Error(_) =
    remote_actor.get_or_fetch(ctx, "https://nowhere.example/users/x")
}

pub fn get_or_fetch_rejects_id_mismatch_test() {
  let routes = [
    #(
      "https://evil.example/users/x",
      support.json_response(fixture("mastodon_actor.json")),
    ),
  ]
  let ctx =
    support.test_context_with_send(
      support.temp_db_path(),
      support.fake_send(routes),
    )
  let assert Error(_) =
    remote_actor.get_or_fetch(ctx, "https://evil.example/users/x")
}

pub fn refetch_updates_row_test() {
  let #(send, requests) =
    support.recording_send(support.fake_send(mastodon_routes()))
  let ctx = support.test_context_with_send(support.temp_db_path(), send)
  let assert Ok(first) = remote_actor.get_or_fetch(ctx, actor_uri)
  let assert Ok(second) = remote_actor.refetch(ctx, actor_uri)
  assert second.id == first.id
  assert list.length(requests()) == 2
}

pub fn by_key_id_follows_owner_test() {
  let key_url = "https://keys.example/keys/1"
  let owner = "https://r.example/users/a"
  let key_doc =
    json.object([
      #("id", json.string(key_url)),
      #("type", json.string("Key")),
      #("owner", json.string(owner)),
      #("publicKeyPem", json.string("PEM")),
    ])
    |> json.to_string
  let actor =
    json.object([
      #("id", json.string(owner)),
      #("type", json.string("Person")),
      #("preferredUsername", json.string("a")),
      #("inbox", json.string(owner <> "/inbox")),
      #("publicKey", key(key_url, "PEM")),
    ])
    |> json.to_string
  let routes = [
    #(key_url, support.json_response(key_doc)),
    #(owner, support.json_response(actor)),
  ]
  let ctx =
    support.test_context_with_send(
      support.temp_db_path(),
      support.fake_send(routes),
    )
  let assert Ok(a) = remote_actor.by_key_id(ctx, key_url)
  assert a.uri == owner
  assert a.public_key_id == key_url
}

pub fn by_key_id_strips_fragment_test() {
  let ctx =
    support.test_context_with_send(
      support.temp_db_path(),
      support.fake_send(mastodon_routes()),
    )
  let assert Ok(a) = remote_actor.by_key_id(ctx, actor_uri <> "#main-key")
  assert a.uri == actor_uri
}

pub fn by_key_id_rejects_key_not_on_owner_test() {
  let owner = "https://r.example/users/a"
  let key_url = "https://keys.example/keys/1"
  let key_doc =
    json.object([
      #("id", json.string(key_url)),
      #("owner", json.string(owner)),
      #("publicKeyPem", json.string("PEM")),
    ])
    |> json.to_string
  // The owner does not list that key.
  let actor =
    json.object([
      #("id", json.string(owner)),
      #("type", json.string("Person")),
      #("preferredUsername", json.string("a")),
      #("inbox", json.string(owner <> "/inbox")),
      #("publicKey", key(owner <> "#other", "PEM2")),
    ])
    |> json.to_string
  let routes = [
    #(key_url, support.json_response(key_doc)),
    #(owner, support.json_response(actor)),
  ]
  let ctx =
    support.test_context_with_send(
      support.temp_db_path(),
      support.fake_send(routes),
    )
  let assert Error(_) = remote_actor.by_key_id(ctx, key_url)
}

pub fn resolve_acct_test() {
  // The acct domain differs from the host the actor lives on.
  let owner = "https://social.example/users/alice"
  let webfinger =
    "{\"subject\":\"acct:alice@example.com\",\"links\":["
    <> "{\"rel\":\"http://webfinger.net/rel/profile-page\",\"type\":\"text/html\",\"href\":\"https://social.example/@alice\"},"
    <> "{\"rel\":\"self\",\"type\":\"application/activity+json\",\"href\":\""
    <> owner
    <> "\"}]}"
  let actor =
    json.object([
      #("id", json.string(owner)),
      #("type", json.string("Person")),
      #("preferredUsername", json.string("alice")),
      #("inbox", json.string(owner <> "/inbox")),
      #("publicKey", key(owner <> "#main-key", "PEM")),
    ])
    |> json.to_string
  let routes = [
    #(
      "https://example.com/.well-known/webfinger?resource=acct:alice@example.com",
      support.json_response(webfinger),
    ),
    #(owner, support.json_response(actor)),
  ]
  let path = support.temp_db_path()
  let ctx = support.test_context_with_send(path, support.fake_send(routes))
  let assert Ok(a) = remote_actor.resolve_acct(ctx, "alice", "example.com")
  assert a.uri == owner
  assert a.domain == "example.com"
  // A later cache refresh keeps the acct domain.
  let assert Ok(b) = remote_actor.refetch(ctx, owner)
  assert b.domain == "example.com"
  assert b.id == a.id
}

pub fn resolve_acct_unknown_test() {
  let ctx = support.test_context(support.temp_db_path())
  let assert Error(_) = remote_actor.resolve_acct(ctx, "nobody", "example.com")
}

pub fn get_or_fetch_stores_one_row_test() {
  let path = support.temp_db_path()
  let ctx =
    support.test_context_with_send(path, support.fake_send(mastodon_routes()))
  let assert Ok(_) = remote_actor.get_or_fetch(ctx, actor_uri)
  let assert Ok(_) = remote_actor.refetch(ctx, actor_uri)
  let rows =
    db.with_connection(path, fn(conn) {
      sqlight.query(
        "SELECT COUNT(*) FROM remote_actors",
        on: conn,
        with: [],
        expecting: decode.at([0], decode.int),
      )
    })
  assert rows == Ok([1])
}

pub fn signed_get_is_signed_test() {
  let #(send, requests) =
    support.recording_send(support.fake_send(mastodon_routes()))
  let ctx = support.test_context_with_send(support.temp_db_path(), send)
  let assert Ok(res) = http_client.signed_get(ctx, actor_uri)
  assert res.status == 200
  let assert [req] = requests()
  assert request.get_header(req, "accept") == Ok("application/activity+json")
  assert request.get_header(req, "user-agent")
    == Ok("ochoko/0.1.0 (+https://ochoko.ynkt.me/)")
  let assert Ok(parsed) = signature.parse_header(req)
  assert parsed.key_id == "https://ochoko.ynkt.me/me#main-key"
  let assert Ok(public) =
    rsa.public_from_pem(rsa.public_pem(support.test_key()))
  let assert Ok(Nil) = signature.verify(req, parsed, public, ctx.now())
}

// --- GoToSocial key ids --------------------------------------------------------

const gts_actor = "https://gts.example/users/zork"

const gts_key = "https://gts.example/users/zork/main-key"

fn gts_full_actor() -> String {
  json.object([
    #("id", json.string(gts_actor)),
    #("type", json.string("Person")),
    #("preferredUsername", json.string("zork")),
    #("inbox", json.string(gts_actor <> "/inbox")),
    #(
      "publicKey",
      json.object([
        #("id", json.string(gts_key)),
        #("owner", json.string(gts_actor)),
        #("publicKeyPem", json.string("PEM")),
      ]),
    ),
  ])
  |> json.to_string
}

/// What GoToSocial serves at the key URL: a stub of the actor.
fn gts_key_stub(extra: List(#(String, json.Json))) -> String {
  json.object([
    #("id", json.string(gts_actor)),
    #("type", json.string("Person")),
    #("preferredUsername", json.string("zork")),
    #(
      "publicKey",
      json.object([
        #("id", json.string(gts_key)),
        #("owner", json.string(gts_actor)),
        #("publicKeyPem", json.string("PEM")),
      ]),
    ),
    ..extra
  ])
  |> json.to_string
}

fn gts_lookup(stub: String) {
  let #(send, requests) =
    support.recording_send(
      support.fake_send([
        #(gts_key, support.json_response(stub)),
        #(gts_actor, support.json_response(gts_full_actor())),
      ]),
    )
  let ctx = support.test_context_with_send(support.temp_db_path(), send)
  let assert Ok(a) = remote_actor.by_key_id(ctx, gts_key)
  assert a.uri == gts_actor
  assert a.public_key_id == gts_key
  assert a.inbox == gts_actor <> "/inbox"
  // The second lookup is answered from the cache.
  let before = list.length(requests())
  let assert Ok(b) = remote_actor.by_key_id(ctx, gts_key)
  assert b.id == a.id
  assert list.length(requests()) == before
}

pub fn by_key_id_gotosocial_stub_without_inbox_test() {
  gts_lookup(gts_key_stub([]))
}

pub fn by_key_id_gotosocial_stub_with_inbox_test() {
  gts_lookup(gts_key_stub([#("inbox", json.string(gts_actor <> "/inbox"))]))
}

pub fn by_key_id_stub_owner_must_list_key_test() {
  // The stub claims an owner whose document lists another key.
  let other =
    json.object([
      #("id", json.string(gts_actor)),
      #("type", json.string("Person")),
      #("preferredUsername", json.string("zork")),
      #("inbox", json.string(gts_actor <> "/inbox")),
      #("publicKey", key(gts_actor <> "#other", "PEM")),
    ])
    |> json.to_string
  let ctx =
    support.test_context_with_send(
      support.temp_db_path(),
      support.fake_send([
        #(gts_key, support.json_response(gts_key_stub([]))),
        #(gts_actor, support.json_response(other)),
      ]),
    )
  let assert Error(_) = remote_actor.by_key_id(ctx, gts_key)
}

pub fn by_key_id_refuses_private_key_url_test() {
  let #(send, requests) =
    support.recording_send(support.fake_send(mastodon_routes()))
  let ctx = support.test_context_with_send(support.temp_db_path(), send)
  let assert Error(_) =
    remote_actor.by_key_id(ctx, "http://127.0.0.1/users/a#main-key")
  let assert Error(_) =
    remote_actor.by_key_id(ctx, "https://10.0.0.1/users/a#main-key")
  assert requests() == []
}

pub fn decode_drops_non_web_urls_test() {
  let body =
    actor_json([
      #("inbox", json.string("https://r.example/users/a/inbox")),
      #("publicKey", key("https://r.example/users/a#k", "PEM")),
      #("url", json.string("javascript:alert(1)")),
      #(
        "icon",
        json.object([
          #("type", json.string("Image")),
          #("url", json.string("javascript:alert(2)")),
        ]),
      ),
      #("image", json.string("vbscript:x")),
    ])
  let assert Ok(a) = remote_actor.decode(body)
  assert a.url == None
  assert a.avatar_url == None
  assert a.header_url == None
}

pub fn decode_keeps_http_urls_test() {
  let body =
    actor_json([
      #("inbox", json.string("https://r.example/users/a/inbox")),
      #("publicKey", key("https://r.example/users/a#k", "PEM")),
      #("url", json.string("http://r.example/@a")),
      #("icon", json.string("https://r.example/a.png")),
    ])
  let assert Ok(a) = remote_actor.decode(body)
  assert a.url == Some("http://r.example/@a")
  assert a.avatar_url == Some("https://r.example/a.png")
}
