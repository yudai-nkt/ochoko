//// The inbox: authenticates incoming activities by HTTP Signature, attributes
//// them to the signer, drops duplicates and dispatches them.

import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/uri
import ochoko/config
import ochoko/context.{type Context}
import ochoko/crypto/rsa
import ochoko/db
import ochoko/federation/activities
import ochoko/federation/ap_decode
import ochoko/federation/note.{type InboundNote}
import ochoko/federation/remote_actor.{type RemoteActor}
import ochoko/http_client
import ochoko/signature
import ochoko/store/deliveries
import ochoko/store/follows
import ochoko/store/notifications
import ochoko/store/processed_activities
import ochoko/store/remote_actors
import ochoko/store/statuses
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
    Error(remote_actor.DatabaseError(_) as e) -> lookup_failed(parsed, e)
    Error(remote_actor.FetchError(_)) ->
      case list.contains(envelope.types, "Delete") {
        True -> authenticate_stale_delete(ctx, req, parsed, envelope, body)
        False -> wisp.response(401)
      }
    Ok(signer) ->
      case verify_with_refetch(ctx, req, parsed, signer) {
        Error(res) -> res
        Ok(signer) -> attribute(ctx, signer, envelope, body)
      }
  }
}

fn lookup_failed(
  parsed: signature.Parsed,
  e: remote_actor.ActorError,
) -> Response {
  wisp.log_error(
    "inbox: key lookup for "
    <> parsed.key_id
    <> " failed: "
    <> remote_actor.describe_error(e),
  )
  wisp.internal_server_error()
}

/// A `Delete` whose signer cannot be fetched (typically 410 for a deleted
/// actor) is verified against the stored key, however old, so that the
/// actor's deletion still takes effect. Without a stored key it is accepted
/// and ignored.
fn authenticate_stale_delete(
  ctx: Context,
  req: request.Request(String),
  parsed: signature.Parsed,
  envelope: Envelope,
  body: String,
) -> Response {
  case remote_actor.stale_by_key_id(ctx, parsed.key_id) {
    Error(e) -> lookup_failed(parsed, e)
    Ok(None) -> wisp.response(202)
    Ok(Some(signer)) ->
      case verify(ctx, req, parsed, signer) {
        Ok(Nil) -> attribute(ctx, signer, envelope, body)
        Error(_) -> wisp.response(401)
      }
  }
}

/// The activity must be by the signer.
fn attribute(
  ctx: Context,
  signer: RemoteActor,
  envelope: Envelope,
  body: String,
) -> Response {
  case signer.uri == envelope.actor {
    False -> wisp.response(401)
    True -> process(ctx, signer, envelope, body)
  }
}

/// Verifies against the cached key; on a bad signature refetches the actor
/// once (the key may have been rotated), requiring it to list the signing
/// key, and tries again.
fn verify_with_refetch(
  ctx: Context,
  req: request.Request(String),
  parsed: signature.Parsed,
  signer: RemoteActor,
) -> Result(RemoteActor, Response) {
  case verify(ctx, req, parsed, signer) {
    Ok(Nil) -> Ok(signer)
    Error(signature.BadSignature) ->
      case remote_actor.refetch_for_key(ctx, signer.uri, parsed.key_id) {
        Error(remote_actor.DatabaseError(_) as e) ->
          Error(lookup_failed(parsed, e))
        Error(remote_actor.FetchError(_)) -> Error(wisp.response(401))
        Ok(fresh) ->
          case verify(ctx, req, parsed, fresh) {
            Ok(Nil) -> Ok(fresh)
            Error(_) -> Error(wisp.response(401))
          }
      }
    Error(_) -> Error(wisp.response(401))
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
  // Network I/O must not happen while the write transaction is held.
  let inbound = resolve_note(ctx, signer, envelope, body)
  let outcome =
    db.with_connection(ctx.db_path, fn(conn) {
      db.transaction(conn, fn() {
        use seen <- result.try(processed_activities.is_processed(
          conn,
          envelope.id,
        ))
        case seen {
          True -> Ok(Nil)
          False -> {
            use _ <- result.try(dispatch(
              ctx,
              conn,
              signer,
              envelope,
              body,
              inbound,
            ))
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

fn dispatch(
  ctx: Context,
  conn: sqlight.Connection,
  signer: RemoteActor,
  envelope: Envelope,
  body: String,
  inbound: Option(InboundNote),
) -> Result(Nil, sqlight.Error) {
  let is = fn(type_) { list.contains(envelope.types, type_) }
  case is("Create"), is("Delete") {
    True, _ -> handle_create(ctx, conn, signer, inbound)
    _, True -> handle_delete(conn, signer, body)
    _, _ -> dispatch_follow_activity(ctx, conn, signer, envelope, body)
  }
}

fn dispatch_follow_activity(
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

/// For a `Create`, the note it carries, embedded or fetched by IRI. A note
/// is fetched only from the signer's own host and only for an accepted
/// followee, so that activities cannot make us fetch arbitrary URLs.
fn resolve_note(
  ctx: Context,
  signer: RemoteActor,
  envelope: Envelope,
  body: String,
) -> Option(InboundNote) {
  case list.contains(envelope.types, "Create") {
    False -> None
    True ->
      case json.parse(body, decode.at(["object"], decode.dynamic)) {
        Error(_) -> None
        Ok(object) ->
          case decode.run(object, decode.string) {
            Ok(iri) ->
              case
                same_host(iri, signer.uri) && is_accepted_followee(ctx, signer)
              {
                True -> fetch_note(ctx, iri)
                False -> None
              }
            Error(_) -> note.decode(object) |> option.from_result
          }
      }
  }
}

fn is_accepted_followee(ctx: Context, signer: RemoteActor) -> Bool {
  case db.with_connection(ctx.db_path, follows.is_following(_, signer.id)) {
    Ok(Some(follows.Accepted)) -> True
    _ -> False
  }
}

/// Fetches the note at `iri`; it must identify itself by that IRI.
fn fetch_note(ctx: Context, iri: String) -> Option(InboundNote) {
  let fetched = {
    use res <- result.try(
      http_client.signed_get(ctx, iri) |> result.replace_error(Nil),
    )
    case res.status {
      200 -> {
        use data <- result.try(
          json.parse(res.body, decode.dynamic) |> result.replace_error(Nil),
        )
        note.decode(data) |> result.replace_error(Nil)
      }
      _ -> Error(Nil)
    }
  }
  case fetched {
    Ok(n) if n.uri == iri -> Some(n)
    _ -> None
  }
}

fn handle_create(
  ctx: Context,
  conn: sqlight.Connection,
  signer: RemoteActor,
  inbound: Option(InboundNote),
) -> Result(Nil, sqlight.Error) {
  case inbound {
    Some(n) if n.attributed_to == signer.uri ->
      case same_host(n.uri, signer.uri) {
        False -> Ok(Nil)
        True -> {
          use state <- result.try(follows.is_following(conn, signer.id))
          case state {
            Some(follows.Accepted) ->
              statuses.insert_remote(
                conn,
                signer.id,
                n,
                note.visibility(n, signer.followers_uri),
                ctx.now(),
              )
            _ -> Ok(Nil)
          }
        }
      }
    _ -> Ok(Nil)
  }
}

/// A note must live on its author's host, or anyone could squat on URIs.
fn same_host(a: String, b: String) -> Bool {
  case uri.parse(a), uri.parse(b) {
    Ok(a), Ok(b) -> a.host == b.host && option.is_some(a.host)
    _, _ -> False
  }
}

/// `Delete` of the signer itself removes the actor and everything cascading
/// from it; otherwise of one of the signer's own notes.
fn handle_delete(
  conn: sqlight.Connection,
  signer: RemoteActor,
  body: String,
) -> Result(Nil, sqlight.Error) {
  case json.parse(body, decode.at(["object"], ap_decode.iri())) {
    Error(_) -> Ok(Nil)
    Ok(iri) ->
      case iri == signer.uri {
        True -> remote_actors.delete(conn, signer.id)
        False -> statuses.delete_remote(conn, iri, signer.id)
      }
  }
}
