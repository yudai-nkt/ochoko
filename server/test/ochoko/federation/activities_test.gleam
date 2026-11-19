import gleam/dynamic/decode
import gleam/json
import gleam/string
import ochoko/federation/activities
import support

fn field(j: json.Json, path: List(String)) -> String {
  let assert Ok(v) =
    json.parse(json.to_string(j), decode.at(path, decode.string))
  v
}

pub fn follow_test() {
  let #(id, j) = activities.follow(support.test_config(), "https://r.example/a")
  assert string.starts_with(id, "https://ochoko.ynkt.me/activities/")
  assert field(j, ["id"]) == id
  assert field(j, ["type"]) == "Follow"
  assert field(j, ["actor"]) == "https://ochoko.ynkt.me/me"
  assert field(j, ["object"]) == "https://r.example/a"
}

pub fn accept_embeds_follow_test() {
  let j =
    activities.accept(
      support.test_config(),
      "https://r.example/f/1",
      "https://r.example/a",
    )
  assert field(j, ["type"]) == "Accept"
  assert field(j, ["object", "id"]) == "https://r.example/f/1"
  assert field(j, ["object", "actor"]) == "https://r.example/a"
  assert field(j, ["object", "object"]) == "https://ochoko.ynkt.me/me"
}

pub fn undo_and_reject_test() {
  let c = support.test_config()
  let #(_, f) = activities.follow(c, "https://r.example/a")
  assert field(activities.undo(c, f), ["object", "type"]) == "Follow"
  assert field(activities.reject(c, "u", "https://r.example/a"), ["type"])
    == "Reject"
}
