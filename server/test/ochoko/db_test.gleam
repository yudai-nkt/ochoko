import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam/string
import ochoko/db
import ochoko/store/profile
import sqlight
import support

fn count(conn: sqlight.Connection, sql: String) -> Int {
  let assert Ok([n]) =
    sqlight.query(sql, on: conn, with: [], expecting: {
      use n <- decode.field(0, decode.int)
      decode.success(n)
    })
  n
}

pub fn migrate_is_idempotent_test() {
  let conn = support.fresh_db()
  assert db.migrate(conn) == Ok(Nil)
  assert db.migrate(conn) == Ok(Nil)
  assert count(conn, "PRAGMA user_version") == 1
}

pub fn profile_has_exactly_one_row_test() {
  let conn = support.fresh_db()
  assert count(conn, "SELECT count(*) FROM profile") == 1
}

pub fn profile_rejects_second_row_test() {
  let conn = support.fresh_db()
  let r =
    sqlight.exec(
      "INSERT INTO profile (id, display_name, note) VALUES (2, 'x', 'y')",
      on: conn,
    )
  assert case r {
    Error(_) -> True
    Ok(_) -> False
  }
}

pub fn profile_rejects_delete_test() {
  let conn = support.fresh_db()
  let assert Error(e) = sqlight.exec("DELETE FROM profile", on: conn)
  assert string.contains(e.message, "profile row cannot be deleted")
}

pub fn no_user_tables_test() {
  let conn = support.fresh_db()
  assert count(
      conn,
      "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name LIKE '%user%'",
    )
    == 0
  assert count(
      conn,
      "SELECT count(*) FROM sqlite_master m, pragma_table_info(m.name) c WHERE m.type = 'table' AND c.name = 'user_id'",
    )
    == 0
}

pub fn profile_update_roundtrip_test() {
  let conn = support.fresh_db()
  let assert Ok(p) = profile.get(conn)
  assert p == profile.Profile("", "", None, None)
  let new =
    profile.Profile(
      "Yudai",
      "hello",
      Some("https://x/a.png"),
      Some("https://x/h.png"),
    )
  assert profile.update(conn, new) == Ok(Nil)
  assert profile.get(conn) == Ok(new)
}
