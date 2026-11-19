import gleam/dynamic/decode
import gleam/http
import gleam/json
import ochoko/api/respond
import ochoko/web/router
import sqlight
import support
import wisp/simulate

fn error_field(body: String) -> String {
  let assert Ok(message) = json.parse(body, decode.at(["error"], decode.string))
  message
}

pub fn server_error_is_json_500_test() {
  let res =
    respond.server_error(sqlight.SqlightError(
      sqlight.GenericError,
      "disk I/O error",
      -1,
    ))
  assert res.status == 500
  let body = simulate.read_body(res)
  assert error_field(body) == "Internal server error"
}

pub fn not_found_and_unprocessable_test() {
  let res = respond.not_found()
  assert res.status == 404
  assert error_field(simulate.read_body(res)) == "Record not found"
  let res = respond.unprocessable("bad")
  assert res.status == 422
  assert error_field(simulate.read_body(res)) == "bad"
}

pub fn unknown_api_path_is_json_404_test() {
  let ctx = support.test_context(support.temp_db_path())
  let res =
    router.handle_request(
      simulate.request(http.Get, "/api/v1/nonexistent"),
      ctx,
    )
  assert res.status == 404
  assert error_field(simulate.read_body(res)) == "Record not found"
  let res =
    router.handle_request(simulate.request(http.Post, "/api/v9/whatever"), ctx)
  assert res.status == 404
  assert error_field(simulate.read_body(res)) == "Record not found"
}
