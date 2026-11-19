//// Outbound ActivityPub activities. Ids are `https://{host}/activities/{id}`.

import gleam/int
import gleam/json
import gleam/time/timestamp
import ochoko/config.{type Config}
import ochoko/id

const context_url = "https://www.w3.org/ns/activitystreams"

fn new_id(c: Config) -> String {
  "https://"
  <> c.host
  <> "/activities/"
  <> int.to_string(id.generate(timestamp.system_time()))
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
  #(activity_id, activity(c, activity_id, "Follow", json.string(object)))
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
