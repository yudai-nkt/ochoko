//// `GET /api/v1/instance` and `GET /api/v2/instance`.

import gleam/http.{Get}
import gleam/json
import gleam/option.{Some}
import gleam/result
import ochoko/api/present
import ochoko/context.{type Context}
import ochoko/db
import ochoko/store/statuses
import ochoko_shared/mastodon
import wisp.{type Request, type Response}

const version = "4.3.0 (compatible; ochoko 0.1.0)"

/// Limits advertised to clients. Characters and media follow the server's
/// behaviour; everything else is unsupported and reported as 0, except the
/// profile text limits, which are generous.
fn configuration() -> mastodon.InstanceConfiguration {
  mastodon.InstanceConfiguration(
    max_characters: 500,
    max_media_attachments: 0,
    characters_reserved_per_url: 23,
    supported_mime_types: [],
    image_size_limit: 0,
    image_matrix_limit: 0,
    video_size_limit: 0,
    video_frame_rate_limit: 0,
    video_matrix_limit: 0,
    poll_max_options: 0,
    poll_max_characters_per_option: 0,
    poll_min_expiration: 0,
    poll_max_expiration: 0,
    max_featured_tags: 0,
    max_pinned_statuses: 0,
    max_display_name_length: 30,
    max_note_length: 500,
    max_avatar_description_length: 0,
    max_header_description_length: 0,
    max_profile_fields: 0,
    profile_field_name_limit: 0,
    profile_field_value_limit: 0,
  )
}

pub fn v1(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  db.with_connection(ctx.db_path, fn(conn) {
    let status_count =
      statuses.count_by_actor(conn, option.None) |> result.unwrap(0)
    mastodon.InstanceV1(
      uri: ctx.config.host,
      title: "ochoko",
      description: "",
      short_description: "",
      email: "",
      version:,
      languages: ["en"],
      registrations: False,
      approval_required: False,
      streaming_api: "",
      user_count: 1,
      status_count:,
      domain_count: 0,
      invites_enabled: False,
      configuration: configuration(),
      contact_account: Some(present.local_account(ctx, conn)),
    )
    |> mastodon.instance_v1_to_json
  })
  |> respond
}

pub fn v2(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Get)
  db.with_connection(ctx.db_path, fn(conn) {
    mastodon.InstanceV2(
      domain: ctx.config.host,
      title: "ochoko",
      version:,
      source_url: "https://github.com/yudai-nkt/ochoko",
      description: "",
      languages: ["en"],
      configuration: configuration(),
      streaming_url: "",
      registrations_enabled: False,
      registrations_approval_required: False,
      api_version: 2,
      contact_email: "",
      contact_account: present.local_account(ctx, conn),
      active_month_users: 1,
      thumbnail_url: "https://" <> ctx.config.host <> "/static/avatar.png",
    )
    |> mastodon.instance_v2_to_json
  })
  |> respond
}

fn respond(body: json.Json) -> Response {
  wisp.json_response(json.to_string(body), 200)
}
