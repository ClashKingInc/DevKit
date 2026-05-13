-- +goose Up
CREATE TABLE servers (
    id text PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE server_clans (
    tag text NOT NULL,
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    clan_channel_id text DEFAULT NULL,
    PRIMARY KEY (tag, server_id)
);

CREATE TABLE clan_position_roles (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    clan_tag text,
    position text NOT NULL CHECK (position IN ('member', 'elder', 'coleader', 'leader')),
    role_id text NOT NULL
);

CREATE UNIQUE INDEX idx_clan_position_roles_clan
    ON clan_position_roles (server_id, clan_tag, position)
    WHERE clan_tag IS NOT NULL;

CREATE UNIQUE INDEX idx_clan_position_roles_global
    ON clan_position_roles (server_id, position)
    WHERE clan_tag IS NULL;


CREATE TABLE bases (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    message_id text NOT NULL,
    base_link text NOT NULL,
    downloads integer NOT NULL DEFAULT 0,
    upvotes integer NOT NULL DEFAULT 0,
    downvotes integer NOT NULL DEFAULT 0,
    downloaders text[] NOT NULL DEFAULT '{}',
    whitelisted_role_id text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE hall_roles (
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    role_id text NOT NULL,
    hall_level int NOT NULL,
    is_townhall boolean NOT NULL,
    PRIMARY KEY (server_id, hall_level, is_townhall)
);

CREATE TABLE league_roles (
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    league_id int NOT NULL ,
    role_id text NOT NULL,
    PRIMARY KEY (server_id, league_id)
);

CREATE TABLE basic_clan (
    tag text PRIMARY KEY,
    name text NOT NULL
);

-- +goose Down
