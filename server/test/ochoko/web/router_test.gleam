import gleam/http
import gleam/time/timestamp
import ochoko/config
import ochoko/context.{type Context, Context}
import ochoko/web/router
import wisp/simulate

fn test_ctx() -> Context {
  let c =
    config.Config(
      account_domain: "ynkt.me",
      host: "ochoko.ynkt.me",
      handle: "yudai",
      listen_port: 8000,
      database_path: ":memory:",
      private_key_path: "key.pem",
      password_hash: "hash",
      secret_key_base: "secret",
    )
  Context(config: c, db_path: ":memory:", now: timestamp.system_time)
}

pub fn health_test() {
  let res =
    router.handle_request(simulate.request(http.Get, "/health"), test_ctx())
  assert res.status == 200
  assert simulate.read_body(res) == "ok"
}

pub fn unknown_path_test() {
  let res =
    router.handle_request(simulate.request(http.Get, "/nope"), test_ctx())
  assert res.status == 404
}
