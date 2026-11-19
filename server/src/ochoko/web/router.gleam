import ochoko/context.{type Context}
import wisp.{type Request, type Response}

pub fn handle_request(req: Request, _ctx: Context) -> Response {
  case wisp.path_segments(req) {
    ["health"] -> wisp.ok() |> wisp.string_body("ok")
    _ -> wisp.not_found()
  }
}
