-- +goose Up
-- Keep the latest observation for each clan/weekend. This is game history,
-- not delivery bookkeeping. Completed weekends cannot regress to ongoing.
CREATE TABLE public.capital_raid_history (
    clan_tag text NOT NULL,
    start_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone NOT NULL,
    state text NOT NULL,
    data jsonb NOT NULL,
    observed_at timestamp with time zone NOT NULL DEFAULT now(),
    PRIMARY KEY (clan_tag, start_time),
    CONSTRAINT capital_raid_history_tag CHECK (clan_tag ~ '^#[0289PYLQGRJCUV]{1,15}$'),
    CONSTRAINT capital_raid_history_times CHECK (end_time > start_time),
    CONSTRAINT capital_raid_history_state CHECK (state IN ('ongoing', 'ended')),
    CONSTRAINT capital_raid_history_data CHECK (jsonb_typeof(data) = 'object')
);
CREATE INDEX capital_raid_history_start_time_idx ON public.capital_raid_history (start_time);

-- +goose Down
DROP TABLE public.capital_raid_history;
