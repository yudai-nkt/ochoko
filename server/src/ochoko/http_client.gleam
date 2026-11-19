//// Outbound HTTP. The transport is injected through `Context.send` so that
//// tests can substitute a fake.

import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/result
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

fn user_agent(ctx: Context) -> String {
  "ochoko/0.1.0 (+https://" <> ctx.config.host <> "/)"
}

/// Builds a GET request for `url` with our User-Agent and the given `Accept`.
fn get_request(
  ctx: Context,
  url: String,
  accept: String,
) -> Result(Request(String), HttpError) {
  case request.to(url) {
    Error(Nil) -> Error(transport.Unreachable("invalid url: " <> url))
    Ok(req) -> {
      let req = case req.path {
        "" -> request.set_path(req, "/")
        _ -> req
      }
      Ok(
        req
        |> request.set_header("accept", accept)
        |> request.set_header("user-agent", user_agent(ctx)),
      )
    }
  }
}

/// An unsigned GET with the given `Accept` header.
pub fn get(
  ctx: Context,
  url: String,
  accept: String,
) -> Result(Response(String), HttpError) {
  use req <- result.try(get_request(ctx, url, accept))
  ctx.send(req)
}

/// A GET for an ActivityPub document, signed with our actor key
/// (authorized-fetch compatible).
pub fn signed_get(
  ctx: Context,
  url: String,
) -> Result(Response(String), HttpError) {
  use req <- result.try(get_request(ctx, url, "application/activity+json"))
  let req =
    signature.sign(req, ctx.private_key, config.key_id(ctx.config), ctx.now())
  ctx.send(req)
}
