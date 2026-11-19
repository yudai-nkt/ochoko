import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/time/timestamp
import ochoko/context.{type Context}
import ochoko/db
import ochoko/federation/note
import ochoko/federation/remote_actor
import ochoko/store/follows
import ochoko/store/profile
import ochoko/store/statuses
import ochoko/web/router
import ochoko_shared/mastodon
import sqlight
import support
import wisp
import wisp/simulate

const remote_uri = "https://r.example/users/remote"

const webfinger_url =
  "https://r.example/.well-known/webfinger?resource=acct:remote@r.example"

fn webfinger() -> String {
  "{\"subject\":\"acct:remote@r.example\",\"links\":[{\"rel\":\"self\",\"type\":\"application/activity+json\",\"href\":\""
  <> remote_uri
  <> "\"}]}"
}

fn routes() {
  [
    #(
      remote_uri,
      support.json_response(support.remote_actor_json(
        remote_uri,
        support.remote_key(),
      )),
    ),
    #(webfinger_url, support.json_response(webfinger())),
  ]
}

fn setup() -> #(String, Context, String) {
  let path = support.temp_db_path()
  let ctx = support.test_context_with_send(path, support.fake_send(routes()))
  #(path, ctx, support.user_token(ctx))
}

fn call(
  ctx: Context,
  token: String,
  method: http.Method,
  path: String,
) -> wisp.Response {
  router.handle_request(
    simulate.request(method, path)
      |> request.set_header("authorization", "Bearer " <> token),
    ctx,
  )
}

fn get(ctx: Context, token: String, path: String) -> wisp.Response {
  call(ctx, token, http.Get, path)
}

fn post(ctx: Context, token: String, path: String) -> wisp.Response {
  call(ctx, token, http.Post, path)
}

fn str(res: wisp.Response, path: List(String)) -> String {
  let assert Ok(v) =
    json.parse(simulate.read_body(res), decode.at(path, decode.string))
  v
}

fn flag(res: wisp.Response, path: List(String)) -> Bool {
  let assert Ok(v) =
    json.parse(simulate.read_body(res), decode.at(path, decode.bool))
  v
}

fn strings(res: wisp.Response, key: String) -> List(String) {
  let assert Ok(v) =
    json.parse(
      simulate.read_body(res),
      decode.list(decode.at([key], decode.string)),
    )
  v
}

/// Caches the remote actor and returns its row id.
fn remote_id(ctx: Context) -> Int {
  let assert Ok(a) = remote_actor.get_or_fetch(ctx, remote_uri)
  a.id
}

fn deliveries(path: String) -> List(#(String, String)) {
  let assert Ok(rows) =
    db.with_connection(path, fn(conn) {
      sqlight.query(
        "SELECT inbox, body FROM deliveries ORDER BY id",
        on: conn,
        with: [],
        expecting: {
          use inbox <- decode.field(0, decode.string)
          use body <- decode.field(1, decode.string)
          decode.success(#(inbox, body))
        },
      )
    })
  rows
}

fn field_of(body: String, key: String) -> String {
  let assert Ok(v) = json.parse(body, decode.at([key], decode.string))
  v
}

// --- instance -----------------------------------------------------------------

pub fn instance_v2_test() {
  let #(_, ctx, _) = setup()
  let res =
    router.handle_request(simulate.request(http.Get, "/api/v2/instance"), ctx)
  assert res.status == 200
  assert str(res, ["version"]) == "4.3.0 (compatible; ochoko 0.1.0)"
  // The account domain (Mastodon's LOCAL_DOMAIN), so clients show
  // @yudai@ynkt.me.
  assert str(res, ["domain"]) == "ynkt.me"
  assert str(res, ["title"]) == "ochoko"
  assert str(res, ["contact", "account", "acct"]) == "yudai"
  assert flag(res, ["registrations", "enabled"]) == False
  let assert Ok(n) =
    json.parse(
      simulate.read_body(res),
      decode.at(["configuration", "statuses", "max_characters"], decode.int),
    )
  assert n == 500
}

pub fn instance_v1_test() {
  let #(_, ctx, _) = setup()
  let res =
    router.handle_request(simulate.request(http.Get, "/api/v1/instance"), ctx)
  assert res.status == 200
  assert str(res, ["uri"]) == "ynkt.me"
  assert str(res, ["version"]) == "4.3.0 (compatible; ochoko 0.1.0)"
  let assert Ok(n) =
    json.parse(
      simulate.read_body(res),
      decode.at(
        ["configuration", "statuses", "characters_reserved_per_url"],
        decode.int,
      ),
    )
  assert n == 23
}

// --- local account ---------------------------------------------------------------

pub fn verify_credentials_test() {
  let #(path, ctx, token) = setup()
  let assert Ok(Nil) =
    db.with_connection(path, profile.update(
      _,
      profile.Profile("Yudai", "hello", None, None),
    ))
  let res = get(ctx, token, "/api/v1/accounts/verify_credentials")
  assert res.status == 200
  assert str(res, ["id"]) == "0"
  assert str(res, ["acct"]) == "yudai"
  assert str(res, ["display_name"]) == "Yudai"
  assert str(res, ["note"]) == "<p>hello</p>"
  assert str(res, ["source", "privacy"]) == "public"
  assert str(res, ["source", "note"]) == "hello"
  assert flag(res, ["source", "sensitive"]) == False
}

pub fn verify_credentials_requires_user_token_test() {
  let #(_, ctx, _) = setup()
  let res =
    router.handle_request(
      simulate.request(http.Get, "/api/v1/accounts/verify_credentials"),
      ctx,
    )
  assert res.status == 401
}

pub fn local_account_default_avatar_test() {
  let #(_, ctx, token) = setup()
  let res = get(ctx, token, "/api/v1/accounts/0")
  assert str(res, ["avatar"]) == "https://ochoko.ynkt.me/static/avatar.png"
  assert str(res, ["url"]) == "https://ochoko.ynkt.me/me"
}

pub fn static_avatar_served_test() {
  let #(_, ctx, _) = setup()
  let res =
    router.handle_request(simulate.request(http.Get, "/static/avatar.png"), ctx)
  assert res.status == 200
  assert list.key_find(res.headers, "content-type") == Ok("image/png")
}

pub fn remote_account_acct_test() {
  let #(_, ctx, token) = setup()
  let id = remote_id(ctx)
  let res = get(ctx, token, "/api/v1/accounts/" <> int_to_string(id))
  assert res.status == 200
  assert str(res, ["acct"]) == "remote@r.example"
  assert str(res, ["id"]) == int_to_string(id)
}

fn int_to_string(n: Int) -> String {
  int.to_string(n)
}

pub fn lookup_remote_test() {
  let #(_, ctx, token) = setup()
  let res = get(ctx, token, "/api/v1/accounts/lookup?acct=remote@r.example")
  assert res.status == 200
  assert str(res, ["acct"]) == "remote@r.example"
  let res = get(ctx, token, "/api/v1/accounts/lookup?acct=yudai")
  assert str(res, ["id"]) == "0"
  let res = get(ctx, token, "/api/v1/accounts/lookup?acct=nobody@r.example")
  assert res.status == 404
}

pub fn unknown_account_404_test() {
  let #(_, ctx, token) = setup()
  let res = get(ctx, token, "/api/v1/accounts/999")
  assert res.status == 404
  assert simulate.read_body(res) == "{\"error\":\"Record not found\"}"
  assert post(ctx, token, "/api/v1/accounts/999/follow").status == 404
  assert get(ctx, token, "/api/v1/accounts/abc").status == 404
}

// --- follow actions ---------------------------------------------------------------

pub fn follow_enqueues_follow_and_marks_requested_test() {
  let #(path, ctx, token) = setup()
  let id = remote_id(ctx)
  let res =
    post(ctx, token, "/api/v1/accounts/" <> int_to_string(id) <> "/follow")
  assert res.status == 200
  assert flag(res, ["requested"]) == True
  assert flag(res, ["following"]) == False
  let assert [#(inbox, body)] = deliveries(path)
  assert inbox == remote_uri <> "/inbox"
  assert field_of(body, "type") == "Follow"
  assert field_of(body, "object") == remote_uri
  assert field_of(body, "actor") == "https://ochoko.ynkt.me/me"
}

pub fn follow_twice_is_noop_test() {
  let #(path, ctx, token) = setup()
  let id = int_to_string(remote_id(ctx))
  let _ = post(ctx, token, "/api/v1/accounts/" <> id <> "/follow")
  let res = post(ctx, token, "/api/v1/accounts/" <> id <> "/follow")
  assert res.status == 200
  assert flag(res, ["requested"]) == True
  assert list.length(deliveries(path)) == 1
}

pub fn unfollow_enqueues_undo_with_original_follow_id_test() {
  let #(path, ctx, token) = setup()
  let id_int = remote_id(ctx)
  let id = int_to_string(id_int)
  let _ = post(ctx, token, "/api/v1/accounts/" <> id <> "/follow")
  let assert [#(_, follow_body)] = deliveries(path)
  let follow_id = field_of(follow_body, "id")
  let res = post(ctx, token, "/api/v1/accounts/" <> id <> "/unfollow")
  assert res.status == 200
  assert flag(res, ["requested"]) == False
  assert flag(res, ["following"]) == False
  let assert [_, #(inbox, body)] = deliveries(path)
  assert inbox == remote_uri <> "/inbox"
  assert field_of(body, "type") == "Undo"
  let assert Ok(inner_id) =
    json.parse(body, decode.at(["object", "id"], decode.string))
  assert inner_id == follow_id
  let assert Ok(inner_type) =
    json.parse(body, decode.at(["object", "type"], decode.string))
  assert inner_type == "Follow"
  let assert Ok(None) =
    db.with_connection(path, follows.is_following(_, id_int))
}

pub fn remove_from_followers_enqueues_reject_test() {
  let #(path, ctx, token) = setup()
  let id = remote_id(ctx)
  let assert Ok(Nil) =
    db.with_connection(path, follows.add_follower(
      _,
      id,
      "https://r.example/follows/1",
      ctx.now(),
    ))
  let res =
    post(
      ctx,
      token,
      "/api/v1/accounts/" <> int_to_string(id) <> "/remove_from_followers",
    )
  assert res.status == 200
  assert flag(res, ["followed_by"]) == False
  let assert [#(inbox, body)] = deliveries(path)
  assert inbox == remote_uri <> "/inbox"
  assert field_of(body, "type") == "Reject"
  let assert Ok(inner_id) =
    json.parse(body, decode.at(["object", "id"], decode.string))
  assert inner_id == "https://r.example/follows/1"
  let assert Ok(False) = db.with_connection(path, follows.is_follower(_, id))
}

pub fn relationships_followed_by_test() {
  let #(path, ctx, token) = setup()
  let id = remote_id(ctx)
  let assert Ok(Nil) =
    db.with_connection(path, follows.add_follower(
      _,
      id,
      "https://r.example/follows/1",
      ctx.now(),
    ))
  let res =
    get(
      ctx,
      token,
      "/api/v1/accounts/relationships?id[]=" <> int_to_string(id) <> "&id[]=999",
    )
  assert res.status == 200
  let assert Ok(rels) =
    json.parse(
      simulate.read_body(res),
      decode.list(decode.at(["followed_by"], decode.bool)),
    )
  assert rels == [True]
}

// --- statuses -----------------------------------------------------------------------

fn status_id(path: String, uri: String) -> Int {
  let assert Ok(Some(row)) =
    db.with_connection(path, statuses.get_by_uri(_, uri))
  row.id
}

pub fn account_statuses_paginates_test() {
  let #(path, ctx, token) = setup()
  let id = remote_id(ctx)
  let uris = [
    "https://r.example/n/1",
    "https://r.example/n/2",
    "https://r.example/n/3",
  ]
  let assert Ok(Nil) =
    db.with_connection(path, fn(conn) { insert_notes(conn, id, ctx, uris) })
  let id1 = status_id(path, "https://r.example/n/1")
  let id2 = status_id(path, "https://r.example/n/2")
  let id3 = status_id(path, "https://r.example/n/3")
  let base = "/api/v1/accounts/" <> int_to_string(id) <> "/statuses"
  let res = get(ctx, token, base <> "?limit=1")
  assert res.status == 200
  assert strings(res, "uri") == ["https://r.example/n/3"]
  let link_base =
    "https://ochoko.ynkt.me/api/v1/accounts/"
    <> int_to_string(id)
    <> "/statuses?limit=1"
  assert list.key_find(res.headers, "link")
    == Ok(
      "<"
      <> link_base
      <> "&max_id="
      <> int_to_string(id3)
      <> ">; rel=\"next\", <"
      <> link_base
      <> "&min_id="
      <> int_to_string(id3)
      <> ">; rel=\"prev\"",
    )
  // Following `next` yields the next older status.
  let res = get(ctx, token, base <> "?limit=1&max_id=" <> int_to_string(id3))
  assert strings(res, "uri") == ["https://r.example/n/2"]
  // `min_id` pages forward from the cursor.
  let res = get(ctx, token, base <> "?limit=1&min_id=" <> int_to_string(id1))
  assert strings(res, "uri") == ["https://r.example/n/2"]
  let res = get(ctx, token, base <> "?since_id=" <> int_to_string(id2))
  assert strings(res, "uri") == ["https://r.example/n/3"]
  let res = get(ctx, token, base)
  assert strings(res, "uri")
    == [
      "https://r.example/n/3",
      "https://r.example/n/2",
      "https://r.example/n/1",
    ]
  // An empty page has no Link header.
  let res = get(ctx, token, base <> "?max_id=" <> int_to_string(id1))
  assert strings(res, "uri") == []
  assert list.key_find(res.headers, "link") == Error(Nil)
  let res = get(ctx, token, "/api/v1/accounts/0/statuses")
  assert strings(res, "uri") == []
}

pub fn followers_and_following_test() {
  let #(path, ctx, token) = setup()
  let id = remote_id(ctx)
  let remote = "/api/v1/accounts/" <> int_to_string(id)
  assert strings(get(ctx, token, "/api/v1/accounts/0/followers"), "acct") == []
  assert strings(get(ctx, token, "/api/v1/accounts/0/following"), "acct") == []
  let assert Ok(Nil) =
    db.with_connection(path, fn(conn) {
      let assert Ok(Nil) =
        follows.add_follower(conn, id, "https://r.example/f/1", ctx.now())
      follows.add_following(conn, id, "https://r.example/f/2", ctx.now())
    })
  assert strings(get(ctx, token, "/api/v1/accounts/0/followers"), "acct")
    == ["remote@r.example"]
  assert strings(get(ctx, token, "/api/v1/accounts/0/following"), "acct")
    == ["remote@r.example"]
  assert strings(get(ctx, token, remote <> "/followers"), "acct") == []
  assert strings(get(ctx, token, remote <> "/following"), "acct") == []
}

pub fn requests_without_token_are_401_test() {
  let #(_, ctx, _) = setup()
  let id = int_to_string(remote_id(ctx))
  let anon = fn(method, path) {
    router.handle_request(simulate.request(method, path), ctx).status
  }
  assert anon(http.Post, "/api/v1/accounts/" <> id <> "/follow") == 401
  assert anon(http.Post, "/api/v1/accounts/" <> id <> "/unfollow") == 401
  assert anon(http.Get, "/api/v1/accounts/relationships?id[]=" <> id) == 401
  assert anon(http.Get, "/api/v2/search?q=a") == 401
  assert anon(http.Get, "/api/v1/accounts/" <> id) == 401
}

pub fn relationship_pending_then_accepted_test() {
  let #(path, ctx, token) = setup()
  let id = remote_id(ctx)
  let url = "/api/v1/accounts/relationships?id[]=" <> int_to_string(id)
  let _ =
    post(ctx, token, "/api/v1/accounts/" <> int_to_string(id) <> "/follow")
  let rel = fn() {
    let assert Ok(v) =
      json.parse(
        simulate.read_body(get(ctx, token, url)),
        decode.list({
          use requested <- decode.field("requested", decode.bool)
          use following <- decode.field("following", decode.bool)
          decode.success(#(requested, following))
        }),
      )
    v
  }
  assert rel() == [#(True, False)]
  let assert Ok(Nil) =
    db.with_connection(path, follows.set_following_accepted(_, id))
  assert rel() == [#(False, True)]
}

pub fn unfollow_when_not_following_is_noop_test() {
  let #(path, ctx, token) = setup()
  let id = int_to_string(remote_id(ctx))
  let res = post(ctx, token, "/api/v1/accounts/" <> id <> "/unfollow")
  assert res.status == 200
  assert flag(res, ["following"]) == False
  assert deliveries(path) == []
}

pub fn placeholder_images_test() {
  let #(_, ctx, token) = setup()
  let id = int_to_string(remote_id(ctx))
  let res = get(ctx, token, "/api/v1/accounts/" <> id)
  assert str(res, ["avatar"]) == "https://ochoko.ynkt.me/static/avatar.png"
  assert str(res, ["avatar_static"])
    == "https://ochoko.ynkt.me/static/avatar.png"
  assert str(res, ["header"]) == "https://ochoko.ynkt.me/static/header.png"
  let res = get(ctx, token, "/api/v1/accounts/0")
  assert str(res, ["header_static"])
    == "https://ochoko.ynkt.me/static/header.png"
  let res =
    router.handle_request(simulate.request(http.Get, "/static/header.png"), ctx)
  assert res.status == 200
}

pub fn lookup_local_is_case_insensitive_test() {
  let #(_, ctx, token) = setup()
  let res = get(ctx, token, "/api/v1/accounts/lookup?acct=Yudai")
  assert str(res, ["id"]) == "0"
}

fn insert_notes(
  conn: sqlight.Connection,
  actor_id: Int,
  ctx: Context,
  uris: List(String),
) -> Result(Nil, sqlight.Error) {
  list.index_map(uris, fn(uri, i) {
    statuses.insert_remote(
      conn,
      actor_id,
      note_for(uri, i),
      mastodon.Public,
      ctx.now(),
    )
  })
  |> list.try_each(fn(r) { r })
}

fn note_for(uri: String, i: Int) -> note.InboundNote {
  note.InboundNote(
    uri:,
    attributed_to: remote_uri,
    content_html: "<p>hi</p>",
    spoiler_text: "",
    sensitive: False,
    url: None,
    in_reply_to: None,
    language: None,
    published: Some(timestamp.from_unix_seconds(1_600_000_000 + i)),
    to: [],
    cc: [],
    attachments: [],
  )
}

// --- search -----------------------------------------------------------------------

pub fn search_resolve_acct_test() {
  let #(_, ctx, token) = setup()
  let res = get(ctx, token, "/api/v2/search?q=remote@r.example&resolve=true")
  assert res.status == 200
  assert strings_at(res, "accounts", "acct") == ["remote@r.example"]
  assert strings_at(res, "statuses", "id") == []
}

pub fn search_with_leading_at_test() {
  let #(_, ctx, token) = setup()
  let res =
    get(ctx, token, "/api/v2/search?q=%40remote%40r.example&resolve=true")
  assert strings_at(res, "accounts", "acct") == ["remote@r.example"]
}

pub fn search_resolve_url_test() {
  let #(_, ctx, token) = setup()
  let res =
    get(ctx, token, "/api/v2/search?resolve=true&q=" <> uri_encode(remote_uri))
  assert strings_at(res, "accounts", "acct") == ["remote@r.example"]
}

pub fn search_without_resolve_uses_cache_test() {
  let #(_, ctx, token) = setup()
  let res = get(ctx, token, "/api/v2/search?q=rem")
  assert strings_at(res, "accounts", "acct") == []
  let _ = remote_id(ctx)
  let res = get(ctx, token, "/api/v2/search?q=rem")
  assert strings_at(res, "accounts", "acct") == ["remote@r.example"]
  let res = get(ctx, token, "/api/v2/search?q=remote@r.example")
  assert strings_at(res, "accounts", "acct") == ["remote@r.example"]
}

pub fn search_unresolvable_returns_empty_test() {
  let #(_, ctx, token) = setup()
  let res =
    get(ctx, token, "/api/v2/search?q=ghost@nowhere.example&resolve=true")
  assert res.status == 200
  assert strings_at(res, "accounts", "acct") == []
  assert strings_at(res, "hashtags", "name") == []
}

fn strings_at(res: wisp.Response, key: String, field: String) -> List(String) {
  let assert Ok(v) =
    json.parse(
      simulate.read_body(res),
      decode.at([key], decode.list(decode.at([field], decode.string))),
    )
  v
}

@external(erlang, "uri_string", "quote")
fn uri_encode(s: String) -> String
