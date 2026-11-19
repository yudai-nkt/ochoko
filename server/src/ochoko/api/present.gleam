//// Turns stored data into Mastodon API entities.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import ochoko/config
import ochoko/context.{type Context}
import ochoko/federation/note.{type Attachment}
import ochoko/federation/remote_actor_types.{type RemoteActor}
import ochoko/html
import ochoko/store/follows
import ochoko/store/profile
import ochoko/store/remote_actors
import ochoko/store/statuses.{type StatusRow}
import ochoko_shared/mastodon
import sqlight

/// The id of our own account; remote accounts use `remote_actors.id`.
pub const local_account_id = "0"

/// We store no account creation time, so accounts report the Unix epoch.
fn epoch() -> timestamp.Timestamp {
  timestamp.from_unix_seconds(0)
}

fn or_zero(r: Result(Int, sqlight.Error)) -> Int {
  result.unwrap(r, 0)
}

fn local_profile(conn: sqlight.Connection) -> profile.Profile {
  case profile.get(conn) {
    Ok(p) -> p
    Error(_) -> profile.Profile("", "", None, None)
  }
}

fn default_avatar(ctx: Context) -> String {
  "https://" <> ctx.config.host <> "/static/avatar.png"
}

fn default_header(ctx: Context) -> String {
  "https://" <> ctx.config.host <> "/static/header.png"
}

pub fn local_account(
  ctx: Context,
  conn: sqlight.Connection,
) -> mastodon.Account {
  let p = local_profile(conn)
  let avatar = option.unwrap(p.avatar_url, default_avatar(ctx))
  let header = option.unwrap(p.header_url, default_header(ctx))
  mastodon.Account(
    id: local_account_id,
    username: ctx.config.handle,
    acct: ctx.config.handle,
    url: config.actor_id(ctx.config),
    display_name: case p.display_name {
      "" -> ctx.config.handle
      name -> name
    },
    note: html.text_to_html(p.note),
    avatar:,
    avatar_static: avatar,
    header:,
    header_static: header,
    locked: False,
    fields: [],
    emojis: [],
    bot: False,
    group: False,
    discoverable: Some(True),
    created_at: epoch(),
    last_status_at: None,
    statuses_count: or_zero(statuses.count_by_actor(conn, None)),
    followers_count: or_zero(follows.follower_count(conn)),
    following_count: or_zero(follows.following_count(conn)),
  )
}

/// `verify_credentials`: the local account plus its private `source`.
pub fn credential_account(
  ctx: Context,
  conn: sqlight.Connection,
) -> mastodon.CredentialAccount {
  let role =
    mastodon.Role(
      id: 3,
      name: "Owner",
      color: "",
      position: 1000,
      permissions: 0,
      highlighted: True,
      created_at: epoch(),
      updated_at: epoch(),
      collection_limit: 0,
    )
  mastodon.CredentialAccount(
    account: local_account(ctx, conn),
    source: mastodon.AccountSource(
      note: local_profile(conn).note,
      fields: [],
      privacy: mastodon.Public,
      sensitive: False,
      language: Some(""),
      role:,
    ),
    role:,
  )
}

/// Remote counters other than statuses are unknown and reported as 0.
/// Missing images fall back to our placeholders.
pub fn remote_account(
  ctx: Context,
  a: RemoteActor,
  conn: sqlight.Connection,
) -> mastodon.Account {
  let avatar = option.unwrap(a.avatar_url, default_avatar(ctx))
  let header = option.unwrap(a.header_url, default_header(ctx))
  mastodon.Account(
    id: int.to_string(a.id),
    username: a.username,
    acct: a.username <> "@" <> a.domain,
    url: option.unwrap(a.url, a.uri),
    display_name: case a.display_name {
      "" -> a.username
      name -> name
    },
    note: a.summary_html,
    avatar:,
    avatar_static: avatar,
    header:,
    header_static: header,
    locked: a.locked,
    fields: [],
    emojis: [],
    bot: a.bot,
    group: False,
    discoverable: None,
    created_at: epoch(),
    last_status_at: None,
    statuses_count: or_zero(statuses.count_by_actor(conn, Some(a.id))),
    followers_count: 0,
    following_count: 0,
  )
}

pub fn relationship(
  conn: sqlight.Connection,
  remote_id: Int,
) -> mastodon.Relationship {
  let state = result.unwrap(follows.is_following(conn, remote_id), None)
  let followed_by = result.unwrap(follows.is_follower(conn, remote_id), False)
  mastodon.Relationship(
    id: int.to_string(remote_id),
    following: state == Some(follows.Accepted),
    showing_reblogs: True,
    notifying: False,
    followed_by:,
    blocking: False,
    blocked_by: False,
    muting: False,
    muting_notifications: False,
    requested: state == Some(follows.Pending),
    requested_by: False,
    domain_blocking: False,
    endorsed: False,
    note: "",
    languages: None,
  )
}

fn media_kind(media_type: option.Option(String)) -> mastodon.MediaType {
  let t = string.lowercase(option.unwrap(media_type, ""))
  case
    string.starts_with(t, "image"),
    string.starts_with(t, "video"),
    string.starts_with(t, "audio")
  {
    True, _, _ -> mastodon.Image
    _, True, _ -> mastodon.Video
    _, _, True -> mastodon.Audio
    _, _, _ -> mastodon.Unknown
  }
}

fn media_attachment(
  row: StatusRow,
  a: Attachment,
  position: Int,
) -> mastodon.MediaAttachment {
  mastodon.MediaAttachment(
    id: int.to_string(row.id) <> "-" <> int.to_string(position),
    kind: media_kind(a.media_type),
    url: Some(a.url),
    preview_url: a.url,
    remote_url: Some(a.url),
    description: a.description,
    blurhash: a.blurhash,
  )
}

/// The `Status` entity of a stored status, or `Error(Nil)` if its author
/// cannot be loaded. Interaction counts are 0 and the viewer flags false;
/// replies point at the parent when it is stored.
pub fn status(
  ctx: Context,
  conn: sqlight.Connection,
  row: StatusRow,
) -> Result(mastodon.Status, Nil) {
  use account <- result.map(case row.actor_id {
    None -> Ok(local_account(ctx, conn))
    Some(id) ->
      case remote_actors.get(conn, id) {
        Ok(Some(actor)) -> Ok(remote_account(ctx, actor, conn))
        _ -> Error(Nil)
      }
  })
  let parent = case row.in_reply_to_uri {
    None -> None
    Some(uri) -> statuses.get_by_uri(conn, uri) |> result.unwrap(None)
  }
  mastodon.Status(
    id: int.to_string(row.id),
    uri: row.uri,
    created_at: row.published_at,
    account:,
    content: row.content_html,
    visibility: row.visibility,
    sensitive: row.sensitive,
    spoiler_text: row.spoiler_text,
    media_attachments: list.index_map(row.attachments, fn(a, i) {
      media_attachment(row, a, i)
    }),
    application: None,
    mentions: [],
    tags: [],
    emojis: [],
    reblogs_count: 0,
    favourites_count: 0,
    replies_count: 0,
    url: row.url,
    in_reply_to_id: option.map(parent, fn(p) { int.to_string(p.id) }),
    in_reply_to_account_id: case parent {
      Some(p) ->
        Some(case p.actor_id {
          Some(id) -> int.to_string(id)
          None -> local_account_id
        })
      None -> None
    },
    reblog: None,
    language: row.language,
    edited_at: None,
    favourited: False,
    reblogged: False,
    muted: False,
    bookmarked: False,
    text: None,
  )
}
