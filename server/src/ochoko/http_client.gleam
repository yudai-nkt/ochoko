//// Outbound HTTP. The transport is injected through `Context.send` so that
//// tests can substitute a fake.
////
//// Every outbound request is built by `new_request`, which
//// - only allows `https` URLs,
//// - refuses `localhost` (and `*.localhost`) and IP literals in loopback,
////   private, link-local, unspecified, shared or multicast ranges, and
//// - sets our User-Agent.
//// Host names are not resolved here, so a public name pointing at a private
//// address is not caught (see docs/deployment.md).
////
//// Responses to GETs larger than `max_response_bytes` (by `Content-Length`
//// or by actual size) are rejected with `TooLarge`.

import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/uri
import ochoko/config
import ochoko/context.{type Context}
import ochoko/http_transport as transport
import ochoko/signature

pub type Send =
  transport.Send

pub type HttpError =
  transport.HttpError

pub const describe_error = transport.describe_error

pub const httpc_send = transport.httpc_send

/// Largest response body accepted, in bytes.
pub const max_response_bytes = 1_048_576

@external(erlang, "ochoko_net_ffi", "is_blocked_ip_literal")
fn is_blocked_ip_literal(host: String) -> Bool

fn user_agent(ctx: Context) -> String {
  "ochoko/0.1.0 (+" <> config.base_url(ctx.config) <> "/)"
}

/// Checks that `url` may be fetched: `https` and a public host.
pub fn check_url(url: String) -> Result(uri.Uri, HttpError) {
  let refuse = fn(why) { Error(transport.Refused(why <> ": " <> url)) }
  case uri.parse(string.trim(url)) {
    Error(Nil) -> refuse("invalid url")
    Ok(parsed) ->
      case option.map(parsed.scheme, string.lowercase), parsed.host {
        Some("https"), Some(host) if host != "" ->
          case is_blocked_host(host) {
            True -> refuse("private or local host")
            False -> Ok(uri.Uri(..parsed, scheme: Some("https")))
          }
        Some("https"), _ -> refuse("missing host")
        _, _ -> refuse("only https URLs are fetched")
      }
  }
}

fn is_blocked_host(host: String) -> Bool {
  let name = string.lowercase(host)
  let name = case string.ends_with(name, ".") {
    True -> string.drop_end(name, 1)
    False -> name
  }
  name == "localhost"
  || string.ends_with(name, ".localhost")
  || is_blocked_ip_literal(name)
}

/// A request to `url` with our User-Agent, if `url` passes `check_url`.
pub fn new_request(
  ctx: Context,
  method: http.Method,
  url: String,
) -> Result(Request(String), HttpError) {
  use parsed <- result.try(check_url(url))
  case request.from_uri(parsed) {
    Error(Nil) -> Error(transport.Refused("invalid url: " <> url))
    Ok(req) -> {
      let req = case req.path {
        "" -> request.set_path(req, "/")
        _ -> req
      }
      Ok(
        req
        |> request.set_method(method)
        |> request.set_header("user-agent", user_agent(ctx)),
      )
    }
  }
}

/// Sends a GET and enforces the response size limit.
fn send_get(
  ctx: Context,
  req: Request(String),
) -> Result(Response(String), HttpError) {
  use res <- result.try(ctx.send(req))
  let declared =
    response.get_header(res, "content-length")
    |> result.try(fn(v) { int.parse(string.trim(v)) })
  case declared {
    Ok(n) if n > max_response_bytes -> Error(transport.TooLarge)
    _ ->
      case bit_array.byte_size(<<res.body:utf8>>) > max_response_bytes {
        True -> Error(transport.TooLarge)
        False -> Ok(res)
      }
  }
}

/// An unsigned GET with the given `Accept` header.
pub fn get(
  ctx: Context,
  url: String,
  accept: String,
) -> Result(Response(String), HttpError) {
  use req <- result.try(new_request(ctx, http.Get, url))
  send_get(ctx, request.set_header(req, "accept", accept))
}

/// A GET for an ActivityPub document, signed with our actor key
/// (authorized-fetch compatible).
pub fn signed_get(
  ctx: Context,
  url: String,
) -> Result(Response(String), HttpError) {
  use req <- result.try(new_request(ctx, http.Get, url))
  let req =
    req
    |> request.set_header("accept", "application/activity+json")
    |> signature.sign(ctx.private_key, config.key_id(ctx.config), ctx.now())
  send_get(ctx, req)
}

/// A signed POST of an ActivityPub document (delivery to an inbox).
pub fn signed_post(
  ctx: Context,
  url: String,
  body: String,
) -> Result(Response(String), HttpError) {
  use req <- result.try(new_request(ctx, http.Post, url))
  let req =
    req
    |> request.set_header("content-type", "application/activity+json")
    |> request.set_body(body)
    |> signature.sign(ctx.private_key, config.key_id(ctx.config), ctx.now())
  ctx.send(req)
}
