-- +goose Up
ALTER TABLE rosters
  ADD COLUMN max_signups integer CHECK (max_signups BETWEEN 1 AND 500),
  ADD COLUMN require_verified boolean NOT NULL DEFAULT false,
  ADD COLUMN hero_red_percent smallint NOT NULL DEFAULT 50,
  ADD COLUMN hero_yellow_percent smallint NOT NULL DEFAULT 75,
  ADD COLUMN hero_green_percent smallint NOT NULL DEFAULT 90,
  ADD CONSTRAINT roster_hero_gradient_bounds CHECK (
    0 <= hero_red_percent AND hero_red_percent < hero_yellow_percent
    AND hero_yellow_percent < hero_green_percent AND hero_green_percent <= 100
  );

-- +goose Down
ALTER TABLE rosters
  DROP CONSTRAINT roster_hero_gradient_bounds,
  DROP COLUMN hero_green_percent,
  DROP COLUMN hero_yellow_percent,
  DROP COLUMN hero_red_percent,
  DROP COLUMN require_verified,
  DROP COLUMN max_signups;
