//// JSON responses shared by the Mastodon API handlers. Errors use
//// Mastodon's `{"error": "..."}` shape; server errors are logged.

import gleam/json
import gleam/option.{None}
import ochoko_shared/mastodon
import sqlight
import wisp.{type Response}

pub fn json_ok(body: json.Json) -> Response {
  wisp.json_response(json.to_string(body), 200)
}

/// `{"error": message}` with `status`.
pub fn error(message: String, status: Int) -> Response {
  wisp.json_response(
    json.to_string(mastodon.error_to_json(mastodon.Error(message, None))),
    status,
  )
}

pub fn not_found() -> Response {
  error("Record not found", 404)
}

pub fn unprocessable(message: String) -> Response {
  error(message, 422)
}

/// Logs the database error and answers 500.
pub fn server_error(e: sqlight.Error) -> Response {
  internal_error("database error: " <> e.message)
}

/// Logs `reason` and answers 500. The reason is not sent to the client.
pub fn internal_error(reason: String) -> Response {
  wisp.log_error("api: " <> reason)
  error("Internal server error", 500)
}
