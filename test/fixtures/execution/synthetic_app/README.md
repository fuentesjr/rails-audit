# synthetic_app

A synthetic, intentionally minimal Rails app fixture. It exists to be the
known-good "happy path" target for the execution-tier sandbox harness
(`docs/execution-tier-proposal.md` §3.1–§3.3, §3.5) — the harness clones it
into a container, `bundle install`s it, loads its schema into a throwaway
Postgres, boots it, and (in a later milestone) runs active_record_doctor
against it. This app is **not** a demonstration of good Rails style; several
things in it are deliberately wrong so the harness has something real to
detect.

This is not a real product, has no test suite of its own, and is not meant
to be run outside the execution-tier harness.

## Pin

- **Ruby 3.4.5** / **Rails ~> 7.2.2** (resolved to 7.2.3.1 in `Gemfile.lock`).
  Chosen because it's a stable, boot-cheap combination with an official
  `ruby:3.4-slim` Docker image, and Rails 7.2 officially supports Ruby 3.4
  (minimum is Ruby 3.1; 3.4 is fully supported, not just tolerated).
- `Gemfile.lock` was generated with `bundle lock` against the real
  rubygems.org index (not hand-authored), so it's a genuinely resolvable
  dependency graph. It was **not** `bundle install`ed on the host — the
  in-container install (a later milestone) is the real test of installability
  (native extensions, platform-specific gems, etc.).

## Only three frameworks loaded

`config/application.rb` requires only `active_model/railtie` and
`active_record/railtie` — no ActionController/View/Mailer/Cable/Storage/Text/
Mailbox. There is no web layer, no routes, no views, no asset pipeline, no JS
bundler, and nothing that needs Redis to boot. `gem "rails"` still pulls in
the full Rails gem graph as a transitive dependency (that's unavoidable —
it's a meta-gem), but none of the unused frameworks' railties/initializers
run.

## Boots from ENV only

No `config/credentials.yml.enc`, no `config/master.key`, no encrypted
credentials anywhere in this fixture. The app boots under a dedicated
`audit` environment (`config/environments/audit.rb`, `RAILS_ENV=audit`) —
deliberately not `development`/`test`, because Rails only falls back to
`ENV["SECRET_KEY_BASE"]` (skipping credentials) for other environments.
Required env vars for boot + eager load:

- `SECRET_KEY_BASE` — any string >= 30 chars.
- `DATABASE_URL` — a `postgresql://...` URL (see `config/database.yml`).

## Seeded active_record_doctor issues

Two conditions, each commented in the model that carries it:

1. **`app/models/user.rb`** — `belongs_to :account`, and `users.account_id`
   (`db/schema.rb`) has no covering index. Targets AR-doctor's
   `unindexed_foreign_keys` check.
2. **`app/models/user.rb`** — `validates :email, uniqueness: true`, but
   `users.email` (`db/schema.rb`) has no matching unique DB index. Targets
   AR-doctor's `missing_unique_indexes` check.

`posts.user_id` is indexed (a normal, non-flagged FK) for contrast.

## What's verified vs. not

Verified on the host (no Docker): `db/schema.rb` parses as valid Ruby,
`Gemfile`/config files parse, `Gemfile.lock` is a real `bundle lock` resolution
against rubygems.org. **Not** verified on the host: that `bundle install`,
`db:schema:load`, and `Rails.application.eager_load!` actually succeed —
that requires Postgres + the resolved gems installed, which is exactly what
the in-container harness (a later milestone) proves.
