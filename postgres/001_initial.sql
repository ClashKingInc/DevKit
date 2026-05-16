-- +goose Up
CREATE TABLE servers (
    id text PRIMARY KEY,
    name text NOT NULL
);


CREATE TABLE server_clans (
    tag text NOT NULL,
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    category_id uuid NOT NULL,
    clan_channel_id text DEFAULT NULL,
    PRIMARY KEY (tag, server_id)
);

CREATE TABLE clan_categories (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    name text NOT NULL,
    UNIQUE (server_id, name)
);

CREATE TABLE clan_logs (
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    clan_tag text NOT NULL,
    type text NOT NULL,
    webhook_token text NOT NULL,
    thread_id text,
    PRIMARY KEY (server_id, clan_tag, type),
    FOREIGN KEY (clan_tag, server_id)
        REFERENCES server_clans(tag, server_id)
        ON DELETE CASCADE
);

CREATE TABLE server_roles (

)

CREATE TABLE clan_position_roles (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    clan_tag text,
    position text NOT NULL CHECK (position IN ('member', 'elder', 'coleader', 'leader')),
    role_id text NOT NULL,
    FOREIGN KEY (clan_tag, server_id)
        REFERENCES server_clans(tag, server_id)
        ON DELETE CASCADE
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

CREATE TABLE rosters (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    linked_clan_tag text NOT NULL,
    title text NOT NULL,
    description text NOT NULL,
    max_size int NOT NULL,
    minimum_townhall int,
    maximum_townhall int,
    image_url text,
    signup_role_id text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE roster_groups (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    name text NOT NULL,
    PRIMARY KEY (server_id, name)
);

CREATE TABLE roster_members (
    tag text NOT NULL,
    roster_id uuid NOT NULL REFERENCES rosters(id) ON DELETE CASCADE,
    roster_group_id uuid,
    PRIMARY KEY (tag, roster_id)
);

CREATE TABLE player_links (
    tag text NOT NULL,
);

CREATE TABLE strikes (
    id text NOT NULL,
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    tag text NOT NULL,
    date_created timestamptz NOT NULL,
    reason text NOT NULL,
    added_by text NOT NULL,
    strike_weight int, -- if the weight is NULL, then the strike is a BAN
    rollover_date timestamptz,
    PRIMARY KEY (id, server_id)
);

CREATE INDEX idx_strikes_tag
    ON strikes (tag);

CREATE INDEX idx_strikes_server_id
    ON strikes (server_id);

CREATE TABLE audit_history (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    resource_id uuid,
    resource_type text NOT NULL,
    description text NOT NULL,
    user_id text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE one_time_login_tokens (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id text NOT NULL,
    token_hash text NOT NULL UNIQUE,
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_one_time_login_tokens_user_id
    ON one_time_login_tokens (user_id);

CREATE INDEX idx_one_time_login_tokens_expires_at
    ON one_time_login_tokens (expires_at);


CREATE TABLE basic_clan (
    tag text PRIMARY KEY,
    name text NOT NULL,
    location_id int NOT NULL,
    cwl_league_id int NOT NULL,
    public_war_log boolean NOT NULL,
    war_wins int NOT NULL,
    member_count int NOT NULL,
    badge_url text NOT NULL,
    troops_donated int NOT NULL,
    troops_received int NOT NULL
);

CREATE MATERIALIZED VIEW war_league_counts AS
SELECT
    c.cwl_league_id,
    count(*) AS clan_count
FROM basic_clan c
GROUP BY c.cwl_league_id;

CREATE MATERIALIZED VIEW clan_leaderboards AS
SELECT
    c.tag,
    c.location_id,
    rank() OVER (
        ORDER BY c.troops_donated DESC, c.tag
    ) AS donated_rank,
    rank() OVER (
        ORDER BY c.troops_received DESC, c.tag
    ) AS received_rank,
    rank() OVER (
        ORDER BY c.war_wins DESC, c.tag
    ) AS war_wins_rank,
    rank() OVER (
        PARTITION BY c.location_id
        ORDER BY c.troops_donated DESC, c.tag
    ) AS location_donated_rank,
    rank() OVER (
        PARTITION BY c.location_id
        ORDER BY c.troops_received DESC, c.tag
    ) AS location_received_rank,
    rank() OVER (
        PARTITION BY c.location_id
        ORDER BY c.war_wins DESC, c.tag
    ) AS location_war_wins_rank
FROM basic_clan c;

CREATE UNIQUE INDEX idx_clan_leaderboards_tag
    ON clan_leaderboards (tag);

CREATE INDEX idx_clan_leaderboards_donated_rank
    ON clan_leaderboards (donated_rank);

CREATE INDEX idx_clan_leaderboards_received_rank
    ON clan_leaderboards (received_rank);

CREATE INDEX idx_clan_leaderboards_war_wins_rank
    ON clan_leaderboards (war_wins_rank);

CREATE INDEX idx_clan_leaderboards_location_donated_rank
    ON clan_leaderboards (location_id, location_donated_rank);

CREATE INDEX idx_clan_leaderboards_location_received_rank
    ON clan_leaderboards (location_id, location_received_rank);

CREATE INDEX idx_clan_leaderboards_location_war_wins_rank
    ON clan_leaderboards (location_id, location_war_wins_rank);

CREATE TABLE hall_counts (
    village_type int NOT NULL,
    level int NOT NULL,
    total_count int NOT NULL,
    PRIMARY KEY (village_type, level)
)

-- +goose Down
