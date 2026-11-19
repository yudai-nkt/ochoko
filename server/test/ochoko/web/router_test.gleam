import gleam/http
import ochoko/context.{type Context, Context}
import ochoko/web/router
import wisp/simulate

fn test_ctx() -> Context {
  Context
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
