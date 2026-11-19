//// Request parameters from the query string and from a JSON or
//// form-urlencoded body, merged into one dictionary (body wins).

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import wisp.{type Request, type Response}

pub type Params =
  Dict(String, String)

/// Array values (JSON arrays, repeated or `key[]` form fields) are joined
/// with newlines; read them back with `get_list`.
pub fn read(req: Request, next: fn(Params) -> Response) -> Response {
  let query = from_pairs(wisp.get_query(req))
  case req.method {
    http.Get -> next(query)
    _ -> {
      use body <- wisp.require_string_body(req)
      let is_json = case request.get_header(req, "content-type") {
        Ok(ct) -> string.contains(string.lowercase(ct), "json")
        Error(Nil) -> False
      }
      let parsed = case string.trim(body) == "" {
        True -> Ok(dict.new())
        False ->
          case is_json {
            True -> parse_json(body)
            False -> parse_form(body)
          }
      }
      case parsed {
        Ok(from_body) -> next(dict.merge(query, from_body))
        Error(Nil) -> wisp.bad_request("invalid request body")
      }
    }
  }
}

pub fn get(params: Params, key: String) -> String {
  dict.get(params, key) |> result.unwrap("")
}

pub fn get_list(params: Params, key: String) -> List(String) {
  get(params, key)
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(s) { s != "" })
}

fn from_pairs(pairs: List(#(String, String))) -> Params {
  list.fold(pairs, dict.new(), fn(acc, pair) {
    let is_array = string.ends_with(pair.0, "[]")
    let key = case is_array {
      True -> string.drop_end(pair.0, 2)
      False -> pair.0
    }
    case is_array, dict.get(acc, key) {
      True, Ok(existing) -> dict.insert(acc, key, existing <> "\n" <> pair.1)
      _, _ -> dict.insert(acc, key, pair.1)
    }
  })
}

fn parse_form(body: String) -> Result(Params, Nil) {
  uri.parse_query(body) |> result.map(from_pairs)
}

fn scalar() -> decode.Decoder(String) {
  decode.one_of(decode.string, [
    decode.bool
      |> decode.map(fn(b) {
        case b {
          True -> "true"
          False -> "false"
        }
      }),
    decode.int |> decode.map(int.to_string),
    decode.float |> decode.map(float.to_string),
    // Objects (e.g. `poll`, or media given as objects) are only reported as
    // present.
    decode.dict(decode.string, decode.dynamic) |> decode.map(fn(_) { "{}" }),
  ])
}

fn parse_json(body: String) -> Result(Params, Nil) {
  let value =
    decode.one_of(decode.list(scalar()) |> decode.map(string.join(_, "\n")), [
      scalar(),
      decode.success(""),
    ])
  json.parse(body, decode.dict(decode.string, value))
  |> result.replace_error(Nil)
}
