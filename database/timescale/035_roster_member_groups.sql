-- +goose Up
-- Player labels inside rosters are distinct from roster_groups, which groups
-- whole rosters. Existing members remain in Main (NULL) after this upgrade.
CREATE TABLE public.roster_member_groups (
    id uuid NOT NULL DEFAULT uuidv7(),
    server_id text NOT NULL,
    name text NOT NULL,
    position integer NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    UNIQUE (server_id, id),
    UNIQUE (server_id, name),
    FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE,
    CHECK (length(btrim(name)) BETWEEN 1 AND 49),
    CHECK (position >= 0)
);

CREATE TABLE public.roster_member_group_settings (
    roster_id uuid NOT NULL,
    member_group_id uuid NOT NULL,
    server_id text NOT NULL,
    signup_enabled boolean NOT NULL DEFAULT false,
    position integer NOT NULL DEFAULT 0,
    role_id text,
    PRIMARY KEY (roster_id, member_group_id),
    FOREIGN KEY (roster_id, server_id) REFERENCES public.rosters(id, server_id) ON DELETE CASCADE,
    FOREIGN KEY (server_id, member_group_id) REFERENCES public.roster_member_groups(server_id, id) ON DELETE CASCADE,
    CHECK (position >= 0),
    CHECK (role_id IS NULL OR role_id ~ '^[0-9]{15,20}$')
);

ALTER TABLE public.roster_members ADD COLUMN member_group_id uuid;
ALTER TABLE public.roster_members ADD CONSTRAINT roster_members_group_fkey
    FOREIGN KEY (roster_id, member_group_id)
    REFERENCES public.roster_member_group_settings(roster_id, member_group_id)
    DEFERRABLE INITIALLY IMMEDIATE;

CREATE INDEX roster_members_group_idx ON public.roster_members(roster_id, member_group_id)
    WHERE member_group_id IS NOT NULL;
CREATE INDEX roster_member_group_settings_server_idx ON public.roster_member_group_settings(server_id, member_group_id);

-- +goose Down
-- Removing this feature discards group definitions/settings/assignments; take a
-- backup before rolling back a database where users have configured labels.
ALTER TABLE public.roster_members DROP CONSTRAINT roster_members_group_fkey;
ALTER TABLE public.roster_members DROP COLUMN member_group_id;
DROP TABLE public.roster_member_group_settings;
DROP TABLE public.roster_member_groups;
