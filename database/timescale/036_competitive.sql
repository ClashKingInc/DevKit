-- +goose Up
ALTER TABLE dashboard_role_grants DROP CONSTRAINT dashboard_role_grants_section_check;
ALTER TABLE dashboard_role_grants ADD CONSTRAINT dashboard_role_grants_section_check CHECK (section IN ('settings','logs','clans','rosters','links','moderation','roles','reminders','autoboards','giveaways','panels','tickets','embeds','wars','leaderboards','competitive'));
CREATE TABLE competitive_profiles (
    user_id text PRIMARY KEY REFERENCES auth_users(user_id) ON DELETE CASCADE,
    display_name text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 50),
    avatar_url text,
    banner_url text,
    private boolean NOT NULL DEFAULT true,
    hide_discord boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE competitive_teams (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    server_id text NOT NULL,
    clan_tag text NOT NULL REFERENCES basic_clan(tag),
    internal_name text NOT NULL CHECK (length(internal_name) BETWEEN 1 AND 80),
    size smallint NOT NULL CHECK (size IN (2,3,5,10)),
    archived boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX competitive_teams_clan ON competitive_teams(clan_tag);
CREATE TABLE competitive_team_members (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    team_id uuid NOT NULL REFERENCES competitive_teams(id),
    player_tag text NOT NULL,
    user_id text NOT NULL,
    joined_at timestamptz NOT NULL DEFAULT now(),
    accepted_at timestamptz,
    left_at timestamptz,
    CHECK (left_at IS NULL OR left_at >= joined_at)
);
CREATE UNIQUE INDEX competitive_active_team_member ON competitive_team_members(team_id,player_tag) WHERE left_at IS NULL;
CREATE TABLE competitive_tournaments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    server_id text NOT NULL,
    name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
    format text NOT NULL CHECK (format IN ('single_elimination','double_elimination','round_robin','swiss','elo')),
    team_size smallint NOT NULL CHECK (team_size IN (2,3,5,10)),
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','registration','active','completed','cancelled')),
    rules text NOT NULL DEFAULT '',
    min_town_hall smallint NOT NULL DEFAULT 1 CHECK (min_town_hall BETWEEN 1 AND 30),
    max_town_hall smallint NOT NULL DEFAULT 30 CHECK (max_town_hall BETWEEN 1 AND 30),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at),
    CHECK (max_town_hall >= min_town_hall)
);
CREATE TABLE competitive_participants (
    tournament_id uuid NOT NULL REFERENCES competitive_tournaments(id),
    team_id uuid NOT NULL REFERENCES competitive_teams(id),
    joined_at timestamptz NOT NULL DEFAULT now(),
    withdrawn_at timestamptz,
    checked_in_at timestamptz,
    roster jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(roster)='array'),
    PRIMARY KEY (tournament_id,team_id)
);
CREATE TABLE competitive_matches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id uuid NOT NULL REFERENCES competitive_tournaments(id),
    round integer NOT NULL DEFAULT 1 CHECK (round > 0),
    home_team_id uuid NOT NULL REFERENCES competitive_teams(id),
    away_team_id uuid NOT NULL REFERENCES competitive_teams(id),
    war_id text,
    home_score numeric,
    away_score numeric,
    penalty jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','active','completed','cancelled')),
    CHECK (home_team_id <> away_team_id),
    FOREIGN KEY (tournament_id,home_team_id) REFERENCES competitive_participants(tournament_id,team_id),
    FOREIGN KEY (tournament_id,away_team_id) REFERENCES competitive_participants(tournament_id,team_id)
);
CREATE TABLE competitive_role_grants (
    server_id text NOT NULL,
    role_id text NOT NULL,
    permission text NOT NULL CHECK (permission IN ('teams','tournaments','participants','matches','scores','penalties','permissions')),
    PRIMARY KEY (server_id,role_id,permission)
);
CREATE TABLE competitive_audit (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    server_id text NOT NULL,
    actor_id text NOT NULL,
    action text NOT NULL,
    entity_id text NOT NULL,
    before_data jsonb,
    after_data jsonb,
    reason text NOT NULL DEFAULT '',
    occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX competitive_audit_server ON competitive_audit(server_id,occurred_at DESC);
-- +goose Down
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'Competitive membership and audit history require a backup or data-preserving forward migration'; END $$;
-- +goose StatementEnd
