//// Outgoing delivery worker. Rows are claimed from the `deliveries` table
//// and each is delivered in its own unlinked process with its own database
//// connection, so a slow remote host cannot hold up the others.
////
//// `run_once` only claims and spawns; it does not wait for the workers.
//// Tests that need to observe completion use `run_once_and_wait`.

import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/uri
import ochoko/config
import ochoko/context.{type Context}
import ochoko/db
import ochoko/http_transport
import ochoko/signature
import ochoko/store/deliveries.{type Delivery}
import wisp

pub const backoff_seconds = [
  60,
  300,
  1800,
  7200,
  21_600,
  43_200,
  86_400,
  86_400,
  86_400,
]

const batch_size = 16

const lock_seconds = 60

const tick_ms = 5000

type Outcome {
  Delivered
  Retry(reason: String)
  Drop(reason: String)
}

/// Claim up to 16 due rows and start a worker for each. Returns the number
/// claimed immediately, without waiting for the workers.
pub fn run_once(ctx: Context) -> Int {
  list.length(dispatch(ctx))
}

/// Like `run_once`, but waits (up to `timeout_ms` per worker) for the
/// workers to finish. Intended for tests.
pub fn run_once_and_wait(ctx: Context, timeout_ms: Int) -> Int {
  let done = dispatch(ctx)
  list.each(done, fn(subject) { process.receive(subject, timeout_ms) })
  list.length(done)
}

fn dispatch(ctx: Context) -> List(Subject(Nil)) {
  let claimed =
    db.with_connection(ctx.db_path, fn(conn) {
      deliveries.claim_due(conn, ctx.now(), batch_size, lock_seconds)
    })
  case claimed {
    Ok(rows) ->
      list.map(rows, fn(row) {
        let done = process.new_subject()
        process.spawn_unlinked(fn() {
          deliver(ctx, row)
          process.send(done, Nil)
        })
        done
      })
    Error(_) -> {
      wisp.log_warning("delivery: failed to claim rows")
      []
    }
  }
}

fn deliver(ctx: Context, row: Delivery) -> Nil {
  let outcome = attempt(ctx, row)
  db.with_connection(ctx.db_path, fn(conn) {
    let _ = case outcome {
      Delivered -> deliveries.delete(conn, row.id)
      Drop(reason) -> {
        wisp.log_warning(
          "delivery: dropping " <> row.inbox <> " (" <> reason <> ")",
        )
        deliveries.delete(conn, row.id)
      }
      Retry(reason) ->
        case list.drop(backoff_seconds, row.attempts) {
          [delay, ..] ->
            deliveries.reschedule(
              conn,
              row.id,
              row.attempts + 1,
              deliveries.unix(ctx.now()) + delay,
            )
          [] -> {
            wisp.log_warning(
              "delivery: giving up on "
              <> row.inbox
              <> " after "
              <> int.to_string(row.attempts)
              <> " attempts ("
              <> reason
              <> ")",
            )
            deliveries.delete(conn, row.id)
          }
        }
    }
    Nil
  })
}

fn attempt(ctx: Context, row: Delivery) -> Outcome {
  case uri.parse(row.inbox) |> result.try(request.from_uri) {
    Error(_) -> Drop("invalid inbox URL")
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Post)
        |> request.set_header("content-type", "application/activity+json")
        |> request.set_body(row.body)
        |> signature.sign(ctx.private_key, config.key_id(ctx.config), ctx.now())
      case ctx.send(req) {
        Ok(res) -> classify(res)
        Error(e) -> Retry(http_transport.describe_error(e))
      }
    }
  }
}

fn classify(res: response.Response(String)) -> Outcome {
  let status = res.status
  case status {
    _ if status >= 200 && status < 300 -> Delivered
    408 | 429 -> Retry("status " <> int.to_string(status))
    _ if status >= 500 -> Retry("status " <> int.to_string(status))
    _ -> Drop("status " <> int.to_string(status))
  }
}

pub type Msg {
  Tick
}

/// Start the worker actor, which runs `run_once` every 5 seconds.
pub fn start(
  ctx: Context,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send(self, Tick)
    actor.initialised(self) |> actor.returning(self) |> Ok
  })
  |> actor.on_message(fn(self, msg) {
    let Tick = msg
    let _ = run_once(ctx)
    let _ = process.send_after(self, tick_ms, Tick)
    actor.continue(self)
  })
  |> actor.start
}
