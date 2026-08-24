//go:build ignore

package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
)

const maxCWLGroupBatchSize = 1000

func main() {
	migrateutil.Main("cwl_groups", runCWLGroups)
}

func runCWLGroups(ctx context.Context, cfg migrateutil.Config) error {
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, `
		ALTER TABLE public.cwl_standings
			DROP CONSTRAINT IF EXISTS cwl_standings_group_clan_fkey;
		ALTER TABLE public.cwl_group_members
			DROP CONSTRAINT IF EXISTS cwl_group_members_group_clan_fkey,
			DROP CONSTRAINT IF EXISTS cwl_group_members_pkey;
		ALTER TABLE public.cwl_group_clans
			DROP CONSTRAINT IF EXISTS cwl_group_clans_cwl_id_fkey,
			DROP CONSTRAINT IF EXISTS cwl_group_clans_pkey;
		ALTER TABLE public.cwl_groups
			DROP CONSTRAINT IF EXISTS cwl_groups_pkey;
		DROP INDEX IF EXISTS public.idx_cwl_groups_season_league;
		DROP INDEX IF EXISTS public.idx_cwl_groups_season_league_size;
		DROP INDEX IF EXISTS public.idx_cwl_group_clans_clan_cwl;
		DROP INDEX IF EXISTS public.idx_cwl_group_members_cwl_id;
		TRUNCATE TABLE
			public.cwl_standings,
			public.cwl_group_members,
			public.cwl_group_clans,
			public.cwl_groups;
	`); err != nil {
		return err
	}
	mongoClient, err := migrateutil.StatsClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer mongoClient.Disconnect(ctx)
	batchSize := min(cfg.BatchSize, maxCWLGroupBatchSize)
	streamCfg := cfg
	streamCfg.BatchSize = batchSize
	groups := make([][]any, 0, batchSize)
	clans := make([][]any, 0, batchSize*8)
	members := make([][]any, 0, batchSize*120)
	groupPositions := make(map[string]int, batchSize)
	clanPositions := make(map[string]int, batchSize*8)
	memberPositions := make(map[string]int, batchSize*120)
	docsInBatch := 0
	flush := func() error {
		if len(groups) == 0 {
			return nil
		}
		startedAt := time.Now()
		fmt.Fprintf(
			os.Stderr,
			"\nflushing cwl_groups=%d cwl_group_clans=%d cwl_group_members=%d ...",
			len(groups),
			len(clans),
			len(members),
		)
		err := flushCWLGroupRows(ctx, pool, groups, clans, members)
		if err == nil {
			fmt.Fprintf(os.Stderr, " done in %s\n", time.Since(startedAt).Round(time.Millisecond))
		}
		groups = groups[:0]
		clans = clans[:0]
		members = members[:0]
		clear(groupPositions)
		clear(clanPositions)
		clear(memberPositions)
		docsInBatch = 0
		return err
	}
	seen, err := migrateutil.StreamAll(ctx, streamCfg, "cwl_group", mongoClient.Database("looper").Collection("cwl_group"), func(doc bson.M) (bool, error) {
		data := migrateutil.Map(doc["data"])
		if data == nil {
			return false, nil
		}
		legacyCWLID := migrateutil.String(firstCWL(doc["cwl_id"], data["cwl_id"]))
		if legacyCWLID == "" {
			return false, nil
		}
		cwlID := migrateutil.StableCWLID(legacyCWLID)
		for _, raw := range migrateutil.Slice(data["clans"]) {
			clan := migrateutil.Map(raw)
			tag := migrateutil.String(clan["tag"])
			if tag == "" {
				continue
			}
			badgeURLs := migrateutil.Map(clan["badgeUrls"])
			row := []any{
				cwlID,
				tag,
				migrateutil.String(clan["name"]),
				migrateutil.Int(clan["clanLevel"]),
				migrateutil.BadgeToken(clan["badgeToken"], clan["badge_token"], badgeURLs["medium"], badgeURLs["small"], badgeURLs["large"]),
			}
			key := cwlID + "\x00" + tag
			if position, ok := clanPositions[key]; ok {
				clans[position] = row
			} else {
				clanPositions[key] = len(clans)
				clans = append(clans, row)
			}
			for _, rawMember := range migrateutil.Slice(clan["members"]) {
				member := migrateutil.Map(rawMember)
				memberTag := migrateutil.String(member["tag"])
				if memberTag == "" {
					continue
				}
				memberRow := []any{
					cwlID,
					tag,
					migrateutil.String(member["name"]),
					memberTag,
					migrateutil.Int(member["townHallLevel"]),
				}
				memberKey := cwlID + "\x00" + memberTag
				if position, ok := memberPositions[memberKey]; ok {
					members[position] = memberRow
				} else {
					memberPositions[memberKey] = len(members)
					members = append(members, memberRow)
				}
			}
		}
		row := []any{
			cwlID,
			migrateutil.String(data["season"]),
			firstCWLNullableInt(data["cwlLeagueId"], data["cwl_league_id"], doc["cwl_league_id"]),
			cwlGroupState(migrateutil.String(data["state"])),
			migrateutil.RawJSON(migrateutil.Slice(data["rounds"])),
		}
		if position, ok := groupPositions[cwlID]; ok {
			groups[position] = row
		} else {
			groupPositions[cwlID] = len(groups)
			groups = append(groups, row)
		}
		docsInBatch++
		return docsInBatch >= batchSize, nil
	}, flush)
	if err != nil {
		return err
	}
	for _, index := range []struct {
		name string
		sql  string
	}{
		{
			name: "cwl_groups_pkey",
			sql:  "ALTER TABLE cwl_groups ADD CONSTRAINT cwl_groups_pkey PRIMARY KEY (cwl_id)",
		},
		{
			name: "cwl_group_clans_pkey",
			sql:  "ALTER TABLE cwl_group_clans ADD CONSTRAINT cwl_group_clans_pkey PRIMARY KEY (cwl_id, clan_tag)",
		},
		{
			name: "cwl_group_clans_cwl_id_fkey",
			sql:  "ALTER TABLE cwl_group_clans ADD CONSTRAINT cwl_group_clans_cwl_id_fkey FOREIGN KEY (cwl_id) REFERENCES cwl_groups(cwl_id) ON DELETE CASCADE",
		},
		{
			name: "cwl_group_members_pkey",
			sql:  "ALTER TABLE cwl_group_members ADD CONSTRAINT cwl_group_members_pkey PRIMARY KEY (tag, cwl_id)",
		},
		{
			name: "cwl_group_members_group_clan_fkey",
			sql:  "ALTER TABLE cwl_group_members ADD CONSTRAINT cwl_group_members_group_clan_fkey FOREIGN KEY (cwl_id, clan_tag) REFERENCES cwl_group_clans(cwl_id, clan_tag) ON DELETE CASCADE",
		},
		{
			name: "cwl_standings_group_clan_fkey",
			sql:  "ALTER TABLE cwl_standings ADD CONSTRAINT cwl_standings_group_clan_fkey FOREIGN KEY (cwl_id, clan_tag) REFERENCES cwl_group_clans(cwl_id, clan_tag) ON DELETE CASCADE",
		},
		{
			name: "idx_cwl_groups_season_league",
			sql:  "CREATE INDEX IF NOT EXISTS idx_cwl_groups_season_league ON cwl_groups (season, cwl_league_id)",
		},
		{
			name: "idx_cwl_groups_season_league_size",
			sql:  "CREATE INDEX IF NOT EXISTS idx_cwl_groups_season_league_size ON cwl_groups (season, cwl_league_id, war_size)",
		},
		{
			name: "idx_cwl_group_clans_clan_cwl",
			sql:  "CREATE INDEX IF NOT EXISTS idx_cwl_group_clans_clan_cwl ON cwl_group_clans (clan_tag, cwl_id DESC)",
		},
		{
			name: "idx_cwl_group_members_cwl_id",
			sql:  "CREATE INDEX IF NOT EXISTS idx_cwl_group_members_cwl_id ON cwl_group_members (cwl_id)",
		},
	} {
		startedAt := time.Now()
		fmt.Fprintf(os.Stderr, "building %s ...", index.name)
		if _, err := pool.Exec(ctx, index.sql); err != nil {
			return fmt.Errorf("build %s: %w", index.name, err)
		}
		fmt.Fprintf(os.Stderr, " done in %s\n", time.Since(startedAt).Round(time.Millisecond))
	}
	fmt.Printf("cwl_groups: scanned_docs=%d\n", seen)
	return nil
}

func flushCWLGroupRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, groups, clans, members [][]any) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_cwl_groups (
			cwl_id text, season text, cwl_league_id int, state text, rounds text
		) ON COMMIT DROP;
		CREATE TEMP TABLE _ck_cwl_group_clans (
			cwl_id text, clan_tag text, name text, clan_level int, badge_token text
		) ON COMMIT DROP;
		CREATE TEMP TABLE _ck_cwl_group_members (
			cwl_id text, clan_tag text, name text, tag text, town_hall int
		) ON COMMIT DROP
	`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_cwl_groups"}, []string{
		"cwl_id", "season", "cwl_league_id", "state", "rounds",
	}, pgx.CopyFromRows(groups)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO cwl_groups (cwl_id, season, cwl_league_id, state, rounds)
		SELECT cwl_id, season, cwl_league_id, state, rounds::jsonb
		FROM _ck_cwl_groups
		WHERE cwl_id <> '' AND season <> ''
	`); err != nil {
		return err
	}
	if len(clans) == 0 {
		return tx.Commit(ctx)
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_cwl_group_clans"}, []string{
		"cwl_id", "clan_tag", "name", "clan_level", "badge_token",
	}, pgx.CopyFromRows(clans)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO cwl_group_clans (cwl_id, clan_tag, name, clan_level, badge_token)
		SELECT cwl_id, clan_tag, name, clan_level, badge_token
		FROM _ck_cwl_group_clans
		WHERE cwl_id <> '' AND clan_tag <> ''
	`); err != nil {
		return err
	}
	if len(members) > 0 {
		if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_cwl_group_members"}, []string{
			"cwl_id", "clan_tag", "name", "tag", "town_hall",
		}, pgx.CopyFromRows(members)); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO cwl_group_members (cwl_id, clan_tag, name, tag, town_hall)
		SELECT cwl_id, clan_tag, name, tag, town_hall
		FROM _ck_cwl_group_members
		WHERE cwl_id <> '' AND clan_tag <> '' AND tag <> ''
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func firstCWL(values ...any) any {
	for _, value := range values {
		if migrateutil.String(value) != "" {
			return value
		}
	}
	return nil
}

func firstCWLNullableInt(values ...any) any {
	for _, value := range values {
		if out := migrateutil.Int(value); out != 0 {
			return out
		}
	}
	return nil
}

func cwlGroupState(value string) string {
	switch value {
	case "notInWar", "preparation", "inWar", "ended":
		return value
	default:
		return "preparation"
	}
}
