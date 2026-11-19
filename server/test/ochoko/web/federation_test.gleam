import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/time/timestamp
import ochoko/db
import ochoko/federation/local_actor
import ochoko/html
import ochoko/store/profile.{Profile}
import ochoko/store/statuses
import ochoko/web/router
import ochoko_shared/mastodon
import sqlight
import support
import wisp/simulate

fn get(path: String) {
  let ctx = support.test_context(support.temp_db_path())
  router.handle_request(simulate.request(http.Get, path), ctx)
}

fn string_at(body: String, path: List(String)) -> String {
  let assert Ok(s) = json.parse(body, decode.at(path, decode.string))
  s
}

fn link_field(body: String, key: String) {
  json.parse(
    body,
    decode.at(["links"], decode.list(decode.at([key], decode.string))),
  )
}

pub fn webfinger_subject_uses_account_domain_test() {
  let res = get("/.well-known/webfinger?resource=acct:yudai@ynkt.me")
  assert res.status == 200
  assert response.get_header(res, "content-type")
    == Ok("application/jrd+json; charset=utf-8")
  let body = simulate.read_body(res)
  assert string_at(body, ["subject"]) == "acct:yudai@ynkt.me"
  let assert Ok(["https://ochoko.ynkt.me/me"]) =
    json.parse(body, decode.at(["aliases"], decode.list(decode.string)))
  let assert Ok(["self"]) = link_field(body, "rel")
  let assert Ok(["application/activity+json"]) = link_field(body, "type")
  let assert Ok(["https://ochoko.ynkt.me/me"]) = link_field(body, "href")
}

pub fn webfinger_accepts_host_domain_test() {
  let res = get("/.well-known/webfinger?resource=acct:yudai@ochoko.ynkt.me")
  assert res.status == 200
  assert string_at(simulate.read_body(res), ["subject"]) == "acct:yudai@ynkt.me"
}

pub fn webfinger_accepts_actor_url_test() {
  let res = get("/.well-known/webfinger?resource=https://ochoko.ynkt.me/me")
  assert res.status == 200
}

pub fn webfinger_unknown_404_test() {
  assert get("/.well-known/webfinger?resource=acct:nobody@ynkt.me").status
    == 404
}

pub fn webfinger_missing_400_test() {
  assert get("/.well-known/webfinger").status == 400
}

pub fn actor_json_test() {
  let p = Profile("Yudai", "<p>hi</p>", Some("https://x/a.png"), None)
  let body =
    local_actor.actor_json(support.test_config(), p, "PEM")
    |> json.to_string
  assert string_at(body, ["id"]) == "https://ochoko.ynkt.me/me"
  assert string_at(body, ["type"]) == "Person"
  assert string_at(body, ["inbox"]) == "https://ochoko.ynkt.me/me/inbox"
  assert string_at(body, ["publicKey", "owner"]) == "https://ochoko.ynkt.me/me"
  assert string_at(body, ["publicKey", "id"])
    == "https://ochoko.ynkt.me/me#main-key"
  assert string_at(body, ["publicKey", "publicKeyPem"]) == "PEM"
  assert string_at(body, ["url"]) == "https://ochoko.ynkt.me/profile"
  assert string_at(body, ["name"]) == "Yudai"
  assert string_at(body, ["icon", "url"]) == "https://x/a.png"
  assert string_at(body, ["endpoints", "sharedInbox"])
    == "https://ochoko.ynkt.me/inbox"
  let assert Ok(False) =
    json.parse(body, decode.at(["manuallyApprovesFollowers"], decode.bool))
}

pub fn actor_name_falls_back_to_handle_test() {
  let p = Profile("", "", None, None)
  let body =
    local_actor.actor_json(support.test_config(), p, "PEM")
    |> json.to_string
  assert string_at(body, ["name"]) == "yudai"
}

pub fn me_serves_actor_test() {
  let res = get("/me")
  assert res.status == 200
  assert response.get_header(res, "content-type")
    == Ok("application/activity+json; charset=utf-8")
  let body = simulate.read_body(res)
  assert string_at(body, ["id"]) == "https://ochoko.ynkt.me/me"
  assert string_at(body, ["name"]) == "yudai"
}

pub fn me_redirects_browsers_test() {
  let ctx = support.test_context(support.temp_db_path())
  let res =
    simulate.request(http.Get, "/me")
    |> request.set_header("accept", "text/html,application/xhtml+xml")
    |> router.handle_request(ctx)
  assert res.status == 302
  assert response.get_header(res, "location")
    == Ok("https://ochoko.ynkt.me/profile")
}

pub fn me_serves_json_when_activity_json_accepted_test() {
  let ctx = support.test_context(support.temp_db_path())
  let res =
    simulate.request(http.Get, "/me")
    |> request.set_header("accept", "text/html, application/activity+json")
    |> router.handle_request(ctx)
  assert res.status == 200
}

pub fn followers_collection_total_test() {
  let path = support.temp_db_path()
  let ctx = support.test_context(path)
  db.with_connection(path, fn(conn) {
    list.each([1, 2], fn(n) { insert_follower(conn, n) })
  })
  let res =
    router.handle_request(simulate.request(http.Get, "/me/followers"), ctx)
  assert res.status == 200
  let body = simulate.read_body(res)
  let assert Ok(2) = json.parse(body, decode.at(["totalItems"], decode.int))
  assert string_at(body, ["type"]) == "OrderedCollection"
  assert string_at(body, ["id"]) == "https://ochoko.ynkt.me/me/followers"
}

pub fn following_and_outbox_empty_test() {
  let body = simulate.read_body(get("/me/following"))
  let assert Ok(0) = json.parse(body, decode.at(["totalItems"], decode.int))
  let body = simulate.read_body(get("/me/outbox"))
  let assert Ok(0) = json.parse(body, decode.at(["totalItems"], decode.int))
  assert string_at(body, ["id"]) == "https://ochoko.ynkt.me/me/outbox"
}

pub fn cors_preflight_test() {
  let ctx = support.test_context(":memory:")
  let res =
    simulate.request(http.Options, "/api/v1/apps")
    |> router.handle_request(ctx)
  assert res.status == 204
  assert response.get_header(res, "access-control-allow-origin") == Ok("*")
  assert response.get_header(res, "access-control-allow-methods")
    == Ok("GET, POST, PUT, PATCH, DELETE, OPTIONS")
  assert response.get_header(res, "access-control-allow-headers")
    == Ok("Authorization, Content-Type, Idempotency-Key")
  assert response.get_header(res, "access-control-expose-headers") == Ok("Link")
}

pub fn cors_on_normal_response_test() {
  let res = get("/health")
  assert response.get_header(res, "access-control-allow-origin") == Ok("*")
  let res = get("/nope")
  assert res.status == 404
  assert response.get_header(res, "access-control-allow-origin") == Ok("*")
}

fn insert_follower(conn: sqlight.Connection, n: Int) -> Nil {
  let uri = "https://r.example/users/" <> int.to_string(n)
  let assert Ok(_) =
    sqlight.query(
      "INSERT INTO remote_actors (id, uri, username, domain, display_name, summary_html, inbox, public_key_id, public_key_pem, bot, locked, fetched_at) VALUES (?, ?, 'u', 'r.example', '', '', 'i', 'k', 'p', 0, 0, 0)",
      on: conn,
      with: [sqlight.int(n), sqlight.text(uri)],
      expecting: decode.success(Nil),
    )
  let assert Ok(_) =
    sqlight.query(
      "INSERT INTO followers (actor_id, follow_uri, created_at) VALUES (?, ?, 0)",
      on: conn,
      with: [sqlight.int(n), sqlight.text(uri <> "#follow")],
      expecting: decode.success(Nil),
    )
  Nil
}

// --- final review fixes -------------------------------------------------------

pub fn webfinger_is_case_insensitive_test() {
  assert get("/.well-known/webfinger?resource=acct:Yudai@YNKT.me").status == 200
  assert get("/.well-known/webfinger?resource=ACCT:yudai@Ochoko.Ynkt.Me").status
    == 200
}

pub fn webfinger_tolerates_missing_acct_prefix_test() {
  let res = get("/.well-known/webfinger?resource=yudai@ynkt.me")
  assert res.status == 200
  assert string_at(simulate.read_body(res), ["subject"]) == "acct:yudai@ynkt.me"
  assert get("/.well-known/webfinger?resource=nobody@ynkt.me").status == 404
}

pub fn actor_summary_is_rendered_note_test() {
  let p = Profile("Yudai", "hi <b>\nthere", None, None)
  let body =
    local_actor.actor_json(support.test_config(), p, "PEM")
    |> json.to_string
  assert string_at(body, ["summary"]) == html.text_to_html("hi <b>\nthere")
}

pub fn outbox_counts_own_live_statuses_test() {
  let path = support.temp_db_path()
  let ctx = support.test_context(path)
  let now = timestamp.from_unix_seconds(1_700_000_000)
  db.with_connection(path, fn(conn) {
    let insert = fn() {
      let assert Ok(row) =
        statuses.insert_own(
          conn,
          ctx.config,
          "x",
          "<p>x</p>",
          mastodon.Public,
          "",
          False,
          None,
          now,
        )
      row
    }
    let _ = insert()
    let _ = insert()
    let gone = insert()
    let assert Ok(Nil) = statuses.mark_deleted(conn, gone.id, now)
    Nil
  })
  let res = router.handle_request(simulate.request(http.Get, "/me/outbox"), ctx)
  assert res.status == 200
  let body = simulate.read_body(res)
  let assert Ok(2) = json.parse(body, decode.at(["totalItems"], decode.int))
  assert string_at(body, ["id"]) == "https://ochoko.ynkt.me/me/outbox"
}
