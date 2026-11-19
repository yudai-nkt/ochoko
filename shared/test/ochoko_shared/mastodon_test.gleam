import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/time/timestamp
import ochoko_shared/mastodon.{Direct, Private, Public, Unlisted}

pub fn visibility_to_string_test() {
  assert mastodon.visibility_to_string(Public) == "public"
  assert mastodon.visibility_to_string(Unlisted) == "unlisted"
  assert mastodon.visibility_to_string(Private) == "private"
  assert mastodon.visibility_to_string(Direct) == "direct"
}

fn ts() -> timestamp.Timestamp {
  timestamp.from_unix_seconds(1_795_091_696)
}

fn account() -> mastodon.Account {
  mastodon.Account(
    id: "1",
    username: "me",
    acct: "me",
    url: "https://example.com/@me",
    display_name: "Me",
    note: "<p>hi</p>",
    avatar: "https://example.com/a.png",
    avatar_static: "https://example.com/a.png",
    header: "https://example.com/h.png",
    header_static: "https://example.com/h.png",
    locked: False,
    fields: [
      mastodon.Field(
        name: "web",
        value: "https://example.com",
        verified_at: None,
      ),
    ],
    emojis: [],
    bot: False,
    group: False,
    discoverable: None,
    created_at: ts(),
    last_status_at: None,
    statuses_count: 0,
    followers_count: 0,
    following_count: 0,
    source: None,
  )
}

fn status() -> mastodon.Status {
  mastodon.Status(
    id: "10",
    uri: "https://example.com/notes/10",
    created_at: ts(),
    account: account(),
    content: "<p>hello</p>",
    visibility: Public,
    sensitive: False,
    spoiler_text: "",
    media_attachments: [],
    application: None,
    mentions: [],
    tags: [],
    emojis: [],
    reblogs_count: 0,
    favourites_count: 0,
    replies_count: 0,
    url: None,
    in_reply_to_id: None,
    in_reply_to_account_id: None,
    reblog: None,
    language: None,
    edited_at: None,
    favourited: False,
    reblogged: False,
    muted: False,
    bookmarked: False,
    text: None,
  )
}

fn instance_configuration() -> mastodon.InstanceConfiguration {
  mastodon.InstanceConfiguration(
    max_characters: 5000,
    max_media_attachments: 4,
    characters_reserved_per_url: 23,
  )
}

fn keys(j: json.Json) -> dict.Dict(String, dynamic.Dynamic) {
  let assert Ok(d) =
    json.parse(json.to_string(j), decode.dict(decode.string, decode.dynamic))
  d
}

fn assert_keys(j: json.Json, expected: List(String)) {
  let d = keys(j)
  let missing = list.filter(expected, fn(k) { !dict.has_key(d, k) })
  assert missing == []
}

pub fn account_has_required_keys_test() {
  assert_keys(mastodon.account_to_json(account()), [
    "id", "username", "acct", "url", "display_name", "note", "avatar",
    "avatar_static", "header", "header_static", "locked", "fields", "emojis",
    "bot", "group", "discoverable", "created_at", "last_status_at",
    "statuses_count", "followers_count", "following_count", "roles",
    "feature_approval",
  ])
}

pub fn account_source_only_when_present_test() {
  assert !dict.has_key(keys(mastodon.account_to_json(account())), "source")
  let source =
    mastodon.AccountSource(
      note: "hi",
      fields: [],
      privacy: Public,
      sensitive: False,
      language: None,
    )
  let j =
    mastodon.account_to_json(
      mastodon.Account(..account(), source: Some(source)),
    )
  assert_keys(j, ["source"])
}

pub fn field_has_required_keys_test() {
  assert_keys(mastodon.field_to_json(mastodon.Field("a", "b", None)), [
    "name",
    "value",
    "verified_at",
  ])
}

pub fn status_has_required_keys_test() {
  assert_keys(mastodon.status_to_json(status()), [
    "id", "uri", "created_at", "account", "content", "visibility", "sensitive",
    "spoiler_text", "media_attachments", "mentions", "tags", "emojis",
    "reblogs_count", "favourites_count", "replies_count", "url",
    "in_reply_to_id", "in_reply_to_account_id", "reblog", "poll", "card",
    "language", "edited_at", "favourited", "reblogged", "muted", "bookmarked",
    "application", "quotes_count", "quote_approval",
  ])
}

pub fn status_nullable_keys_are_null_test() {
  let d = keys(mastodon.status_to_json(status()))
  let assert Ok(v) = dict.get(d, "in_reply_to_id")
  assert decode.run(v, decode.optional(decode.string)) == Ok(None)
  list.each(
    [
      "url", "in_reply_to_account_id", "reblog", "poll", "card", "language",
      "edited_at", "application",
    ],
    fn(k) {
      let assert Ok(v) = dict.get(d, k)
      assert decode.run(v, decode.optional(decode.string)) == Ok(None)
    },
  )
}

pub fn status_text_omitted_by_default_test() {
  assert !dict.has_key(keys(mastodon.status_to_json(status())), "text")
  let j =
    mastodon.status_to_json(mastodon.Status(..status(), text: Some("raw")))
  assert_keys(j, ["text"])
}

pub fn media_attachment_has_required_keys_test() {
  let m =
    mastodon.MediaAttachment(
      id: "5",
      kind: mastodon.Image,
      url: Some("https://example.com/m.png"),
      preview_url: "https://example.com/m.png",
      remote_url: None,
      description: None,
      blurhash: None,
    )
  assert_keys(mastodon.media_attachment_to_json(m), [
    "id", "type", "url", "preview_url", "remote_url", "description", "blurhash",
  ])
}

pub fn notification_has_required_keys_test() {
  let n =
    mastodon.Notification(
      id: "7",
      kind: mastodon.FollowNotification,
      created_at: ts(),
      account: account(),
      status: None,
    )
  assert_keys(mastodon.notification_to_json(n), [
    "id", "type", "created_at", "account", "status", "group_key",
  ])
}

pub fn relationship_has_required_keys_test() {
  let r =
    mastodon.Relationship(
      id: "1",
      following: True,
      showing_reblogs: True,
      notifying: False,
      followed_by: False,
      blocking: False,
      blocked_by: False,
      muting: False,
      muting_notifications: False,
      requested: False,
      requested_by: False,
      domain_blocking: False,
      endorsed: False,
      note: "",
      languages: None,
    )
  assert_keys(mastodon.relationship_to_json(r), [
    "id", "following", "showing_reblogs", "notifying", "followed_by", "blocking",
    "blocked_by", "muting", "muting_notifications", "requested", "requested_by",
    "domain_blocking", "endorsed", "note", "languages",
  ])
}

pub fn application_has_required_keys_test() {
  let a =
    mastodon.Application(
      name: "app",
      website: None,
      scopes: ["read"],
      redirect_uris: ["urn:ietf:wg:oauth:2.0:oob"],
      client_id: Some("cid"),
      client_secret: Some("secret"),
      vapid_key: None,
    )
  assert_keys(mastodon.application_to_json(a), [
    "name", "website", "scopes", "redirect_uris", "vapid_key", "client_id",
    "client_secret",
  ])
}

pub fn token_has_required_keys_test() {
  let t =
    mastodon.Token(
      access_token: "x",
      token_type: "Bearer",
      scope: "read write",
      created_at: ts(),
    )
  assert_keys(mastodon.token_to_json(t), [
    "access_token", "token_type", "scope", "created_at",
  ])
}

pub fn instance_v1_has_required_keys_test() {
  let i =
    mastodon.InstanceV1(
      uri: "example.com",
      title: "ochoko",
      description: "",
      short_description: "",
      email: "me@example.com",
      version: "4.3.0",
      languages: ["en"],
      registrations: False,
      approval_required: False,
      streaming_api: "wss://example.com",
      user_count: 1,
      status_count: 0,
      domain_count: 0,
      invites_enabled: False,
      configuration: instance_configuration(),
      contact_account: Some(account()),
    )
  let j = mastodon.instance_v1_to_json(i)
  assert_keys(j, [
    "uri", "title", "description", "short_description", "email", "version",
    "languages", "registrations", "approval_required", "urls", "stats",
    "invites_enabled", "configuration", "contact_account", "thumbnail", "rules",
  ])
  let assert Ok(max) =
    json.parse(
      json.to_string(j),
      decode.at(["configuration", "statuses", "max_characters"], decode.int),
    )
  assert max == 5000
}

pub fn instance_v2_has_required_keys_test() {
  let i =
    mastodon.InstanceV2(
      domain: "example.com",
      title: "ochoko",
      version: "4.3.0",
      source_url: "https://github.com/yudai-nkt/ochoko",
      description: "",
      languages: ["en"],
      configuration: instance_configuration(),
      streaming_url: "wss://example.com",
      registrations_enabled: False,
      contact_email: "me@example.com",
      contact_account: account(),
      active_month_users: 1,
      thumbnail_url: "https://example.com/t.png",
    )
  let j = mastodon.instance_v2_to_json(i)
  assert_keys(j, [
    "domain", "title", "version", "source_url", "description", "usage",
    "thumbnail", "icon", "languages", "configuration", "registrations",
    "api_versions", "contact", "rules",
  ])
  let s = json.to_string(j)
  let assert Ok(n) =
    json.parse(
      s,
      decode.at(
        ["configuration", "statuses", "max_media_attachments"],
        decode.int,
      ),
    )
  assert n == 4
  let assert Ok(r) =
    json.parse(
      s,
      decode.at(
        ["configuration", "statuses", "characters_reserved_per_url"],
        decode.int,
      ),
    )
  assert r == 23
  let assert Ok(enabled) =
    json.parse(s, decode.at(["registrations", "enabled"], decode.bool))
  assert !enabled
  let assert Ok(acct) =
    json.parse(s, decode.at(["contact", "account", "acct"], decode.string))
  assert acct == "me"
}

pub fn search_results_has_required_keys_test() {
  assert_keys(
    mastodon.search_results_to_json(mastodon.SearchResults([], [], [])),
    ["accounts", "statuses", "hashtags"],
  )
}

pub fn context_has_required_keys_test() {
  assert_keys(mastodon.context_to_json(mastodon.Context([], [status()])), [
    "ancestors",
    "descendants",
  ])
}

pub fn error_has_required_keys_test() {
  assert_keys(mastodon.error_to_json(mastodon.Error("nope", None)), ["error"])
  assert_keys(mastodon.error_to_json(mastodon.Error("nope", Some("why"))), [
    "error",
    "error_description",
  ])
}

pub fn timestamp_format_test() {
  assert mastodon.format_timestamp(timestamp.from_unix_seconds(1_795_091_696))
    == "2026-11-19T12:34:56.000Z"
  assert mastodon.format_timestamp(timestamp.from_unix_seconds_and_nanoseconds(
      0,
      7_000_000,
    ))
    == "1970-01-01T00:00:00.007Z"
  assert mastodon.format_timestamp(timestamp.from_unix_seconds_and_nanoseconds(
      951_782_400,
      999_999_999,
    ))
    == "2000-02-29T00:00:00.999Z"
}
