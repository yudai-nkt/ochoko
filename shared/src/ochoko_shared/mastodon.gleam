//// Mastodon API entities and their JSON encoders.
////
//// Target-agnostic: depends only on gleam_stdlib, gleam_json and gleam_time.
//// Conventions:
//// - nullable keys (`Option`) are encoded as `null` when `None`;
//// - keys documented as "omitted when None" are left out entirely.
//// Key sets follow masto.js (`src/mastodon/entities/v1`, `v2`).

import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

pub type Visibility {
  Public
  Unlisted
  Private
  Direct
}

pub fn visibility_to_string(v: Visibility) -> String {
  case v {
    Public -> "public"
    Unlisted -> "unlisted"
    Private -> "private"
    Direct -> "direct"
  }
}

// ---------------------------------------------------------------- helpers

fn pad(n: Int, width: Int) -> String {
  string.pad_start(int.to_string(n), width, "0")
}

/// Format as `YYYY-MM-DDTHH:MM:SS.mmmZ` (UTC, millisecond precision).
pub fn format_timestamp(ts: Timestamp) -> String {
  let #(date, time) = timestamp.to_calendar(ts, calendar.utc_offset)
  pad(date.year, 4)
  <> "-"
  <> pad(calendar.month_to_int(date.month), 2)
  <> "-"
  <> pad(date.day, 2)
  <> "T"
  <> pad(time.hours, 2)
  <> ":"
  <> pad(time.minutes, 2)
  <> ":"
  <> pad(time.seconds, 2)
  <> "."
  <> pad(time.nanoseconds / 1_000_000, 3)
  <> "Z"
}

/// Format as `YYYY-MM-DD` (UTC); Mastodon uses this for `last_status_at`.
pub fn format_date(ts: Timestamp) -> String {
  let #(date, _) = timestamp.to_calendar(ts, calendar.utc_offset)
  pad(date.year, 4)
  <> "-"
  <> pad(calendar.month_to_int(date.month), 2)
  <> "-"
  <> pad(date.day, 2)
}

fn time_json(ts: Timestamp) -> Json {
  json.string(format_timestamp(ts))
}

// ---------------------------------------------------------------- shared small entities

pub type CustomEmoji {
  CustomEmoji(
    shortcode: String,
    url: String,
    static_url: String,
    visible_in_picker: Bool,
  )
}

pub fn custom_emoji_to_json(e: CustomEmoji) -> Json {
  json.object([
    #("shortcode", json.string(e.shortcode)),
    #("url", json.string(e.url)),
    #("static_url", json.string(e.static_url)),
    #("visible_in_picker", json.bool(e.visible_in_picker)),
  ])
}

pub type Tag {
  Tag(name: String, url: String)
}

pub fn tag_to_json(t: Tag) -> Json {
  json.object([
    #("id", json.string(t.name)),
    #("name", json.string(t.name)),
    #("url", json.string(t.url)),
    #("history", json.preprocessed_array([])),
  ])
}

pub type Mention {
  Mention(id: String, username: String, url: String, acct: String)
}

pub fn mention_to_json(m: Mention) -> Json {
  json.object([
    #("id", json.string(m.id)),
    #("username", json.string(m.username)),
    #("url", json.string(m.url)),
    #("acct", json.string(m.acct)),
  ])
}

// ---------------------------------------------------------------- account

pub type Field {
  Field(name: String, value: String, verified_at: Option(Timestamp))
}

pub fn field_to_json(f: Field) -> Json {
  json.object([
    #("name", json.string(f.name)),
    #("value", json.string(f.value)),
    #("verified_at", json.nullable(f.verified_at, time_json)),
  ])
}

/// A server role (`Role` in masto.js). Needed by `CredentialAccount`.
pub type Role {
  Role(
    id: Int,
    name: String,
    color: String,
    position: Int,
    permissions: Int,
    highlighted: Bool,
    created_at: Timestamp,
    updated_at: Timestamp,
    collection_limit: Int,
  )
}

pub fn role_to_json(r: Role) -> Json {
  json.object([
    #("id", json.int(r.id)),
    #("name", json.string(r.name)),
    #("color", json.string(r.color)),
    #("position", json.int(r.position)),
    #("permissions", json.int(r.permissions)),
    #("highlighted", json.bool(r.highlighted)),
    #("created_at", time_json(r.created_at)),
    #("updated_at", time_json(r.updated_at)),
    #("collection_limit", json.int(r.collection_limit)),
  ])
}

/// The `source` object of `CredentialAccount` (verify_credentials).
pub type AccountSource {
  AccountSource(
    note: String,
    fields: List(Field),
    privacy: Visibility,
    sensitive: Bool,
    language: Option(String),
    role: Role,
  )
}

fn account_source_to_json(s: AccountSource) -> Json {
  json.object([
    #("note", json.string(s.note)),
    #("fields", json.array(s.fields, field_to_json)),
    #("privacy", json.string(visibility_to_string(s.privacy))),
    #("sensitive", json.bool(s.sensitive)),
    #("language", json.nullable(s.language, json.string)),
    #("attribution_domains", json.preprocessed_array([])),
    #("indexable", json.bool(False)),
    #("quote_policy", json.string("public")),
    #("role", role_to_json(s.role)),
  ])
}

pub type Account {
  Account(
    id: String,
    username: String,
    acct: String,
    url: String,
    display_name: String,
    note: String,
    avatar: String,
    avatar_static: String,
    header: String,
    header_static: String,
    locked: Bool,
    fields: List(Field),
    emojis: List(CustomEmoji),
    bot: Bool,
    group: Bool,
    discoverable: Option(Bool),
    created_at: Timestamp,
    last_status_at: Option(Timestamp),
    statuses_count: Int,
    followers_count: Int,
    following_count: Int,
  )
}

/// The public account representation. Never contains private `source` data;
/// use `CredentialAccount` for verify_credentials.
pub fn account_to_json(a: Account) -> Json {
  json.object(account_fields(a))
}

fn account_fields(a: Account) -> List(#(String, Json)) {
  [
    #("id", json.string(a.id)),
    #("username", json.string(a.username)),
    #("acct", json.string(a.acct)),
    #("url", json.string(a.url)),
    #("display_name", json.string(a.display_name)),
    #("note", json.string(a.note)),
    #("avatar", json.string(a.avatar)),
    #("avatar_static", json.string(a.avatar_static)),
    #("header", json.string(a.header)),
    #("header_static", json.string(a.header_static)),
    #("locked", json.bool(a.locked)),
    #("fields", json.array(a.fields, field_to_json)),
    #("emojis", json.array(a.emojis, custom_emoji_to_json)),
    #("bot", json.bool(a.bot)),
    #("group", json.bool(a.group)),
    #("discoverable", json.nullable(a.discoverable, json.bool)),
    #("created_at", time_json(a.created_at)),
    #(
      "last_status_at",
      json.nullable(a.last_status_at, fn(t) { json.string(format_date(t)) }),
    ),
    #("statuses_count", json.int(a.statuses_count)),
    #("followers_count", json.int(a.followers_count)),
    #("following_count", json.int(a.following_count)),
    #("roles", json.preprocessed_array([])),
    #(
      "feature_approval",
      json.object([
        #("automatic", json.preprocessed_array([])),
        #("manual", json.preprocessed_array([])),
        #("current_user", json.string("unknown")),
      ]),
    ),
  ]
}

/// An account as returned to its owner by verify_credentials / update_credentials:
/// all `Account` fields plus `source` and `role`.
pub type CredentialAccount {
  CredentialAccount(account: Account, source: AccountSource, role: Role)
}

pub fn credential_account_to_json(c: CredentialAccount) -> Json {
  json.object(
    list.append(account_fields(c.account), [
      #("source", account_source_to_json(c.source)),
      #("role", role_to_json(c.role)),
    ]),
  )
}

// ---------------------------------------------------------------- application / token

pub type Application {
  Application(
    name: String,
    website: Option(String),
    scopes: List(String),
    redirect_uris: List(String),
    /// `client_id` is omitted when None (only returned by app registration).
    client_id: Option(String),
    /// `client_secret` is omitted when None (only returned by app registration).
    client_secret: Option(String),
    vapid_key: Option(String),
  )
}

pub fn application_to_json(a: Application) -> Json {
  let base = [
    #("name", json.string(a.name)),
    #("website", json.nullable(a.website, json.string)),
    #("scopes", json.array(a.scopes, json.string)),
    #("redirect_uris", json.array(a.redirect_uris, json.string)),
    #("vapid_key", json.nullable(a.vapid_key, json.string)),
  ]
  let base = case a.client_id {
    Some(v) -> [#("client_id", json.string(v)), ..base]
    None -> base
  }
  let base = case a.client_secret {
    Some(v) -> [#("client_secret", json.string(v)), ..base]
    None -> base
  }
  json.object(base)
}

pub type Token {
  Token(
    access_token: String,
    token_type: String,
    scope: String,
    created_at: Timestamp,
  )
}

/// `created_at` is encoded as Unix seconds (an integer), as Mastodon does.
pub fn token_to_json(t: Token) -> Json {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(t.created_at)
  json.object([
    #("access_token", json.string(t.access_token)),
    #("token_type", json.string(t.token_type)),
    #("scope", json.string(t.scope)),
    #("created_at", json.int(seconds)),
  ])
}

// ---------------------------------------------------------------- media

pub type MediaType {
  Image
  Video
  Gifv
  Audio
  Unknown
}

fn media_type_to_string(t: MediaType) -> String {
  case t {
    Image -> "image"
    Video -> "video"
    Gifv -> "gifv"
    Audio -> "audio"
    Unknown -> "unknown"
  }
}

pub type MediaAttachment {
  MediaAttachment(
    id: String,
    kind: MediaType,
    url: Option(String),
    preview_url: String,
    remote_url: Option(String),
    description: Option(String),
    blurhash: Option(String),
  )
}

pub fn media_attachment_to_json(m: MediaAttachment) -> Json {
  json.object([
    #("id", json.string(m.id)),
    #("type", json.string(media_type_to_string(m.kind))),
    #("url", json.nullable(m.url, json.string)),
    #("preview_url", json.string(m.preview_url)),
    #("remote_url", json.nullable(m.remote_url, json.string)),
    #("description", json.nullable(m.description, json.string)),
    #("blurhash", json.nullable(m.blurhash, json.string)),
  ])
}

// ---------------------------------------------------------------- status

pub type Status {
  Status(
    id: String,
    uri: String,
    created_at: Timestamp,
    account: Account,
    content: String,
    visibility: Visibility,
    sensitive: Bool,
    spoiler_text: String,
    media_attachments: List(MediaAttachment),
    /// Client application; masto.js requires the key, `null` when unknown.
    application: Option(Application),
    mentions: List(Mention),
    tags: List(Tag),
    emojis: List(CustomEmoji),
    reblogs_count: Int,
    favourites_count: Int,
    replies_count: Int,
    url: Option(String),
    in_reply_to_id: Option(String),
    in_reply_to_account_id: Option(String),
    reblog: Option(Status),
    language: Option(String),
    edited_at: Option(Timestamp),
    favourited: Bool,
    reblogged: Bool,
    muted: Bool,
    bookmarked: Bool,
    /// Plain-text source; the `text` key is omitted when None (it only
    /// appears in delete responses).
    text: Option(String),
  )
}

/// Fixed protocol constants for this server version: `poll` and `card` are
/// always `null` (unsupported), `quotes_count` is 0 and `quote_approval`
/// advertises no quoting (`current_user: "denied"`).
pub fn status_to_json(s: Status) -> Json {
  let base = [
    #("id", json.string(s.id)),
    #("uri", json.string(s.uri)),
    #("created_at", time_json(s.created_at)),
    #("account", account_to_json(s.account)),
    #("content", json.string(s.content)),
    #("visibility", json.string(visibility_to_string(s.visibility))),
    #("sensitive", json.bool(s.sensitive)),
    #("spoiler_text", json.string(s.spoiler_text)),
    #(
      "media_attachments",
      json.array(s.media_attachments, media_attachment_to_json),
    ),
    #("application", json.nullable(s.application, application_to_json)),
    #("mentions", json.array(s.mentions, mention_to_json)),
    #("tags", json.array(s.tags, tag_to_json)),
    #("emojis", json.array(s.emojis, custom_emoji_to_json)),
    #("reblogs_count", json.int(s.reblogs_count)),
    #("favourites_count", json.int(s.favourites_count)),
    #("replies_count", json.int(s.replies_count)),
    #("quotes_count", json.int(0)),
    #(
      "quote_approval",
      json.object([
        #("automatic", json.preprocessed_array([])),
        #("manual", json.preprocessed_array([])),
        #("current_user", json.string("denied")),
      ]),
    ),
    #("url", json.nullable(s.url, json.string)),
    #("in_reply_to_id", json.nullable(s.in_reply_to_id, json.string)),
    #(
      "in_reply_to_account_id",
      json.nullable(s.in_reply_to_account_id, json.string),
    ),
    #("reblog", json.nullable(s.reblog, status_to_json)),
    #("poll", json.null()),
    #("card", json.null()),
    #("language", json.nullable(s.language, json.string)),
    #("edited_at", json.nullable(s.edited_at, time_json)),
    #("favourited", json.bool(s.favourited)),
    #("reblogged", json.bool(s.reblogged)),
    #("muted", json.bool(s.muted)),
    #("bookmarked", json.bool(s.bookmarked)),
  ]
  case s.text {
    Some(t) -> json.object([#("text", json.string(t)), ..base])
    None -> json.object(base)
  }
}

// ---------------------------------------------------------------- notification

pub type NotificationType {
  MentionNotification
  ReblogNotification
  FavouriteNotification
  FollowNotification
  FollowRequestNotification
}

pub fn notification_type_to_string(t: NotificationType) -> String {
  case t {
    MentionNotification -> "mention"
    ReblogNotification -> "reblog"
    FavouriteNotification -> "favourite"
    FollowNotification -> "follow"
    FollowRequestNotification -> "follow_request"
  }
}

pub type Notification {
  Notification(
    id: String,
    kind: NotificationType,
    created_at: Timestamp,
    account: Account,
    status: Option(Status),
  )
}

/// `group_key` is derived from the id (`ungrouped-<id>`), as Mastodon does for
/// the non-grouped endpoint.
pub fn notification_to_json(n: Notification) -> Json {
  json.object([
    #("id", json.string(n.id)),
    #("type", json.string(notification_type_to_string(n.kind))),
    #("created_at", time_json(n.created_at)),
    #("account", account_to_json(n.account)),
    #("status", json.nullable(n.status, status_to_json)),
    #("group_key", json.string("ungrouped-" <> n.id)),
  ])
}

// ---------------------------------------------------------------- relationship

pub type Relationship {
  Relationship(
    id: String,
    following: Bool,
    showing_reblogs: Bool,
    notifying: Bool,
    followed_by: Bool,
    blocking: Bool,
    blocked_by: Bool,
    muting: Bool,
    muting_notifications: Bool,
    requested: Bool,
    requested_by: Bool,
    domain_blocking: Bool,
    endorsed: Bool,
    note: String,
    languages: Option(List(String)),
  )
}

pub fn relationship_to_json(r: Relationship) -> Json {
  json.object([
    #("id", json.string(r.id)),
    #("following", json.bool(r.following)),
    #("showing_reblogs", json.bool(r.showing_reblogs)),
    #("notifying", json.bool(r.notifying)),
    #("followed_by", json.bool(r.followed_by)),
    #("blocking", json.bool(r.blocking)),
    #("blocked_by", json.bool(r.blocked_by)),
    #("muting", json.bool(r.muting)),
    #("muting_notifications", json.bool(r.muting_notifications)),
    #("requested", json.bool(r.requested)),
    #("requested_by", json.bool(r.requested_by)),
    #("domain_blocking", json.bool(r.domain_blocking)),
    #("endorsed", json.bool(r.endorsed)),
    #("note", json.string(r.note)),
    #(
      "languages",
      json.nullable(r.languages, fn(l) { json.array(l, json.string) }),
    ),
  ])
}

// ---------------------------------------------------------------- instance

/// Instance limits, supplied by the server so that advertised values match
/// what it enforces. `max_featured_tags` and `max_pinned_statuses` should be 0
/// when the feature is unsupported.
pub type InstanceConfiguration {
  InstanceConfiguration(
    max_characters: Int,
    max_media_attachments: Int,
    characters_reserved_per_url: Int,
    supported_mime_types: List(String),
    image_size_limit: Int,
    image_matrix_limit: Int,
    video_size_limit: Int,
    video_frame_rate_limit: Int,
    video_matrix_limit: Int,
    poll_max_options: Int,
    poll_max_characters_per_option: Int,
    poll_min_expiration: Int,
    poll_max_expiration: Int,
    max_featured_tags: Int,
    max_pinned_statuses: Int,
    max_display_name_length: Int,
    max_note_length: Int,
    max_avatar_description_length: Int,
    max_header_description_length: Int,
    max_profile_fields: Int,
    profile_field_name_limit: Int,
    profile_field_value_limit: Int,
  )
}

fn statuses_configuration(c: InstanceConfiguration) -> #(String, Json) {
  #(
    "statuses",
    json.object([
      #("max_characters", json.int(c.max_characters)),
      #("max_media_attachments", json.int(c.max_media_attachments)),
      #("characters_reserved_per_url", json.int(c.characters_reserved_per_url)),
    ]),
  )
}

fn media_and_polls_configuration(
  c: InstanceConfiguration,
) -> List(#(String, Json)) {
  [
    #(
      "media_attachments",
      json.object([
        #(
          "supported_mime_types",
          json.array(c.supported_mime_types, json.string),
        ),
        #("image_size_limit", json.int(c.image_size_limit)),
        #("image_matrix_limit", json.int(c.image_matrix_limit)),
        #("video_size_limit", json.int(c.video_size_limit)),
        #("video_frame_rate_limit", json.int(c.video_frame_rate_limit)),
        #("video_matrix_limit", json.int(c.video_matrix_limit)),
      ]),
    ),
    #(
      "polls",
      json.object([
        #("max_options", json.int(c.poll_max_options)),
        #(
          "max_characters_per_option",
          json.int(c.poll_max_characters_per_option),
        ),
        #("min_expiration", json.int(c.poll_min_expiration)),
        #("max_expiration", json.int(c.poll_max_expiration)),
      ]),
    ),
  ]
}

pub type InstanceV1 {
  InstanceV1(
    uri: String,
    title: String,
    description: String,
    short_description: String,
    email: String,
    version: String,
    languages: List(String),
    registrations: Bool,
    approval_required: Bool,
    streaming_api: String,
    user_count: Int,
    status_count: Int,
    domain_count: Int,
    invites_enabled: Bool,
    configuration: InstanceConfiguration,
    contact_account: Option(Account),
  )
}

pub fn instance_v1_to_json(i: InstanceV1) -> Json {
  json.object([
    #("uri", json.string(i.uri)),
    // GoToSocial extension; Elk takes the handle's domain from it.
    #("account_domain", json.string(i.uri)),
    #("title", json.string(i.title)),
    #("description", json.string(i.description)),
    #("short_description", json.string(i.short_description)),
    #("email", json.string(i.email)),
    #("version", json.string(i.version)),
    #("languages", json.array(i.languages, json.string)),
    #("registrations", json.bool(i.registrations)),
    #("approval_required", json.bool(i.approval_required)),
    #("urls", json.object([#("streaming_api", json.string(i.streaming_api))])),
    #(
      "stats",
      json.object([
        #("user_count", json.int(i.user_count)),
        #("status_count", json.int(i.status_count)),
        #("domain_count", json.int(i.domain_count)),
      ]),
    ),
    #("invites_enabled", json.bool(i.invites_enabled)),
    #(
      "configuration",
      json.object([
        #(
          "accounts",
          json.object([
            #("max_featured_tags", json.int(i.configuration.max_featured_tags)),
          ]),
        ),
        statuses_configuration(i.configuration),
        ..media_and_polls_configuration(i.configuration)
      ]),
    ),
    #("contact_account", json.nullable(i.contact_account, account_to_json)),
    #("thumbnail", json.null()),
    #("rules", json.preprocessed_array([])),
  ])
}

pub type InstanceV2 {
  InstanceV2(
    domain: String,
    title: String,
    version: String,
    source_url: String,
    description: String,
    languages: List(String),
    configuration: InstanceConfiguration,
    streaming_url: String,
    registrations_enabled: Bool,
    registrations_approval_required: Bool,
    /// Mastodon API version number reported in `api_versions.mastodon`.
    api_version: Int,
    contact_email: String,
    contact_account: Account,
    active_month_users: Int,
    thumbnail_url: String,
  )
}

pub fn instance_v2_to_json(i: InstanceV2) -> Json {
  json.object([
    #("domain", json.string(i.domain)),
    // GoToSocial extension; Elk takes the handle's domain from it.
    #("account_domain", json.string(i.domain)),
    #("title", json.string(i.title)),
    #("version", json.string(i.version)),
    #("source_url", json.string(i.source_url)),
    #("description", json.string(i.description)),
    #(
      "usage",
      json.object([
        #(
          "users",
          json.object([#("active_month", json.int(i.active_month_users))]),
        ),
      ]),
    ),
    #(
      "thumbnail",
      json.object([
        #("url", json.string(i.thumbnail_url)),
        #("blurhash", json.string("")),
        #(
          "versions",
          json.object([
            #("@1x", json.string(i.thumbnail_url)),
            #("@2x", json.string(i.thumbnail_url)),
          ]),
        ),
        #("description", json.string("")),
      ]),
    ),
    #("icon", json.preprocessed_array([])),
    #("languages", json.array(i.languages, json.string)),
    #(
      "configuration",
      json.object([
        #("urls", json.object([#("streaming", json.string(i.streaming_url))])),
        #(
          "accounts",
          json.object([
            #("max_featured_tags", json.int(i.configuration.max_featured_tags)),
            #(
              "max_pinned_statuses",
              json.int(i.configuration.max_pinned_statuses),
            ),
            #(
              "max_display_name_length",
              json.int(i.configuration.max_display_name_length),
            ),
            #("max_note_length", json.int(i.configuration.max_note_length)),
            #(
              "max_avatar_description_length",
              json.int(i.configuration.max_avatar_description_length),
            ),
            #(
              "max_header_description_length",
              json.int(i.configuration.max_header_description_length),
            ),
            #(
              "max_profile_fields",
              json.int(i.configuration.max_profile_fields),
            ),
            #(
              "profile_field_name_limit",
              json.int(i.configuration.profile_field_name_limit),
            ),
            #(
              "profile_field_value_limit",
              json.int(i.configuration.profile_field_value_limit),
            ),
          ]),
        ),
        #("translation", json.object([#("enabled", json.bool(False))])),
        #("vapid", json.object([#("public_key", json.string(""))])),
        statuses_configuration(i.configuration),
        ..media_and_polls_configuration(i.configuration)
      ]),
    ),
    #(
      "registrations",
      json.object([
        #("enabled", json.bool(i.registrations_enabled)),
        #("approval_required", json.bool(i.registrations_approval_required)),
        #("message", json.null()),
      ]),
    ),
    #("api_versions", json.object([#("mastodon", json.int(i.api_version))])),
    #(
      "contact",
      json.object([
        #("email", json.string(i.contact_email)),
        #("account", account_to_json(i.contact_account)),
      ]),
    ),
    #("rules", json.preprocessed_array([])),
  ])
}

// ---------------------------------------------------------------- search / context / error

pub type SearchResults {
  SearchResults(
    accounts: List(Account),
    statuses: List(Status),
    hashtags: List(Tag),
  )
}

pub fn search_results_to_json(r: SearchResults) -> Json {
  json.object([
    #("accounts", json.array(r.accounts, account_to_json)),
    #("statuses", json.array(r.statuses, status_to_json)),
    #("hashtags", json.array(r.hashtags, tag_to_json)),
  ])
}

pub type Context {
  Context(ancestors: List(Status), descendants: List(Status))
}

pub fn context_to_json(c: Context) -> Json {
  json.object([
    #("ancestors", json.array(c.ancestors, status_to_json)),
    #("descendants", json.array(c.descendants, status_to_json)),
  ])
}

pub type Error {
  /// `error_description` is omitted when None.
  Error(error: String, error_description: Option(String))
}

pub fn error_to_json(e: Error) -> Json {
  let base = [#("error", json.string(e.error))]
  case e.error_description {
    Some(d) ->
      json.object(list.append(base, [#("error_description", json.string(d))]))
    None -> json.object(base)
  }
}
