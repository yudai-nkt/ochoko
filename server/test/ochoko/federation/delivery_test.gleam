import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Post}
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/timestamp
import ochoko/db
import ochoko/federation/delivery
import ochoko/federation/remote_actor_types.{RemoteActor}
import ochoko/http_transport.{type Send}
import ochoko/signature
import ochoko/store/deliveries
import ochoko/store/remote_actors
import sqlight
import support

const now = 1_700_000_000

fn ts() {
  timestamp.from_unix_seconds(now)
}

fn status(code: Int) -> Send {
  fn(_) { Ok(response.new(code) |> response.set_body("")) }
}

fn insert(
  path: String,
  inbox: String,
  attempts: Int,
  next_attempt_at: Int,
  locked_until: Int,
) {
  db.with_connection(path, fn(conn) {
    let assert Ok(_) =
      sqlight.query(
        "INSERT INTO deliveries
         (inbox, body, attempts, next_attempt_at, locked_until, created_at)
         VALUES (?, '{}', ?, ?, ?, 0)",
        on: conn,
        with: [
          sqlight.text(inbox),
          sqlight.int(attempts),
          sqlight.int(next_attempt_at),
          sqlight.int(locked_until),
        ],
        expecting: decode.success(Nil),
      )
    Nil
  })
}

/// (inbox, attempts, next_attempt_at, locked_until) of all rows.
fn rows(path: String) -> List(#(String, Int, Int, Int)) {
  db.with_connection(path, fn(conn) {
    let assert Ok(rows) =
      sqlight.query(
        "SELECT inbox, attempts, next_attempt_at, locked_until
         FROM deliveries ORDER BY id",
        on: conn,
        with: [],
        expecting: {
          use a <- decode.field(0, decode.string)
          use b <- decode.field(1, decode.int)
          use c <- decode.field(2, decode.int)
          use d <- decode.field(3, decode.int)
          decode.success(#(a, b, c, d))
        },
      )
    rows
  })
}

fn run(path: String, send: Send) -> Int {
  delivery.run_once_and_wait(support.test_context_with_send(path, send), 5000)
}

pub fn enqueue_dedupes_inboxes_test() {
  let conn = support.fresh_db()
  let assert Ok(Nil) =
    deliveries.enqueue(
      conn,
      [
        "https://a.example/inbox",
        "https://b.example/inbox",
        "https://a.example/inbox",
      ],
      "{}",
      ts(),
    )
  let assert Ok([n]) =
    sqlight.query(
      "SELECT COUNT(*) FROM deliveries",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  assert n == 2
}

pub fn inboxes_prefer_shared_inbox_test() {
  let conn = support.fresh_db()
  let actor = fn(n: String, shared) {
    let uri = "https://" <> n <> ".example/u"
    RemoteActor(
      id: 0,
      uri:,
      username: n,
      domain: n <> ".example",
      display_name: n,
      summary_html: "",
      avatar_url: None,
      header_url: None,
      url: None,
      inbox: uri <> "/inbox",
      shared_inbox: shared,
      followers_uri: None,
      public_key_id: uri <> "#main-key",
      public_key_pem: "PEM",
      bot: False,
      locked: False,
    )
  }
  let shared = Some("https://s.example/inbox")
  let assert Ok(a) = remote_actors.upsert(conn, actor("a", shared), 1)
  let assert Ok(b) = remote_actors.upsert(conn, actor("b", shared), 1)
  let assert Ok(c) = remote_actors.upsert(conn, actor("c", None), 1)
  list.each([a, b, c], fn(r) {
    let assert Ok(_) =
      sqlight.query(
        "INSERT INTO followers (actor_id, follow_uri, created_at)
         VALUES (?, 'f', 0)",
        on: conn,
        with: [sqlight.int(r.id)],
        expecting: decode.success(Nil),
      )
  })
  assert deliveries.inboxes_for_followers(conn)
    == ["https://c.example/u/inbox", "https://s.example/inbox"]
}

pub fn success_deletes_row_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, 0)
  assert run(path, status(202)) == 1
  assert rows(path) == []
}

pub fn server_error_reschedules_with_backoff_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, 0)
  assert run(path, status(500)) == 1
  assert rows(path) == [#("https://a.example/inbox", 1, now + 60, 0)]
}

pub fn timeout_and_unreachable_retry_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 2, now, 0)
  assert run(path, fn(_) { Error(http_transport.Timeout) }) == 1
  assert rows(path) == [#("https://a.example/inbox", 3, now + 1800, 0)]
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, 0)
  assert run(path, fn(_) { Error(http_transport.Unreachable("nxdomain")) }) == 1
  assert rows(path) == [#("https://a.example/inbox", 1, now + 60, 0)]
}

pub fn gone_drops_immediately_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, 0)
  assert run(path, status(410)) == 1
  assert rows(path) == []
}

pub fn too_many_requests_retries_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, 0)
  assert run(path, status(429)) == 1
  assert rows(path) == [#("https://a.example/inbox", 1, now + 60, 0)]
}

pub fn gives_up_after_schedule_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 9, now, 0)
  assert run(path, status(500)) == 1
  assert rows(path) == []
}

pub fn not_due_rows_are_skipped_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now + 1, 0)
  assert run(path, status(200)) == 0
  assert list.length(rows(path)) == 1
}

pub fn locked_rows_are_skipped_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, now + 30)
  assert run(path, status(200)) == 0
  assert list.length(rows(path)) == 1
}

pub fn claimed_rows_are_locked_test() {
  let parked = process.new_subject()
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, 0)
  let ctx =
    support.test_context_with_send(path, fn(_) {
      // Parks the worker until the test releases it.
      let release = process.new_subject()
      process.send(parked, release)
      let _ = process.receive(release, 30_000)
      Ok(response.new(200) |> response.set_body(""))
    })
  assert delivery.run_once(ctx) == 1
  assert delivery.run_once(ctx) == 0
  assert rows(path) == [#("https://a.example/inbox", 1, now, now + 60)]
  let assert Ok(release) = process.receive(parked, 5000)
  process.send(release, Nil)
  assert await_rows(path, [], 500)
}

/// Host A blocks until released; host B must complete while A is still
/// blocked. No wall-clock sleeps decide the outcome: the poll below is only
/// a bounded wait for B's worker to finish.
pub fn slow_host_does_not_block_others_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, 0)
  insert(path, "https://b.example/inbox", 0, now, 0)
  // A's worker hands the test a subject of its own to be released through.
  let a_started = process.new_subject()
  let send = fn(req: request.Request(String)) {
    case req.host {
      "a.example" -> {
        let release = process.new_subject()
        process.send(a_started, release)
        let _ = process.receive(release, 30_000)
        Ok(response.new(200) |> response.set_body(""))
      }
      _ -> Ok(response.new(200) |> response.set_body(""))
    }
  }
  let ctx = support.test_context_with_send(path, send)
  assert delivery.run_once(ctx) == 2
  // B's row disappears while A is still blocked.
  assert await_rows(path, ["https://a.example/inbox"], 500)
  // A's worker really is parked in send; release it.
  let assert Ok(release) = process.receive(a_started, 5000)
  process.send(release, Nil)
  assert await_rows(path, [], 500)
}

fn await_rows(path: String, expected: List(String), tries: Int) -> Bool {
  let inboxes = list.map(rows(path), fn(r) { r.0 })
  case inboxes == expected, tries {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      await_rows(path, expected, tries - 1)
    }
  }
}

pub fn posted_request_is_signed_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, 0)
  let #(send, recorded) = support.recording_send(status(200))
  assert run(path, send) == 1
  let assert [req] = recorded()
  assert req.method == Post
  assert request.get_header(req, "content-type")
    == Ok("application/activity+json")
  assert result.is_ok(request.get_header(req, "date"))
  assert request.get_header(req, "digest") == Ok(signature.digest("{}"))
  let assert Ok(header) = request.get_header(req, "signature")
  assert header != ""
}

pub fn crashing_worker_still_consumes_an_attempt_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, 0)
  assert run(path, fn(_) { panic as "boom" }) == 1
  assert rows(path) == [#("https://a.example/inbox", 1, now, now + 60)]
}

pub fn crash_loop_is_eventually_dropped_test() {
  let path = support.temp_db_path()
  // Stored count 10: the 10th (final) attempt already crashed.
  insert(path, "https://a.example/inbox", 10, now, 0)
  assert run(path, fn(_) { panic as "boom" }) == 0
  assert rows(path) == []
}

pub fn posted_request_has_user_agent_test() {
  let path = support.temp_db_path()
  insert(path, "https://a.example/inbox", 0, now, 0)
  let #(send, recorded) = support.recording_send(status(200))
  assert run(path, send) == 1
  let assert [req] = recorded()
  assert request.get_header(req, "user-agent")
    == Ok("ochoko/0.1.0 (+https://ochoko.ynkt.me/)")
}

pub fn private_inbox_is_dropped_without_sending_test() {
  let path = support.temp_db_path()
  insert(path, "https://127.0.0.1:8000/me/inbox", 0, now, 0)
  let #(send, recorded) = support.recording_send(status(200))
  assert run(path, send) == 1
  assert recorded() == []
  assert rows(path) == []
}
