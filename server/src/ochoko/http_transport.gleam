//// The injectable HTTP transport. Lives apart from `ochoko/http_client`
//// because `Context` holds a `Send` and `http_client` needs `Context`;
//// `http_client` re-exports the types as aliases.

import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/result
import gleam/string

pub type Send =
  fn(Request(String)) -> Result(Response(String), HttpError)

pub type HttpError {
  Timeout
  Unreachable(String)
}

pub fn describe_error(e: HttpError) -> String {
  case e {
    Timeout -> "timeout"
    Unreachable(reason) -> "unreachable: " <> reason
  }
}

/// A `Send` backed by gleam_httpc. Redirects are not followed.
pub fn httpc_send(timeout_ms: Int) -> Send {
  fn(req) {
    httpc.configure()
    |> httpc.timeout(timeout_ms)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) {
      case e {
        httpc.ResponseTimeout -> Timeout
        other -> Unreachable(string.inspect(other))
      }
    })
  }
}
