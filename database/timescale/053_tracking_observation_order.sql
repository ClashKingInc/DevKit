-- +goose Up
-- One current controller row, not an outage/event history. The recovery state
-- commits with clock corrections so a restart cannot apply the same shift twice.
CREATE TABLE tracking_availability (
    singleton boolean NOT NULL DEFAULT true,
    available boolean NOT NULL DEFAULT true,
    official_started_at timestamptz,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    observed_at timestamptz NOT NULL DEFAULT '1970-01-01 00:00:00+00',
    revision bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (singleton),
    CHECK (singleton),
    CHECK (revision >= 0),
    CHECK (NOT available OR official_started_at IS NULL)
);
INSERT INTO tracking_availability (singleton) VALUES (true);

-- Legacy facts have no trustworthy fetch time. Epoch admits the first stamped
-- observation without pretending migration time was an observation of the game.
ALTER TABLE basic_player
    ADD COLUMN observed_at timestamptz NOT NULL DEFAULT '1970-01-01 00:00:00+00';

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM tracking_availability WHERE official_started_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Finish official maintenance recovery before removing tracking availability state';
    END IF;
END;
$$;
-- +goose StatementEnd
ALTER TABLE basic_player DROP COLUMN observed_at;
DROP TABLE tracking_availability;
