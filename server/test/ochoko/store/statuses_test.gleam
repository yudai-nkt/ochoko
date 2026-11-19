import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/time/timestamp
import ochoko/db
import ochoko/federation/note
import ochoko/federation/remote_actor_types.{RemoteActor}
import ochoko/store/page.{Page}
import ochoko/store/remote_actors
import ochoko/store/statuses
import ochoko_shared/mastodon
import sqlight
import support

fn n(uri: String, at: Int) -> note.InboundNote {
  note.InboundNote(
    uri:,
    attributed_to: "https://r.example/u",
    content_html: "<p>x</p>",
    spoiler_text: "",
    sensitive: False,
    url: None,
    in_reply_to: None,
    language: None,
    published: Some(timestamp.from_unix_seconds(at)),
    to: [],
    cc: [],
    attachments: [],
  )
}

fn actor(conn) -> Int {
  let assert Ok(a) =
    remote_actors.upsert(
      conn,
      RemoteActor(
        id: 0,
        uri: "https://r.example/u",
        username: "u",
        domain: "r.example",
        display_name: "U",
        summary_html: "",
        avatar_url: None,
        header_url: None,
        url: None,
        inbox: "https://r.example/u/inbox",
        shared_inbox: None,
        followers_uri: None,
        public_key_id: "k",
        public_key_pem: "p",
        bot: False,
        locked: False,
      ),
      0,
    )
  a.id
}

fn uris(rows: List(statuses.StatusRow)) -> List(String) {
  list.map(rows, fn(r) { r.uri })
}

pub fn list_by_actor_paging_test() {
  let path = support.temp_db_path()
  use conn <- db.with_connection(path)
  let a = actor(conn)
  let now = timestamp.from_unix_seconds(1_700_000_000)
  let put = fn(uri, at, v) {
    let assert Ok(Nil) = statuses.insert_remote(conn, a, n(uri, at), v, now)
    Nil
  }
  put("s1", 1_600_000_001, mastodon.Public)
  put("s2", 1_600_000_002, mastodon.Unlisted)
  put("s3", 1_600_000_003, mastodon.Public)
  put("s4", 1_600_000_004, mastodon.Public)
  put("direct", 1_600_000_005, mastodon.Direct)
  put("gone", 1_600_000_006, mastodon.Public)
  let assert Ok(_) =
    sqlight.query(
      "UPDATE statuses SET deleted_at = 1 WHERE uri = 'gone'",
      on: conn,
      with: [],
      expecting: decode.success(Nil),
    )
  let id = fn(uri) {
    let assert Ok(Some(r)) = statuses.get_by_uri(conn, uri)
    r.id
  }
  let list_ = fn(page) {
    let assert Ok(rows) = statuses.list_by_actor(conn, Some(a), page)
    uris(rows)
  }
  // Deleted and direct statuses never appear.
  assert list_(Page(None, None, None, 40)) == ["s4", "s3", "s2", "s1"]
  assert list_(Page(Some(id("s3")), None, None, 40)) == ["s2", "s1"]
  assert list_(Page(Some(id("s3")), None, None, 1)) == ["s2"]
  assert list_(Page(None, Some(id("s2")), None, 40)) == ["s4", "s3"]
  // since_id keeps the newest page, min_id the page just after the cursor.
  assert list_(Page(None, Some(id("s1")), None, 2)) == ["s4", "s3"]
  assert list_(Page(None, None, Some(id("s1")), 2)) == ["s3", "s2"]
  // Our own statuses are listed separately.
  let assert Ok(own) =
    statuses.list_by_actor(conn, None, Page(None, None, None, 40))
  assert own == []
}
