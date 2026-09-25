-- +goose Up
-- A bot-authored channel message is not a webhook. Keep its delivery target
-- separate from the legacy webhook destination used by older automations.
CREATE TABLE roster_discord_publications (
  roster_id uuid PRIMARY KEY REFERENCES rosters(id) ON DELETE CASCADE,
  channel_id text NOT NULL CHECK (channel_id ~ '^[0-9]{1,20}$'),
  message_id text NOT NULL CHECK (message_id ~ '^[0-9]{1,20}$'),
  mode text NOT NULL CHECK (mode IN ('signup', 'post')),
  dashboard_url text NOT NULL,
  join_label text NOT NULL CHECK (length(join_label) BETWEEN 1 AND 80),
  remove_label text NOT NULL CHECK (length(remove_label) BETWEEN 1 AND 80),
  view_label text NOT NULL CHECK (length(view_label) BETWEEN 1 AND 80),
  needs_sync boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(channel_id, message_id)
);

-- +goose Down
DROP TABLE roster_discord_publications;
