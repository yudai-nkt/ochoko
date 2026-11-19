import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import ochoko/context.{type Context}
import ochoko/db
import ochoko/federation/note
import ochoko/federation/remote_actor
import ochoko/store/follows
import ochoko/store/statuses
import ochoko/web/router
import ochoko_shared/mastodon
import sqlight
import support
import wisp
import wisp/simulate

const remote_uri = "https://r.example/users/remote"

const public_uri = "https://www.w3.org/ns/activitystreams#Public"

const followers_uri = "https://ochoko.ynkt.me/me/followers"

fn setup() -> #(String, Context, String) {
  let path = support.temp_db_path()
  let ctx =
    support.test_context_with_send(
      path,
      support.fake_send([
        #(
          remote_uri,
          support.json_response(support.remote_actor_json(
            remote_uri,
            support.remote_key(),
          )),
        ),
      ]),
    )
  #(path, ctx, support.user_token(ctx))
}

fn with_follower(path: String, ctx: Context) -> Int {
  let assert Ok(a) = remote_actor.get_or_fetch(ctx, remote_uri)
  let assert Ok(Nil) =
    db.with_connection(path, follows.add_follower(
      _,
      a.id,
      "https://r.example/follows/1",
      ctx.now(),
    ))
  a.id
}

fn send(
  ctx: Context,
  token: String,
  method: http.Method,
  path: String,
  body: String,
  headers: List(#(String, String)),
) -> wisp.Response {
  let req =
    simulate.request(method, path)
    |> request.set_header("authorization", "Bearer " <> token)
    |> simulate.string_body(body)
    |> request.set_header("content-type", "application/json")
  router.handle_request(
    list.fold(headers, req, fn(r, h) { request.set_header(r, h.0, h.1) }),
    ctx,
  )
}

fn post_json(ctx: Context, token: String, body: String) -> wisp.Response {
  send(ctx, token, http.Post, "/api/v1/statuses", body, [])
}

fn post_text(ctx: Context, token: String, text: String) -> wisp.Response {
  post_json(
    ctx,
    token,
    json.to_string(json.object([#("status", json.string(text))])),
  )
}

fn str(res: wisp.Response, path: List(String)) -> String {
  let assert Ok(v) =
    json.parse(simulate.read_body(res), decode.at(path, decode.string))
  v
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

fn body_str(body: String, path: List(String)) -> String {
  let assert Ok(v) = json.parse(body, decode.at(path, decode.string))
  v
}

fn body_strs(body: String, path: List(String)) -> List(String) {
  let assert Ok(v) =
    json.parse(body, decode.at(path, decode.list(decode.string)))
  v
}

pub fn post_public_status_test() {
  let #(path, ctx, token) = setup()
  let _ = with_follower(path, ctx)
  let res = post_text(ctx, token, "hello")
  assert res.status == 200
  assert str(res, ["visibility"]) == "public"
  assert str(res, ["content"]) == "<p>hello</p>"
  assert str(res, ["account", "acct"]) == "yudai"
  let id = str(res, ["id"])
  assert str(res, ["uri"]) == "https://ochoko.ynkt.me/statuses/" <> id
  let assert [#(inbox, body)] = deliveries(path)
  assert inbox == "https://r.example/inbox"
  assert body_str(body, ["type"]) == "Create"
  assert body_str(body, ["id"])
    == "https://ochoko.ynkt.me/statuses/" <> id <> "/activity"
  assert body_str(body, ["object", "type"]) == "Note"
  assert body_str(body, ["object", "content"]) == "<p>hello</p>"
  assert body_str(body, ["object", "attributedTo"])
    == "https://ochoko.ynkt.me/me"
  assert body_strs(body, ["to"]) == [public_uri]
  assert body_strs(body, ["cc"]) == [followers_uri]
}

pub fn post_unlisted_addressing_test() {
  let #(path, ctx, token) = setup()
  let _ = with_follower(path, ctx)
  let res =
    post_json(ctx, token, "{\"status\":\"hi\",\"visibility\":\"unlisted\"}")
  assert res.status == 200
  assert str(res, ["visibility"]) == "unlisted"
  let assert [#(_, body)] = deliveries(path)
  assert body_strs(body, ["to"]) == [followers_uri]
  assert body_strs(body, ["cc"]) == [public_uri]
  assert body_strs(body, ["object", "to"]) == [followers_uri]
  assert body_strs(body, ["object", "cc"]) == [public_uri]
}

pub fn post_private_422_test() {
  let #(_, ctx, token) = setup()
  let res =
    post_json(ctx, token, "{\"status\":\"hi\",\"visibility\":\"private\"}")
  assert res.status == 422
}

pub fn post_direct_422_test() {
  let #(_, ctx, token) = setup()
  let res =
    post_json(ctx, token, "{\"status\":\"hi\",\"visibility\":\"direct\"}")
  assert res.status == 422
}

pub fn post_reply_422_test() {
  let #(_, ctx, token) = setup()
  let res =
    post_json(ctx, token, "{\"status\":\"hi\",\"in_reply_to_id\":\"1\"}")
  assert res.status == 422
}

pub fn post_media_422_test() {
  let #(_, ctx, token) = setup()
  let res = post_json(ctx, token, "{\"status\":\"hi\",\"media_ids\":[\"1\"]}")
  assert res.status == 422
}

pub fn post_poll_422_test() {
  let #(_, ctx, token) = setup()
  let res =
    post_json(
      ctx,
      token,
      "{\"status\":\"hi\",\"poll\":{\"options\":[\"a\",\"b\"],\"expires_in\":600}}",
    )
  assert res.status == 422
}

pub fn post_empty_422_test() {
  let #(path, ctx, token) = setup()
  assert post_text(ctx, token, "  \n ").status == 422
  assert post_json(ctx, token, "{}").status == 422
  assert deliveries(path) == []
}

pub fn post_too_long_422_test() {
  let #(_, ctx, token) = setup()
  assert post_text(ctx, token, string_of("a", 501)).status == 422
  assert post_text(ctx, token, string_of("a", 500)).status == 200
}

pub fn post_counts_graphemes_test() {
  let #(_, ctx, token) = setup()
  // 500 family emoji are 500 graphemes but many more code points.
  let family = "👨‍👩‍👧"
  assert post_text(ctx, token, string_of(family, 500)).status == 200
  assert post_text(ctx, token, string_of(family, 501)).status == 422
}

fn string_of(s: String, n: Int) -> String {
  list.repeat(s, n) |> list.fold("", fn(acc, x) { acc <> x })
}

pub fn post_sensitive_spoiler_language_test() {
  let #(_, ctx, token) = setup()
  let res =
    post_json(
      ctx,
      token,
      "{\"status\":\"hi\",\"sensitive\":true,\"spoiler_text\":\"cw\",\"language\":\"ja\"}",
    )
  assert res.status == 200
  assert str(res, ["spoiler_text"]) == "cw"
  assert str(res, ["language"]) == "ja"
  let assert Ok(True) =
    json.parse(simulate.read_body(res), decode.at(["sensitive"], decode.bool))
}

pub fn post_requires_auth_test() {
  let #(_, ctx, _) = setup()
  let res =
    router.handle_request(
      simulate.request(http.Post, "/api/v1/statuses")
        |> simulate.string_body("{\"status\":\"x\"}"),
      ctx,
    )
  assert res.status == 401
}

pub fn idempotency_key_returns_same_status_test() {
  let #(path, ctx, token) = setup()
  let _ = with_follower(path, ctx)
  let post = fn(key) {
    send(ctx, token, http.Post, "/api/v1/statuses", "{\"status\":\"once\"}", [
      #("idempotency-key", key),
    ])
  }
  let first = post("k1")
  let second = post("k1")
  assert first.status == 200
  assert second.status == 200
  assert str(first, ["id"]) == str(second, ["id"])
  assert list.length(deliveries(path)) == 1
  let third = post("k2")
  assert str(third, ["id"]) != str(first, ["id"])
}

pub fn idempotency_key_expires_test() {
  let #(_, ctx, token) = setup()
  let post = fn(ctx: Context) {
    send(ctx, token, http.Post, "/api/v1/statuses", "{\"status\":\"x\"}", [
      #("idempotency-key", "k"),
    ])
  }
  let first = post(ctx)
  let later =
    context.Context(..ctx, now: fn() {
      timestamp.add(ctx.now(), duration.seconds(3601))
    })
  let second = post(later)
  assert str(first, ["id"]) != str(second, ["id"])
}

pub fn post_without_followers_enqueues_nothing_test() {
  let #(path, ctx, token) = setup()
  assert post_text(ctx, token, "alone").status == 200
  assert deliveries(path) == []
}

pub fn get_status_test() {
  let #(_, ctx, token) = setup()
  let id = str(post_text(ctx, token, "hello"), ["id"])
  let res = send(ctx, token, http.Get, "/api/v1/statuses/" <> id, "", [])
  assert res.status == 200
  assert str(res, ["id"]) == id
  assert send(ctx, token, http.Get, "/api/v1/statuses/999", "", []).status
    == 404
  assert send(ctx, token, http.Get, "/api/v1/statuses/abc", "", []).status
    == 404
}

pub fn delete_own_status_test() {
  let #(path, ctx, token) = setup()
  let _ = with_follower(path, ctx)
  let id = str(post_text(ctx, token, "bye"), ["id"])
  let res = send(ctx, token, http.Delete, "/api/v1/statuses/" <> id, "", [])
  assert res.status == 200
  assert str(res, ["text"]) == "bye"
  assert str(res, ["id"]) == id
  let assert [_, #(inbox, body)] = deliveries(path)
  assert inbox == "https://r.example/inbox"
  assert body_str(body, ["type"]) == "Delete"
  assert body_str(body, ["object", "type"]) == "Tombstone"
  assert body_str(body, ["object", "id"])
    == "https://ochoko.ynkt.me/statuses/" <> id
  assert body_strs(body, ["to"]) == [public_uri]
  // Gone from the API afterwards, and a second delete is a 404.
  assert send(ctx, token, http.Get, "/api/v1/statuses/" <> id, "", []).status
    == 404
  assert send(ctx, token, http.Delete, "/api/v1/statuses/" <> id, "", []).status
    == 404
  assert list.length(deliveries(path)) == 2
}

fn remote_status_id(path: String, ctx: Context) -> Int {
  let actor = with_follower(path, ctx)
  let n =
    note.InboundNote(
      uri: "https://r.example/notes/1",
      attributed_to: remote_uri,
      content_html: "<p>x</p>",
      spoiler_text: "",
      sensitive: False,
      url: None,
      in_reply_to: None,
      language: None,
      published: Some(timestamp.from_unix_seconds(1_699_000_000)),
      to: [],
      cc: [],
      attachments: [],
    )
  let assert Ok(Nil) =
    db.with_connection(path, statuses.insert_remote(
      _,
      actor,
      n,
      mastodon.Public,
      ctx.now(),
    ))
  let assert Ok(Some(row)) =
    db.with_connection(path, statuses.get_by_uri(_, n.uri))
  row.id
}

pub fn delete_remote_status_404_test() {
  let #(path, ctx, token) = setup()
  let id = int.to_string(remote_status_id(path, ctx))
  // Remote statuses can be read...
  assert send(ctx, token, http.Get, "/api/v1/statuses/" <> id, "", []).status
    == 200
  // ...but not deleted.
  let res = send(ctx, token, http.Delete, "/api/v1/statuses/" <> id, "", [])
  assert res.status == 404
  assert deliveries(path) == []
}

pub fn get_note_json_test() {
  let #(_, ctx, token) = setup()
  let id = str(post_text(ctx, token, "hello"), ["id"])
  let res =
    router.handle_request(simulate.request(http.Get, "/statuses/" <> id), ctx)
  assert res.status == 200
  assert list.key_find(res.headers, "content-type")
    == Ok("application/activity+json; charset=utf-8")
  let body = simulate.read_body(res)
  assert body_str(body, ["type"]) == "Note"
  assert body_str(body, ["id"]) == "https://ochoko.ynkt.me/statuses/" <> id
  assert body_str(body, ["content"]) == "<p>hello</p>"
  assert body_str(body, ["url"]) == "https://ochoko.ynkt.me/statuses/" <> id
  assert body_strs(body, ["to"]) == [public_uri]
  assert body_str(body, ["published"]) == "2023-11-14T22:13:20Z"
}

pub fn get_deleted_note_410_test() {
  let #(_, ctx, token) = setup()
  let id = str(post_text(ctx, token, "hello"), ["id"])
  let _ = send(ctx, token, http.Delete, "/api/v1/statuses/" <> id, "", [])
  let res =
    router.handle_request(simulate.request(http.Get, "/statuses/" <> id), ctx)
  assert res.status == 410
}

pub fn get_remote_or_unknown_note_404_test() {
  let #(path, ctx, _) = setup()
  let id = int.to_string(remote_status_id(path, ctx))
  assert router.handle_request(
      simulate.request(http.Get, "/statuses/" <> id),
      ctx,
    ).status
    == 404
  assert router.handle_request(simulate.request(http.Get, "/statuses/1"), ctx).status
    == 404
}

pub fn context_is_empty_test() {
  let #(_, ctx, token) = setup()
  let id = str(post_text(ctx, token, "hello"), ["id"])
  let res =
    send(ctx, token, http.Get, "/api/v1/statuses/" <> id <> "/context", "", [])
  assert res.status == 200
  let body = simulate.read_body(res)
  assert body_strs(body, ["ancestors"]) == []
  assert body_strs(body, ["descendants"]) == []
}
