//// The inbox: authenticates incoming activities by HTTP Signature, attributes
//// them to the signer, drops duplicates and dispatches them.

import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import ochoko/config
import ochoko/context.{type Context}
import ochoko/crypto/rsa
import ochoko/db
import ochoko/federation/activities
import ochoko/federation/ap_decode
import ochoko/federation/remote_actor.{type RemoteActor}
import ochoko/signature
import ochoko/store/deliveries
import ochoko/store/follows
import ochoko/store/notifications
import ochoko/store/processed_activities
import sqlight
import wisp.{type Request, type Response}

/// Largest accepted request body, in bytes.
const max_body_bytes = 1_048_576

type Envelope {
  Envelope(id: String, types: List(String), actor: String)
}

fn envelope_decoder() -> decode.Decoder(Envelope) {
  use id <- decode.field("id", ap_decode.iri())
  use types <- decode.field("type", ap_decode.type_names())
  use actor <- decode.field("actor", ap_decode.iri())
  decode.success(Envelope(id:, types:, actor:))
}

pub fn handle(ctx: Context, req: Request) -> Response {
  use <- wisp.require_method(req, Post)
  let req = wisp.set_max_body_size(req, max_body_bytes)
  use body <- wisp.require_string_body(req)
  let signed_req = request.set_body(req, body)
  case signature.parse_header(signed_req) {
    Error(_) -> wisp.response(401)
    Ok(parsed) ->
      case json.parse(body, envelope_decoder()) {
        Error(_) -> wisp.bad_request("malformed activity")
        Ok(envelope) -> authenticate(ctx, signed_req, parsed, envelope, body)
      }
  }
}

fn authenticate(
  ctx: Context,
  req: request.Request(String),
  parsed: signature.Parsed,
  envelope: Envelope,
  body: String,
) -> Response {
  case remote_actor.by_key_id(ctx, parsed.key_id) {
    Error(_) ->
      case list.contains(envelope.types, "Delete") {
        True -> wisp.response(202)
        False -> wisp.response(401)
      }
    Ok(signer) ->
      case verify_with_refetch(ctx, req, parsed, signer) {
        Error(_) -> wisp.response(401)
        Ok(signer) ->
          case signer.uri == envelope.actor {
            False -> wisp.response(401)
            True -> process(ctx, signer, envelope, body)
          }
      }
  }
}

/// Verifies against the cached key; on a bad signature refetches the actor
/// once (the key may have been rotated) and tries again.
fn verify_with_refetch(
  ctx: Context,
  req: request.Request(String),
  parsed: signature.Parsed,
  signer: RemoteActor,
) -> Result(RemoteActor, Nil) {
  case verify(ctx, req, parsed, signer) {
    Ok(Nil) -> Ok(signer)
    Error(signature.BadSignature) -> {
      use fresh <- result.try(
        remote_actor.refetch(ctx, signer.uri) |> result.replace_error(Nil),
      )
      verify(ctx, req, parsed, fresh)
      |> result.replace_error(Nil)
      |> result.replace(fresh)
    }
    Error(_) -> Error(Nil)
  }
}

fn verify(
  ctx: Context,
  req: request.Request(String),
  parsed: signature.Parsed,
  signer: RemoteActor,
) -> Result(Nil, signature.VerifyError) {
  case rsa.public_from_pem(signer.public_key_pem) {
    Error(Nil) -> Error(signature.BadSignature)
    Ok(key) -> signature.verify(req, parsed, key, ctx.now())
  }
}

fn process(
  ctx: Context,
  signer: RemoteActor,
  envelope: Envelope,
  body: String,
) -> Response {
  let outcome =
    db.with_connection(ctx.db_path, fn(conn) {
      in_transaction(conn, fn() {
        use seen <- result.try(processed_activities.is_processed(
          conn,
          envelope.id,
        ))
        case seen {
          True -> Ok(Nil)
          False -> {
            use _ <- result.try(dispatch(ctx, conn, signer, envelope, body))
            processed_activities.mark(conn, envelope.id, ctx.now())
          }
        }
      })
    })
  case outcome {
    Ok(Nil) -> wisp.response(202)
    Error(e) -> {
      wisp.log_error(
        "inbox: failed to process " <> envelope.id <> ": " <> e.message,
      )
      wisp.internal_server_error()
    }
  }
}

fn in_transaction(
  conn: sqlight.Connection,
  f: fn() -> Result(Nil, sqlight.Error),
) -> Result(Nil, sqlight.Error) {
  use _ <- result.try(sqlight.exec("BEGIN IMMEDIATE", on: conn))
  case f() {
    Ok(Nil) -> sqlight.exec("COMMIT", on: conn)
    Error(e) -> {
      let _ = sqlight.exec("ROLLBACK", on: conn)
      Error(e)
    }
  }
}

fn dispatch(
  ctx: Context,
  conn: sqlight.Connection,
  signer: RemoteActor,
  envelope: Envelope,
  body: String,
) -> Result(Nil, sqlight.Error) {
  let is = fn(type_) { list.contains(envelope.types, type_) }
  case is("Follow"), is("Undo"), is("Accept"), is("Reject") {
    True, _, _, _ -> handle_follow(ctx, conn, signer, envelope, body)
    _, True, _, _ -> handle_undo(conn, signer, body)
    _, _, True, _ ->
      case object_is_follow(body) {
        True -> {
          use state <- result.try(follows.is_following(conn, signer.id))
          case state {
            Some(follows.Pending) ->
              follows.set_following_accepted(conn, signer.id)
            _ -> Ok(Nil)
          }
        }
        False -> Ok(Nil)
      }
    _, _, _, True ->
      case object_is_follow(body) {
        True -> follows.remove_following(conn, signer.id)
        False -> Ok(Nil)
      }
    _, _, _, _ -> Ok(Nil)
  }
}

/// `Undo` of a Follow: embedded as an object, or by the id of the Follow we
/// stored. Only ever touches the signer's own follower row.
fn handle_undo(
  conn: sqlight.Connection,
  signer: RemoteActor,
  body: String,
) -> Result(Nil, sqlight.Error) {
  case embedded_types(body), object_iri(body) {
    Some(types), _ ->
      case list.contains(types, "Follow") {
        True -> follows.remove_follower(conn, signer.id)
        False -> Ok(Nil)
      }
    None, Some(iri) -> follows.remove_follower_by_follow(conn, signer.id, iri)
    None, None -> Ok(Nil)
  }
}

fn handle_follow(
  ctx: Context,
  conn: sqlight.Connection,
  signer: RemoteActor,
  envelope: Envelope,
  body: String,
) -> Result(Nil, sqlight.Error) {
  let object =
    json.parse(body, decode.at(["object"], ap_decode.iri()))
    |> option.from_result
  case object == Some(config.actor_id(ctx.config)) {
    False -> Ok(Nil)
    True -> {
      let now = ctx.now()
      use was_follower <- result.try(follows.is_follower(conn, signer.id))
      use _ <- result.try(follows.add_follower(
        conn,
        signer.id,
        envelope.id,
        now,
      ))
      use _ <- result.try(case was_follower {
        True -> Ok(Nil)
        False -> notifications.add_follow(conn, signer.id, envelope.id, now)
      })
      let accept =
        activities.accept(ctx.config, envelope.id, signer.uri)
        |> json.to_string
      deliveries.enqueue(conn, [signer.inbox], accept, now)
    }
  }
}

/// Whether the activity's `object` is a `Follow`, or a bare IRI (which may
/// well be one; only the signer's own state is touched by Accept and Reject).
fn object_is_follow(body: String) -> Bool {
  case embedded_types(body) {
    Some(types) -> list.contains(types, "Follow")
    None -> option.is_some(object_iri(body))
  }
}

fn embedded_types(body: String) -> option.Option(List(String)) {
  let decoder =
    decode.optionally_at(
      ["object", "type"],
      None,
      ap_decode.type_names() |> decode.map(Some),
    )
  json.parse(body, decoder) |> result.unwrap(None)
}

fn object_iri(body: String) -> option.Option(String) {
  json.parse(body, decode.at(["object"], decode.string)) |> option.from_result
}
