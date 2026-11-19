import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import ochoko/context.{type Context, Context}
import ochoko/db
import ochoko/federation/inbox
import ochoko/federation/remote_actor
import ochoko/store/follows
import ochoko/store/statuses
import ochoko/web/router
import ochoko_shared/mastodon
import sqlight
import support
import wisp
import wisp/simulate

const actor_a = "https://r.example/users/a"

const actor_b = "https://r.example/users/b"

const us = "https://ochoko.ynkt.me/me"

fn key_a() {
  support.remote_key()
}

fn routes() {
  [
    #(
      actor_a,
      support.json_response(support.remote_actor_json(actor_a, key_a())),
    ),
    #(
      actor_b,
      support.json_response(support.remote_actor_json(actor_b, key_a())),
    ),
  ]
}

fn setup() -> #(String, Context) {
  let path = support.temp_db_path()
  #(path, support.test_context_with_send(path, support.fake_send(routes())))
}

fn activity(id: String, type_: String, actor: String, object: json.Json) {
  json.object([
    #("id", json.string(id)),
    #("type", json.string(type_)),
    #("actor", json.string(actor)),
    #("object", object),
  ])
  |> json.to_string
}

fn follow(id: String, actor: String) -> String {
  activity(id, "Follow", actor, json.string(us))
}

fn embedded_follow(id: String, actor: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("type", json.string("Follow")),
    #("actor", json.string(actor)),
    #("object", json.string(us)),
  ])
}

fn post(ctx: Context, actor: String, body: String) -> wisp.Response {
  inbox.handle(
    ctx,
    support.signed_post(ctx, key_a(), actor <> "#main-key", "/me/inbox", body),
  )
}

fn count(path: String, sql: String) -> Int {
  let assert Ok([n]) =
    db.with_connection(path, fn(conn) {
      sqlight.query(
        sql,
        on: conn,
        with: [],
        expecting: decode.at([0], decode.int),
      )
    })
  n
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

fn actor_row_id(ctx: Context, uri: String) -> Int {
  let assert Ok(a) = remote_actor.get_or_fetch(ctx, uri)
  a.id
}

fn status(res: wisp.Response) -> Int {
  res.status
}

// --- authentication ----------------------------------------------------------

pub fn unsigned_401_test() {
  let #(_, ctx) = setup()
  let req =
    simulate.request(http.Post, "/me/inbox")
    |> simulate.string_body(follow("https://r.example/f/1", actor_a))
  assert status(inbox.handle(ctx, req)) == 401
}

pub fn bad_signature_401_test() {
  let #(path, ctx) = setup()
  // Signed with the server's own key, which is not actor A's.
  let req =
    support.signed_post(
      ctx,
      support.test_key(),
      actor_a <> "#main-key",
      "/me/inbox",
      follow("https://r.example/f/1", actor_a),
    )
  assert status(inbox.handle(ctx, req)) == 401
  assert count(path, "SELECT COUNT(*) FROM followers") == 0
}

pub fn stale_date_401_test() {
  let #(_, ctx) = setup()
  let old =
    Context(..ctx, now: fn() {
      timestamp.from_unix_seconds(1_700_000_000 - 86_400)
    })
  let req =
    support.signed_post(
      old,
      key_a(),
      actor_a <> "#main-key",
      "/me/inbox",
      follow("https://r.example/f/1", actor_a),
    )
  assert status(inbox.handle(ctx, req)) == 401
}

pub fn digest_mismatch_401_test() {
  let #(_, ctx) = setup()
  let signed =
    support.signed_post(
      ctx,
      key_a(),
      actor_a <> "#main-key",
      "/me/inbox",
      follow("https://r.example/f/1", actor_a),
    )
  // Same headers, different body.
  let tampered =
    request.set_body(
      signed,
      simulate.string_body(
        simulate.request(http.Post, "/me/inbox"),
        follow("https://r.example/f/evil", actor_a),
      ).body,
    )
  assert status(inbox.handle(ctx, tampered)) == 401
}

pub fn actor_mismatch_401_test() {
  let #(path, ctx) = setup()
  let req =
    support.signed_post(
      ctx,
      key_a(),
      actor_a <> "#main-key",
      "/me/inbox",
      follow("https://r.example/f/1", actor_b),
    )
  assert status(inbox.handle(ctx, req)) == 401
  assert count(path, "SELECT COUNT(*) FROM followers") == 0
}

pub fn malformed_body_400_test() {
  let #(_, ctx) = setup()
  assert status(post(ctx, actor_a, "{\"hello\": 1}")) == 400
}

pub fn key_rotation_refetches_once_test() {
  let path = support.temp_db_path()
  // Seed the cache with actor A holding the old key (the server's test key).
  let old_ctx =
    support.test_context_with_send(
      path,
      support.fake_send([
        #(
          actor_a,
          support.json_response(support.remote_actor_json(
            actor_a,
            support.test_key(),
          )),
        ),
      ]),
    )
  let assert Ok(_) = remote_actor.get_or_fetch(old_ctx, actor_a)
  let #(send, fetched) =
    support.recording_send(
      support.fake_send([
        #(
          actor_a,
          support.json_response(support.remote_actor_json(actor_a, key_a())),
        ),
      ]),
    )
  let ctx = support.test_context_with_send(path, send)
  assert status(post(ctx, actor_a, follow("https://r.example/f/1", actor_a)))
    == 202
  assert list.length(fetched()) == 1
  assert count(path, "SELECT COUNT(*) FROM followers") == 1
}

pub fn delete_from_unfetchable_actor_202_test() {
  let path = support.temp_db_path()
  let gone = fn(_req) { Ok(response.new(410) |> response.set_body("")) }
  let ctx = support.test_context_with_send(path, gone)
  let body =
    activity("https://r.example/d/1", "Delete", actor_a, json.string(actor_a))
  assert status(post(ctx, actor_a, body)) == 202
  assert count(path, "SELECT COUNT(*) FROM processed_activities") == 0
  assert count(path, "SELECT COUNT(*) FROM remote_actors") == 0
}

pub fn unfetchable_non_delete_401_test() {
  let path = support.temp_db_path()
  let ctx =
    support.test_context_with_send(path, fn(_req) {
      Ok(response.new(410) |> response.set_body(""))
    })
  assert status(post(ctx, actor_a, follow("https://r.example/f/1", actor_a)))
    == 401
}

pub fn oversized_body_413_test() {
  let #(_, ctx) = setup()
  let big = string.repeat("x", 1_048_577)
  assert status(post(ctx, actor_a, big)) == 413
}

// --- follow lifecycle ----------------------------------------------------------

pub fn follow_creates_follower_accept_and_notification_test() {
  let #(path, ctx) = setup()
  assert status(post(ctx, actor_a, follow("https://r.example/f/1", actor_a)))
    == 202
  assert count(path, "SELECT COUNT(*) FROM followers") == 1
  assert count(path, "SELECT COUNT(*) FROM notifications") == 1
  let assert [#(inbox_url, body)] = deliveries(path)
  assert inbox_url == actor_a <> "/inbox"
  let assert Ok(#(type_, object_id)) =
    json.parse(body, {
      use type_ <- decode.field("type", decode.string)
      use object_id <- decode.subfield(["object", "id"], decode.string)
      decode.success(#(type_, object_id))
    })
  assert type_ == "Accept"
  assert object_id == "https://r.example/f/1"
  assert count(path, "SELECT COUNT(*) FROM processed_activities") == 1
}

pub fn follow_of_someone_else_is_ignored_test() {
  let #(path, ctx) = setup()
  let body =
    activity(
      "https://r.example/f/1",
      "Follow",
      actor_a,
      json.string("https://ochoko.ynkt.me/someone-else"),
    )
  assert status(post(ctx, actor_a, body)) == 202
  assert count(path, "SELECT COUNT(*) FROM followers") == 0
  assert deliveries(path) == []
}

pub fn duplicate_activity_is_ignored_test() {
  let #(path, ctx) = setup()
  let body = follow("https://r.example/f/1", actor_a)
  assert status(post(ctx, actor_a, body)) == 202
  assert status(post(ctx, actor_a, body)) == 202
  assert count(path, "SELECT COUNT(*) FROM notifications") == 1
  assert count(path, "SELECT COUNT(*) FROM deliveries") == 1
}

pub fn repeat_follow_with_new_id_reaccepts_test() {
  let #(path, ctx) = setup()
  assert status(post(ctx, actor_a, follow("https://r.example/f/1", actor_a)))
    == 202
  assert status(post(ctx, actor_a, follow("https://r.example/f/2", actor_a)))
    == 202
  assert count(path, "SELECT COUNT(*) FROM followers") == 1
  assert count(path, "SELECT COUNT(*) FROM notifications") == 1
  assert count(path, "SELECT COUNT(*) FROM deliveries") == 2
  assert count(
      path,
      "SELECT COUNT(*) FROM followers WHERE follow_uri = 'https://r.example/f/2'",
    )
    == 1
}

pub fn undo_follow_removes_follower_test() {
  let #(path, ctx) = setup()
  assert status(post(ctx, actor_a, follow("https://r.example/f/1", actor_a)))
    == 202
  let undo =
    activity(
      "https://r.example/u/1",
      "Undo",
      actor_a,
      embedded_follow("https://r.example/f/1", actor_a),
    )
  assert status(post(ctx, actor_a, undo)) == 202
  assert count(path, "SELECT COUNT(*) FROM followers") == 0
}

pub fn undo_by_other_actor_ignored_test() {
  let #(path, ctx) = setup()
  assert status(post(ctx, actor_a, follow("https://r.example/f/1", actor_a)))
    == 202
  let undo =
    activity(
      "https://r.example/u/1",
      "Undo",
      actor_b,
      embedded_follow("https://r.example/f/1", actor_a),
    )
  assert status(post(ctx, actor_b, undo)) == 202
  assert count(path, "SELECT COUNT(*) FROM followers") == 1
}

pub fn undo_of_non_follow_keeps_follower_test() {
  let #(path, ctx) = setup()
  assert status(post(ctx, actor_a, follow("https://r.example/f/1", actor_a)))
    == 202
  let undo =
    activity(
      "https://r.example/u/1",
      "Undo",
      actor_a,
      json.string("https://r.example/likes/1"),
    )
  assert status(post(ctx, actor_a, undo)) == 202
  assert count(path, "SELECT COUNT(*) FROM followers") == 1
}

pub fn accept_marks_following_accepted_test() {
  let #(path, ctx) = setup()
  let id = actor_row_id(ctx, actor_a)
  let assert Ok(Nil) =
    db.with_connection(path, follows.add_following(
      _,
      id,
      "https://ochoko.ynkt.me/activities/9",
      ctx.now(),
    ))
  let accept =
    activity(
      "https://r.example/a/1",
      "Accept",
      actor_a,
      json.string("https://ochoko.ynkt.me/activities/9"),
    )
  assert status(post(ctx, actor_a, accept)) == 202
  assert count(path, "SELECT COUNT(*) FROM following WHERE state = 'accepted'")
    == 1
}

pub fn reject_removes_following_test() {
  let #(path, ctx) = setup()
  let id = actor_row_id(ctx, actor_a)
  let assert Ok(Nil) =
    db.with_connection(path, follows.add_following(
      _,
      id,
      "https://ochoko.ynkt.me/activities/9",
      ctx.now(),
    ))
  let reject =
    activity(
      "https://r.example/r/1",
      "Reject",
      actor_a,
      embedded_follow("https://ochoko.ynkt.me/activities/9", us),
    )
  assert status(post(ctx, actor_a, reject)) == 202
  assert count(path, "SELECT COUNT(*) FROM following") == 0
}

pub fn shared_inbox_route_test() {
  // Both inbox paths are routed to the handler (401 = reached it, unsigned).
  let #(_, ctx) = setup()
  let res = router.handle_request(simulate.request(http.Post, "/inbox"), ctx)
  assert status(res) == 401
  let res = router.handle_request(simulate.request(http.Post, "/me/inbox"), ctx)
  assert status(res) == 401
}

// --- notes and deletes ---------------------------------------------------------

const public = "https://www.w3.org/ns/activitystreams#Public"

fn note_json(
  id: String,
  attributed_to: String,
  to: List(String),
  published: String,
) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("type", json.string("Note")),
    #("attributedTo", json.string(attributed_to)),
    #("content", json.string("<p>hello</p>")),
    #("published", json.string(published)),
    #("to", json.array(to, json.string)),
    #("cc", json.array([], json.string)),
    #("attachment", json.array([], json.string)),
  ])
}

fn note_a(id: String) -> json.Json {
  note_json(id, actor_a, [public], "2023-11-14T00:00:00Z")
}

fn create(id: String, actor: String, object: json.Json) -> String {
  activity(id, "Create", actor, object)
}

fn follow_accepted(path: String, ctx: Context, actor: String) -> Int {
  let id = actor_row_id(ctx, actor)
  let assert Ok(Nil) =
    db.with_connection(path, fn(conn) {
      use _ <- result.try(follows.add_following(
        conn,
        id,
        "https://ochoko.ynkt.me/activities/9",
        ctx.now(),
      ))
      follows.set_following_accepted(conn, id)
    })
  id
}

fn get_status(path: String, uri: String) {
  let assert Ok(row) = db.with_connection(path, statuses.get_by_uri(_, uri))
  row
}

const n1 = "https://r.example/users/a/statuses/1"

pub fn create_from_followed_stored_test() {
  let #(path, ctx) = setup()
  let id = follow_accepted(path, ctx, actor_a)
  let body = create("https://r.example/c/1", actor_a, note_a(n1))
  assert status(post(ctx, actor_a, body)) == 202
  let assert Some(row) = get_status(path, n1)
  assert row.actor_id == Some(id)
  assert row.content_html == "<p>hello</p>"
  assert row.visibility == mastodon.Public
}

pub fn create_from_unfollowed_ignored_test() {
  let #(path, ctx) = setup()
  let body = create("https://r.example/c/1", actor_a, note_a(n1))
  assert status(post(ctx, actor_a, body)) == 202
  assert get_status(path, n1) == None
}

pub fn create_with_pending_follow_ignored_test() {
  let #(path, ctx) = setup()
  let id = actor_row_id(ctx, actor_a)
  let assert Ok(Nil) =
    db.with_connection(path, follows.add_following(
      _,
      id,
      "https://ochoko.ynkt.me/activities/9",
      ctx.now(),
    ))
  let body = create("https://r.example/c/1", actor_a, note_a(n1))
  assert status(post(ctx, actor_a, body)) == 202
  assert get_status(path, n1) == None
}

pub fn create_attributed_to_other_ignored_test() {
  let #(path, ctx) = setup()
  let _ = follow_accepted(path, ctx, actor_a)
  let body =
    create(
      "https://r.example/c/1",
      actor_a,
      note_json(n1, actor_b, [public], "2023-11-14T00:00:00Z"),
    )
  assert status(post(ctx, actor_a, body)) == 202
  assert get_status(path, n1) == None
}

pub fn create_with_iri_object_fetches_note_test() {
  let #(path, ctx) = setup()
  let #(send, requests) =
    support.recording_send(
      support.fake_send([
        #(n1, support.json_response(json.to_string(note_a(n1)))),
        ..routes()
      ]),
    )
  let ctx = Context(..ctx, send:)
  let _ = follow_accepted(path, ctx, actor_a)
  let body = create("https://r.example/c/1", actor_a, json.string(n1))
  assert status(post(ctx, actor_a, body)) == 202
  assert option.is_some(get_status(path, n1))
  assert list.any(requests(), fn(r) { r.path == "/users/a/statuses/1" })
}

pub fn create_with_iri_object_from_unfollowed_not_fetched_test() {
  let #(path, ctx) = setup()
  let #(send, requests) =
    support.recording_send(
      support.fake_send([
        #(n1, support.json_response(json.to_string(note_a(n1)))),
        ..routes()
      ]),
    )
  let ctx = Context(..ctx, send:)
  let body = create("https://r.example/c/1", actor_a, json.string(n1))
  assert status(post(ctx, actor_a, body)) == 202
  assert get_status(path, n1) == None
  assert !list.any(requests(), fn(r) { r.path == "/users/a/statuses/1" })
}

pub fn create_with_iri_object_of_other_id_ignored_test() {
  let #(path, ctx) = setup()
  let other = "https://r.example/users/a/statuses/2"
  let ctx =
    Context(
      ..ctx,
      send: support.fake_send([
        #(n1, support.json_response(json.to_string(note_a(other)))),
        ..routes()
      ]),
    )
  let _ = follow_accepted(path, ctx, actor_a)
  let body = create("https://r.example/c/1", actor_a, json.string(n1))
  assert status(post(ctx, actor_a, body)) == 202
  assert get_status(path, n1) == None
  assert get_status(path, other) == None
}

pub fn duplicate_note_stored_once_test() {
  let #(path, ctx) = setup()
  let _ = follow_accepted(path, ctx, actor_a)
  assert status(post(
      ctx,
      actor_a,
      create("https://r.example/c/1", actor_a, note_a(n1)),
    ))
    == 202
  assert status(post(
      ctx,
      actor_a,
      create("https://r.example/c/2", actor_a, note_a(n1)),
    ))
    == 202
  assert count(path, "SELECT COUNT(*) FROM statuses") == 1
}

pub fn direct_note_stored_with_direct_visibility_test() {
  let #(path, ctx) = setup()
  let _ = follow_accepted(path, ctx, actor_a)
  let body =
    create(
      "https://r.example/c/1",
      actor_a,
      note_json(n1, actor_a, [us], "2023-11-14T00:00:00Z"),
    )
  assert status(post(ctx, actor_a, body)) == 202
  let assert Some(row) = get_status(path, n1)
  assert row.visibility == mastodon.Direct
}

pub fn future_published_is_clamped_test() {
  let #(path, ctx) = setup()
  let _ = follow_accepted(path, ctx, actor_a)
  let body =
    create(
      "https://r.example/c/1",
      actor_a,
      note_json(n1, actor_a, [public], "2099-01-01T00:00:00Z"),
    )
  assert status(post(ctx, actor_a, body)) == 202
  let assert Some(row) = get_status(path, n1)
  assert row.published_at == ctx.now()
}

pub fn delete_note_removes_status_test() {
  let #(path, ctx) = setup()
  let _ = follow_accepted(path, ctx, actor_a)
  let _ =
    post(ctx, actor_a, create("https://r.example/c/1", actor_a, note_a(n1)))
  let delete =
    activity("https://r.example/d/1", "Delete", actor_a, json.string(n1))
  assert status(post(ctx, actor_a, delete)) == 202
  assert get_status(path, n1) == None
}

pub fn delete_note_with_tombstone_removes_status_test() {
  let #(path, ctx) = setup()
  let _ = follow_accepted(path, ctx, actor_a)
  let _ =
    post(ctx, actor_a, create("https://r.example/c/1", actor_a, note_a(n1)))
  let tombstone =
    json.object([
      #("id", json.string(n1)),
      #("type", json.string("Tombstone")),
    ])
  let delete = activity("https://r.example/d/1", "Delete", actor_a, tombstone)
  assert status(post(ctx, actor_a, delete)) == 202
  assert get_status(path, n1) == None
}

pub fn delete_note_of_other_actor_ignored_test() {
  let #(path, ctx) = setup()
  let _ = follow_accepted(path, ctx, actor_a)
  let _ =
    post(ctx, actor_a, create("https://r.example/c/1", actor_a, note_a(n1)))
  let delete =
    activity("https://r.example/d/1", "Delete", actor_b, json.string(n1))
  assert status(post(ctx, actor_b, delete)) == 202
  assert option.is_some(get_status(path, n1))
}

pub fn delete_actor_cascades_test() {
  let #(path, ctx) = setup()
  let _ = follow_accepted(path, ctx, actor_a)
  let _ =
    post(ctx, actor_a, create("https://r.example/c/1", actor_a, note_a(n1)))
  let _ = post(ctx, actor_a, follow("https://r.example/f/1", actor_a))
  assert count(path, "SELECT COUNT(*) FROM statuses") == 1
  assert count(path, "SELECT COUNT(*) FROM followers") == 1
  assert count(path, "SELECT COUNT(*) FROM notifications") == 1
  let delete =
    activity("https://r.example/d/1", "Delete", actor_a, json.string(actor_a))
  assert status(post(ctx, actor_a, delete)) == 202
  assert count(path, "SELECT COUNT(*) FROM statuses") == 0
  assert count(path, "SELECT COUNT(*) FROM followers") == 0
  assert count(path, "SELECT COUNT(*) FROM following") == 0
  assert count(path, "SELECT COUNT(*) FROM notifications") == 0
  assert count(
      path,
      "SELECT COUNT(*) FROM remote_actors WHERE uri = '" <> actor_a <> "'",
    )
    == 0
}
