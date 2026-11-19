import gleam/http
import gleam/http/request
import ochoko/api/params
import wisp
import wisp/simulate

/// The value `params.get` yields for `key` in the JSON `body`.
fn value(body: String, key: String) -> String {
  let req =
    simulate.request(http.Post, "/")
    |> simulate.string_body(body)
    |> request.set_header("content-type", "application/json")
  params.read(req, fn(p) { wisp.ok() |> wisp.string_body(params.get(p, key)) })
  |> simulate.read_body
}

const body =
  "{\"b\":true,\"i\":5,\"f\":1.5,\"o\":{\"a\":1},\"n\":null,\"l\":[1,false,\"x\",{\"k\":1}]}"

pub fn json_scalars_are_stringified_test() {
  assert value(body, "b") == "true"
  assert value(body, "i") == "5"
  assert value(body, "f") == "1.5"
}

pub fn json_objects_are_present_test() {
  assert value(body, "o") == "{}"
  assert value(body, "n") == ""
}

pub fn json_arrays_of_scalars_and_objects_test() {
  assert value(body, "l") == "1\nfalse\nx\n{}"
}
