/// Migration SQL scripts. Index + 1 is the schema version stored in
/// `PRAGMA user_version`.
pub fn all() -> List(String) {
  [migration_1]
}

const migration_1 =
  "
CREATE TABLE profile (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  display_name TEXT NOT NULL,
  note TEXT NOT NULL,
  avatar_url TEXT,
  header_url TEXT
);
INSERT INTO profile (id, display_name, note, avatar_url, header_url)
  VALUES (1, '', '', NULL, NULL);
CREATE TRIGGER profile_no_delete BEFORE DELETE ON profile
BEGIN
  SELECT RAISE(ABORT, 'profile row cannot be deleted');
END;

CREATE TABLE remote_actors (
  id INTEGER PRIMARY KEY,
  uri TEXT UNIQUE NOT NULL,
  username TEXT NOT NULL,
  domain TEXT NOT NULL,
  display_name TEXT NOT NULL,
  summary_html TEXT NOT NULL,
  avatar_url TEXT,
  header_url TEXT,
  url TEXT,
  inbox TEXT NOT NULL,
  shared_inbox TEXT,
  followers_uri TEXT,
  public_key_id TEXT NOT NULL,
  public_key_pem TEXT NOT NULL,
  bot INTEGER NOT NULL,
  locked INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL
);

CREATE TABLE following (
  actor_id INTEGER PRIMARY KEY REFERENCES remote_actors ON DELETE CASCADE,
  state TEXT NOT NULL CHECK (state IN ('pending', 'accepted')),
  follow_uri TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE followers (
  actor_id INTEGER PRIMARY KEY REFERENCES remote_actors ON DELETE CASCADE,
  follow_uri TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE statuses (
  id INTEGER PRIMARY KEY,
  uri TEXT UNIQUE NOT NULL,
  actor_id INTEGER REFERENCES remote_actors ON DELETE CASCADE,
  content_html TEXT NOT NULL,
  text TEXT,
  spoiler_text TEXT NOT NULL,
  sensitive INTEGER NOT NULL,
  visibility TEXT NOT NULL CHECK (visibility IN ('public', 'unlisted', 'private', 'direct')),
  url TEXT,
  in_reply_to_uri TEXT,
  language TEXT,
  published_at INTEGER NOT NULL,
  deleted_at INTEGER
);

CREATE TABLE media_attachments (
  id INTEGER PRIMARY KEY,
  status_id INTEGER NOT NULL REFERENCES statuses ON DELETE CASCADE,
  remote_url TEXT NOT NULL,
  media_type TEXT,
  description TEXT,
  blurhash TEXT,
  position INTEGER NOT NULL
);

CREATE TABLE notifications (
  id INTEGER PRIMARY KEY,
  type TEXT NOT NULL CHECK (type IN ('follow')),
  actor_id INTEGER NOT NULL REFERENCES remote_actors ON DELETE CASCADE,
  activity_uri TEXT UNIQUE NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE oauth_apps (
  id INTEGER PRIMARY KEY,
  client_id TEXT UNIQUE NOT NULL,
  client_secret TEXT NOT NULL,
  name TEXT NOT NULL,
  website TEXT,
  redirect_uris TEXT NOT NULL,
  scopes TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE oauth_codes (
  code_hash TEXT PRIMARY KEY,
  app_id INTEGER NOT NULL REFERENCES oauth_apps ON DELETE CASCADE,
  redirect_uri TEXT NOT NULL,
  scopes TEXT NOT NULL,
  code_challenge TEXT,
  expires_at INTEGER NOT NULL
);

CREATE TABLE oauth_tokens (
  token_hash TEXT PRIMARY KEY,
  app_id INTEGER NOT NULL REFERENCES oauth_apps ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('user', 'app')),
  scopes TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE deliveries (
  id INTEGER PRIMARY KEY,
  inbox TEXT NOT NULL,
  body TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  locked_until INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE idempotency_keys (
  key TEXT PRIMARY KEY,
  status_id INTEGER NOT NULL REFERENCES statuses ON DELETE CASCADE,
  created_at INTEGER NOT NULL
);

CREATE TABLE processed_activities (
  uri TEXT PRIMARY KEY,
  received_at INTEGER NOT NULL
);
"
