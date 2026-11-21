//// Outbound ActivityPub activities. Ids are `https://{host}/activities/{id}`.

import gleam/json
import gleam/option.{None, Some}
import gleam/time/calendar
import gleam/time/timestamp
import ochoko/config.{type Config}
import ochoko/id
import ochoko/store/statuses.{type StatusRow}
import ochoko_shared/mastodon.{Public, Unlisted}

const context_url = "https://www.w3.org/ns/activitystreams"

/// The `as:Public` collection.
pub const public = "https://www.w3.org/ns/activitystreams#Public"

fn new_id(c: Config) -> String {
  config.activity_uri(c, id.generate(timestamp.system_time()))
}

fn activity(
  c: Config,
  activity_id: String,
  type_: String,
  object: json.Json,
) -> json.Json {
  json.object([
    #("@context", json.string(context_url)),
    #("id", json.string(activity_id)),
    #("type", json.string(type_)),
    #("actor", json.string(config.actor_id(c))),
    #("object", object),
  ])
}

/// A `Follow` of `object`; returns the activity id and the activity.
pub fn follow(c: Config, object: String) -> #(String, json.Json) {
  let activity_id = new_id(c)
  #(activity_id, follow_with_id(c, activity_id, object))
}

/// The `Follow` of `object` with the given id (to send it again).
pub fn follow_with_id(c: Config, activity_id: String, object: String) {
  activity(c, activity_id, "Follow", json.string(object))
}

pub fn undo(c: Config, inner: json.Json) -> json.Json {
  activity(c, new_id(c), "Undo", inner)
}

/// `Accept` of the Follow `follow_id` sent by `follower_uri` to us.
pub fn accept(c: Config, follow_id: String, follower_uri: String) -> json.Json {
  activity(c, new_id(c), "Accept", embedded_follow(c, follow_id, follower_uri))
}

pub fn reject(
  c: Config,
  follow_uri: String,
  follower_uri: String,
) -> json.Json {
  activity(c, new_id(c), "Reject", embedded_follow(c, follow_uri, follower_uri))
}

fn embedded_follow(c: Config, follow_id: String, follower_uri: String) {
  json.object([
    #("id", json.string(follow_id)),
    #("type", json.string("Follow")),
    #("actor", json.string(follower_uri)),
    #("object", json.string(config.actor_id(c))),
  ])
}

/// The `Follow` we sent as `follow_id` to `object`, for embedding in `Undo`.
pub fn sent_follow(c: Config, follow_id: String, object: String) -> json.Json {
  json.object([
    #("id", json.string(follow_id)),
    #("type", json.string("Follow")),
    #("actor", json.string(config.actor_id(c))),
    #("object", json.string(object)),
  ])
}

/// `(to, cc)` of one of our statuses: public ones go to everybody and are
/// copied to our followers, unlisted ones the other way round.
fn addressing(c: Config, s: StatusRow) -> #(List(String), List(String)) {
  let followers = config.followers_uri(c)
  case s.visibility {
    Public -> #([public], [followers])
    Unlisted -> #([followers], [public])
    _ -> #([followers], [])
  }
}

fn strings(values: List(String)) -> json.Json {
  json.array(values, json.string)
}

fn note_fields(c: Config, s: StatusRow) -> List(#(String, json.Json)) {
  let #(to, cc) = addressing(c, s)
  [
    #("id", json.string(s.uri)),
    #("type", json.string("Note")),
    #("attributedTo", json.string(config.actor_id(c))),
    #("content", json.string(s.content_html)),
    #(
      "published",
      json.string(timestamp.to_rfc3339(s.published_at, calendar.utc_offset)),
    ),
    #("url", json.string(option.unwrap(s.url, s.uri))),
    #("to", strings(to)),
    #("cc", strings(cc)),
    #("sensitive", json.bool(s.sensitive)),
    #("summary", case s.spoiler_text {
      "" -> json.null()
      cw -> json.string(cw)
    }),
    ..case s.language {
      Some(code) -> [
        #("contentMap", json.object([#(code, json.string(s.content_html))])),
      ]
      None -> []
    }
  ]
}

/// Our status as a standalone `Note` document.
pub fn note_json(c: Config, s: StatusRow) -> json.Json {
  json.object([#("@context", json.string(context_url)), ..note_fields(c, s)])
}

/// The `Create` activity announcing our status `s`.
pub fn create(c: Config, s: StatusRow) -> json.Json {
  let #(to, cc) = addressing(c, s)
  json.object([
    #("@context", json.string(context_url)),
    #("id", json.string(s.uri <> "/activity")),
    #("type", json.string("Create")),
    #("actor", json.string(config.actor_id(c))),
    #(
      "published",
      json.string(timestamp.to_rfc3339(s.published_at, calendar.utc_offset)),
    ),
    #("to", strings(to)),
    #("cc", strings(cc)),
    #("object", json.object(note_fields(c, s))),
  ])
}

/// The `Tombstone` standing in for a deleted status.
pub fn tombstone_json(s: StatusRow) -> json.Json {
  json.object([
    #("@context", json.string(context_url)),
    #("id", json.string(s.uri)),
    #("type", json.string("Tombstone")),
  ])
}

/// The `Delete` activity retracting our status `s`.
pub fn delete(c: Config, s: StatusRow) -> json.Json {
  json.object([
    #("@context", json.string(context_url)),
    #("id", json.string(new_id(c))),
    #("type", json.string("Delete")),
    #("actor", json.string(config.actor_id(c))),
    #("to", strings([public])),
    #(
      "object",
      json.object([
        #("id", json.string(s.uri)),
        #("type", json.string("Tombstone")),
      ]),
    ),
  ])
}
