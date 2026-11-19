import gleam/list
import gleam/option.{None, Some}
import ochoko/federation/remote_actor_types.{RemoteActor}
import ochoko/store/remote_actors
import support

fn actor(uri: String, username: String, domain: String) {
  RemoteActor(
    id: 0,
    uri:,
    username:,
    domain:,
    display_name: username,
    summary_html: "",
    avatar_url: None,
    header_url: None,
    url: None,
    inbox: uri <> "/inbox",
    shared_inbox: None,
    followers_uri: None,
    public_key_id: uri <> "#main-key",
    public_key_pem: "PEM",
    bot: False,
    locked: False,
  )
}

pub fn upsert_inserts_then_refreshes_by_uri_test() {
  let conn = support.fresh_db()
  let assert Ok(first) =
    remote_actors.upsert(
      conn,
      actor("https://a.example/u/x", "x", "a.example"),
      10,
    )
  assert first.id > 0
  let changed =
    RemoteActor(
      ..actor("https://a.example/u/x", "x", "a.example"),
      display_name: "New",
      locked: True,
      shared_inbox: Some("https://a.example/inbox"),
    )
  let assert Ok(second) = remote_actors.upsert(conn, changed, 20)
  assert second.id == first.id
  assert second.display_name == "New"
  assert second.locked
  assert second.shared_inbox == Some("https://a.example/inbox")
  let assert Ok(Some(#(_, fetched_at))) =
    remote_actors.get_cached(conn, "https://a.example/u/x")
  assert fetched_at == 20
}

pub fn get_and_get_by_uri_test() {
  let conn = support.fresh_db()
  let assert Ok(a) =
    remote_actors.upsert(
      conn,
      actor("https://a.example/u/x", "x", "a.example"),
      1,
    )
  assert remote_actors.get(conn, a.id) == Ok(Some(a))
  assert remote_actors.get_by_uri(conn, a.uri) == Ok(Some(a))
  assert remote_actors.get(conn, 999) == Ok(None)
}

pub fn search_prefix_test() {
  let conn = support.fresh_db()
  let assert Ok(_) =
    remote_actors.upsert(
      conn,
      actor("https://a.example/u/alice", "alice", "a.example"),
      1,
    )
  let assert Ok(_) =
    remote_actors.upsert(
      conn,
      actor("https://b.example/u/alan", "Alan", "b.example"),
      1,
    )
  let assert Ok(_) =
    remote_actors.upsert(
      conn,
      actor("https://b.example/u/bob", "bob", "b.example"),
      1,
    )
  let assert Ok(by_name) = remote_actors.search_prefix(conn, "al", 10)
  assert list_usernames(by_name) == ["Alan", "alice"]
  let assert Ok(by_acct) = remote_actors.search_prefix(conn, "@bob@b.ex", 10)
  assert list_usernames(by_acct) == ["bob"]
  let assert Ok(limited) = remote_actors.search_prefix(conn, "al", 1)
  assert list.length(limited) == 1
  let assert Ok(none) = remote_actors.search_prefix(conn, "%", 10)
  assert none == []
}

fn list_usernames(actors: List(remote_actor_types.RemoteActor)) {
  list.map(actors, fn(a) { a.username })
}
