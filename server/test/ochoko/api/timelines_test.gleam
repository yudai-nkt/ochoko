import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/timestamp
import ochoko/api/stubs
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

fn routes() {
  [
    #(
      remote_uri,
      support.json_response(support.remote_actor_json(
        remote_uri,
        support.remote_key(),
      )),
    ),
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

fn remote_id(ctx: Context) -> Int {
  let assert Ok(a) = remote_actor.get_or_fetch(ctx, remote_uri)
  a.id
}

fn follow(path: String, actor_id: Int, accepted: Bool) -> Nil {
  let assert Ok(Nil) =
    db.with_connection(path, fn(conn) {
      use _ <- result.try(follows.add_following(
        conn,
        actor_id,
        "https://ochoko.ynkt.me/follows/1",
        timestamp.from_unix_seconds(1_700_000_000),
      ))
      case accepted {
        True -> follows.set_following_accepted(conn, actor_id)
        False -> Ok(Nil)
      }
    })
  Nil
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

fn remote_note(
  path: String,
  actor_id: Int,
  uri: String,
  i: Int,
  v: mastodon.Visibility,
) -> Nil {
  let assert Ok(Nil) =
    db.with_connection(path, statuses.insert_remote(
      _,
      actor_id,
      note_for(uri, i),
      v,
      timestamp.from_unix_seconds(1_700_000_000),
    ))
  Nil
}

fn own_note(path: String, ctx: Context, i: Int) -> Int {
  let assert Ok(row) =
    db.with_connection(path, fn(conn) {
      statuses.insert_own(
        conn,
        ctx.config,
        "own " <> int.to_string(i),
        "<p>own</p>",
        mastodon.Public,
        "",
        False,
        None,
        timestamp.from_unix_seconds(1_600_000_000 + i),
      )
    })
  row.id
}

fn uris(res: wisp.Response) -> List(String) {
  let assert Ok(v) =
    json.parse(
      simulate.read_body(res),
      decode.list(decode.at(["uri"], decode.string)),
    )
  v
}

fn ids(res: wisp.Response) -> List(String) {
  let assert Ok(v) =
    json.parse(
      simulate.read_body(res),
      decode.list(decode.at(["id"], decode.string)),
    )
  v
}

fn status_id(path: String, uri: String) -> Int {
  let assert Ok(Some(row)) =
    db.with_connection(path, statuses.get_by_uri(_, uri))
  row.id
}

fn n(uri: String) -> String {
  "https://r.example/n/" <> uri
}

// --- home timeline ---------------------------------------------------------

pub fn home_includes_own_and_followed_test() {
  let #(path, ctx, token) = setup()
  let rid = remote_id(ctx)
  follow(path, rid, True)
  remote_note(path, rid, n("1"), 1, mastodon.Public)
  remote_note(path, rid, n("2"), 3, mastodon.Private)
  remote_note(path, rid, n("3"), 4, mastodon.Unlisted)
  let own = own_note(path, ctx, 2)
  let res = get(ctx, token, "/api/v1/timelines/home")
  assert res.status == 200
  assert ids(res)
    == [
      int.to_string(status_id(path, n("3"))),
      int.to_string(status_id(path, n("2"))),
      int.to_string(own),
      int.to_string(status_id(path, n("1"))),
    ]
}

pub fn home_excludes_unfollowed_and_pending_test() {
  let #(path, ctx, token) = setup()
  let rid = remote_id(ctx)
  remote_note(path, rid, n("1"), 1, mastodon.Public)
  assert uris(get(ctx, token, "/api/v1/timelines/home")) == []
  follow(path, rid, False)
  assert uris(get(ctx, token, "/api/v1/timelines/home")) == []
  follow(path, rid, True)
  assert uris(get(ctx, token, "/api/v1/timelines/home")) == [n("1")]
}

pub fn home_excludes_direct_test() {
  let #(path, ctx, token) = setup()
  let rid = remote_id(ctx)
  follow(path, rid, True)
  remote_note(path, rid, n("1"), 1, mastodon.Direct)
  assert uris(get(ctx, token, "/api/v1/timelines/home")) == []
}

pub fn home_excludes_deleted_own_test() {
  let #(path, ctx, token) = setup()
  let own = own_note(path, ctx, 1)
  let _ = own_note(path, ctx, 2)
  let assert Ok(Nil) =
    db.with_connection(path, statuses.mark_deleted(_, own, ctx.now()))
  let res = get(ctx, token, "/api/v1/timelines/home")
  assert list.length(ids(res)) == 1
  assert !list.contains(ids(res), int.to_string(own))
}

fn three(path: String, ctx: Context) -> #(Int, Int, Int) {
  let rid = remote_id(ctx)
  follow(path, rid, True)
  remote_note(path, rid, n("1"), 1, mastodon.Public)
  remote_note(path, rid, n("2"), 2, mastodon.Public)
  remote_note(path, rid, n("3"), 3, mastodon.Public)
  #(status_id(path, n("1")), status_id(path, n("2")), status_id(path, n("3")))
}

pub fn home_max_id_test() {
  let #(path, ctx, token) = setup()
  let #(_, _, id3) = three(path, ctx)
  let res =
    get(ctx, token, "/api/v1/timelines/home?max_id=" <> int.to_string(id3))
  assert uris(res) == [n("2"), n("1")]
}

pub fn home_min_id_returns_closest_newer_test() {
  let #(path, ctx, token) = setup()
  let #(id1, _, _) = three(path, ctx)
  let res =
    get(
      ctx,
      token,
      "/api/v1/timelines/home?limit=1&min_id=" <> int.to_string(id1),
    )
  assert uris(res) == [n("2")]
}

pub fn home_since_id_test() {
  let #(path, ctx, token) = setup()
  let #(id1, _, _) = three(path, ctx)
  let res =
    get(
      ctx,
      token,
      "/api/v1/timelines/home?limit=1&since_id=" <> int.to_string(id1),
    )
  assert uris(res) == [n("3")]
}

pub fn home_link_header_test() {
  let #(path, ctx, token) = setup()
  let #(_, _, id3) = three(path, ctx)
  let res = get(ctx, token, "/api/v1/timelines/home?limit=1")
  let base = "https://ochoko.ynkt.me/api/v1/timelines/home?limit=1"
  let id = int.to_string(id3)
  assert list.key_find(res.headers, "link")
    == Ok(
      "<"
      <> base
      <> "&max_id="
      <> id
      <> ">; rel=\"next\", <"
      <> base
      <> "&min_id="
      <> id
      <> ">; rel=\"prev\"",
    )
}

pub fn home_requires_user_token_test() {
  let #(_, ctx, _) = setup()
  let res =
    router.handle_request(
      simulate.request(http.Get, "/api/v1/timelines/home"),
      ctx,
    )
  assert res.status == 401
}

// --- notifications -----------------------------------------------------------

fn add_notifications(path: String, rid: Int, count: Int) -> Nil {
  int.range(from: 1, to: count + 1, with: [], run: fn(acc, i) { [i, ..acc] })
  |> list.reverse
  |> list.each(fn(i) {
    let assert Ok(Nil) =
      db.with_connection(path, fn(conn) {
        sqlight.query(
          "INSERT INTO notifications (id, type, actor_id, activity_uri, created_at)
           VALUES (?, 'follow', ?, ?, 1700000000)",
          on: conn,
          with: [
            sqlight.int(i * 10),
            sqlight.int(rid),
            sqlight.text("https://r.example/f/" <> int.to_string(i)),
          ],
          expecting: decode.success(Nil),
        )
        |> result.replace(Nil)
      })
  })
}

fn field(res: wisp.Response, key: String) -> List(String) {
  let assert Ok(v) =
    json.parse(
      simulate.read_body(res),
      decode.list(decode.at([key], decode.string)),
    )
  v
}

pub fn notifications_list_test() {
  let #(path, ctx, token) = setup()
  let rid = remote_id(ctx)
  add_notifications(path, rid, 2)
  let res = get(ctx, token, "/api/v1/notifications")
  assert res.status == 200
  assert field(res, "id") == ["20", "10"]
  assert field(res, "type") == ["follow", "follow"]
  assert field(res, "group_key") == ["ungrouped-20", "ungrouped-10"]
  let res = get(ctx, token, "/api/v1/notifications?limit=1")
  assert field(res, "id") == ["20"]
  assert list.key_find(res.headers, "link")
    == Ok(
      "<https://ochoko.ynkt.me/api/v1/notifications?limit=1&max_id=20>; rel=\"next\", <https://ochoko.ynkt.me/api/v1/notifications?limit=1&min_id=20>; rel=\"prev\"",
    )
  let res = get(ctx, token, "/api/v1/notifications?max_id=20")
  assert field(res, "id") == ["10"]
  let res = get(ctx, token, "/api/v1/notifications?limit=1&min_id=10")
  assert field(res, "id") == ["20"]
  let res = get(ctx, token, "/api/v1/notifications/10")
  assert res.status == 200
  let assert Ok("10") =
    json.parse(simulate.read_body(res), decode.at(["id"], decode.string))
  assert get(ctx, token, "/api/v1/notifications/99").status == 404
}

pub fn notifications_exclude_follow_test() {
  let #(path, ctx, token) = setup()
  let rid = remote_id(ctx)
  add_notifications(path, rid, 1)
  let res = get(ctx, token, "/api/v1/notifications?exclude_types[]=follow")
  assert field(res, "id") == []
  let res = get(ctx, token, "/api/v1/notifications?exclude_types[]=mention")
  assert field(res, "id") == ["10"]
  let res = get(ctx, token, "/api/v1/notifications?types[]=mention")
  assert field(res, "id") == []
  let res = get(ctx, token, "/api/v1/notifications?types[]=follow")
  assert field(res, "id") == ["10"]
}

pub fn notifications_clear_test() {
  let #(path, ctx, token) = setup()
  let rid = remote_id(ctx)
  add_notifications(path, rid, 3)
  let res = call(ctx, token, http.Post, "/api/v1/notifications/10/dismiss")
  assert res.status == 200
  assert field(get(ctx, token, "/api/v1/notifications"), "id") == ["30", "20"]
  let res = call(ctx, token, http.Post, "/api/v1/notifications/clear")
  assert res.status == 200
  assert field(get(ctx, token, "/api/v1/notifications"), "id") == []
}

// --- stubs ---------------------------------------------------------------------

fn concrete(pattern: String) -> String {
  pattern
  |> stubs.fill("1")
}

pub fn stubs_return_valid_json_test() {
  let #(_, ctx, token) = setup()
  list.each(stubs.table, fn(stub) {
    let #(method, pattern, _) = stub
    let path = concrete(pattern)
    let res = call(ctx, token, method, path)
    let expected = case pattern {
      "/api/v1/push/subscription" -> 404
      _ -> 200
    }
    assert res.status == expected
    let assert Ok(_) = json.parse(simulate.read_body(res), decode.dynamic)
    // A stub requires a user token.
    let res = router.handle_request(simulate.request(method, path), ctx)
    assert res.status == 401
  })
}
