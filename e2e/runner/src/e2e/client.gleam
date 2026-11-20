//// A minimal Mastodon-API client shared by both servers. Every failure is a
//// `String` describing the request, so a failed step explains itself.

import gleam/dynamic/decode.{type Decoder}
import gleam/http.{type Method, Delete, Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json.{type Json}
import gleam/option
import gleam/result
import gleam/string
import gleam/uri

pub type Client {
  Client(base_url: String, token: String)
}

pub fn get(c: Client, path: String, decoder: Decoder(a)) -> Result(a, String) {
  use req <- result.try(new_request(c, Get, path))
  send_json(req, decoder)
}

pub fn post(
  c: Client,
  path: String,
  body: Json,
  decoder: Decoder(a),
) -> Result(a, String) {
  use req <- result.try(new_request(c, Post, path))
  req
  |> request.set_header("content-type", "application/json")
  |> request.set_body(json.to_string(body))
  |> send_json(decoder)
}

pub fn delete(c: Client, path: String) -> Result(Nil, String) {
  use req <- result.try(new_request(c, Delete, path))
  send_json(req, decode.success(Nil))
}

/// POST a form without following redirects; returns the raw response.
pub fn post_form(
  base_url: String,
  path: String,
  fields: List(#(String, String)),
) -> Result(Response(String), String) {
  use req <- result.try(new_request(Client(base_url, ""), Post, path))
  req
  |> request.set_header("content-type", "application/x-www-form-urlencoded")
  |> request.set_body(uri.query_to_string(fields))
  |> send
}

/// `path?k=v&...` with the values percent-encoded.
pub fn with_query(path: String, query: List(#(String, String))) -> String {
  path <> "?" <> uri.query_to_string(query)
}

fn new_request(
  c: Client,
  method: Method,
  path: String,
) -> Result(Request(String), String) {
  use req <- result.try(
    request.to(c.base_url <> path)
    |> result.replace_error("invalid URL: " <> c.base_url <> path),
  )
  let req = request.set_method(req, method)
  Ok(case c.token {
    "" -> req
    token -> request.set_header(req, "authorization", "Bearer " <> token)
  })
}

fn send(req: Request(String)) -> Result(Response(String), String) {
  httpc.configure()
  |> httpc.timeout(15_000)
  |> httpc.dispatch(req)
  |> result.map_error(fn(e) { describe(req) <> ": " <> string.inspect(e) })
}

fn send_json(req: Request(String), decoder: Decoder(a)) -> Result(a, String) {
  use resp <- result.try(send(req))
  case resp.status >= 200 && resp.status < 300 {
    False ->
      Error(
        describe(req)
        <> ": HTTP "
        <> int.to_string(resp.status)
        <> " "
        <> string.slice(resp.body, 0, 500),
      )
    True ->
      json.parse(resp.body, decoder)
      |> result.map_error(fn(e) {
        describe(req) <> ": unexpected JSON: " <> string.inspect(e)
      })
  }
}

fn describe(req: Request(String)) -> String {
  let method = string.uppercase(http.method_to_string(req.method))
  let query = case req.query {
    option.Some(q) -> "?" <> q
    option.None -> ""
  }
  method <> " " <> req.host <> req.path <> query
}
