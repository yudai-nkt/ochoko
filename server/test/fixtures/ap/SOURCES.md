# ActivityPub fixtures

Real payloads used to test lenient decoding. Only public accounts and public
posts. Files are unmodified apart from what is noted below.

| File | Source | Fetched |
| --- | --- | --- |
| `mastodon_actor.json` | `curl -H 'Accept: application/activity+json' https://fosstodon.org/users/fosstodon` (Mastodon) | 2026-11-20 |
| `mastodon_note.json` | `curl -H 'Accept: application/activity+json' https://fosstodon.org/users/fosstodon/statuses/117377852752602059` (Mastodon) | 2026-11-20 |
| `misskey_actor.json` | `curl -H 'Accept: application/activity+json' https://misskey.io/users/7rkrarq81i` (Misskey; `acct:syuilo@misskey.io` via WebFinger) | 2026-11-20 |
| `misskey_note.json` | `curl -H 'Accept: application/activity+json' https://misskey.io/notes/atr6idzsmo9z0bgc` (Misskey) | 2026-11-20 |
| `akkoma_actor.json` | `curl -H 'Accept: application/activity+json' https://fedi.absturztau.be/users/mauthausengusen` (Akkoma 3.20.1; a `Service` actor) | 2026-11-20 |
| `akkoma_note.json` | `curl -H 'Accept: application/activity+json' https://fedi.absturztau.be/objects/78a6a39f-ab18-4861-966c-bcccee6bee98` (Akkoma) | 2026-11-20 |
| `gotosocial_actor.json` | GoToSocial `internal/typeutils/internaltoas_test.go`, `TestAccountToAS` expected output (the `the_mighty_zork` testrig account) | 2026-11-20 |
| `gotosocial_note.json` | GoToSocial `internal/typeutils/internaltoas_test.go`, `TestStatusToAS` expected output | 2026-11-20 |

## Notes

- mastodon.social, mastodon.online and hachyderm.io answer unauthenticated
  fetches with 401 (authorized fetch), hence fosstodon.org.
- GoToSocial requires signed fetches, so its samples are the serialized
  output asserted in the project's own tests. Source repository:
  https://codeberg.org/superseriousbusiness/gotosocial at commit
  `bbea3309c43acb32f91e7a4417889690f8b7f35f` (shallow clone of `main`).
  The JSON was extracted verbatim from the Go raw string literals.
- pleroma.envs.net (Akkoma) returns only a stub actor to unsigned requests,
  hence fedi.absturztau.be.
