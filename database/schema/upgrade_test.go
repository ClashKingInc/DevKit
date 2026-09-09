package schema

import (
	"context"
	"os"
	"os/exec"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Run only through the local tmpfs fixture with --profile baseline-006.
func TestWorkerAPIUpgrade(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" {
		t.Skip("requires disposable Timescale fixture")
	}
	if os.Getenv("CLASHKING_TIMESCALE_PROFILE") != "baseline-006" {
		t.Skip("requires baseline-006 migration profile")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	run := func(sql string) {
		t.Helper()
		if _, err := conn.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	check := func(sql string) {
		t.Helper()
		var ok bool
		if err := conn.QueryRow(ctx, sql).Scan(&ok); err != nil || !ok {
			t.Fatalf("check failed: %s (%v)", sql, err)
		}
	}
	check(`SELECT max(version_id)=6 FROM goose_db_version WHERE is_applied`)
	run(`INSERT INTO auth_users(user_id,provider) VALUES ('old','discord'),('new','discord');
 INSERT INTO billing_customers(user_id,stripe_customer_id) VALUES ('old','cus_old'),('new','cus_new');
 INSERT INTO billing_subscriptions(user_id,provider_subscription_id,status) VALUES ('old','sub_old','active');
 INSERT INTO servers(id,name) VALUES ('123','existing');
 INSERT INTO ticket_panels(server_id,name,components,data) VALUES (
   '123',
   'existing',
   '[{"id":0,"type":2,"custom_id":"old_button","label":"Apply"},{"id":0,"type":2,"custom_id":"duplicate","label":"First"},{"type":2,"custom_id":"duplicate","label":"Second"}]',
   '{"old_button_settings":{"questions":["Why?"]},"duplicate_settings":{"questions":["Which one?"]}}'
 );
 INSERT INTO ticket_panel(id,server_id,name,description) VALUES ('00000000-0000-4000-8000-000000000001','123','existing','imported');
 INSERT INTO ticket_panel_buttons(id,panel_id,server_id,custom_id) VALUES ('00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','123','old_button');
 INSERT INTO tickets(server_id,channel_id,panel_id) VALUES ('123','456','00000000-0000-4000-8000-000000000001');
 INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received)
 VALUES ('#A','existing',true,100,50,'badge',10,20);`)
	migrate := func(command ...string) error {
		t.Helper()
		args := append([]string{"-env", "/dev/null", "-dir", "../timescale"}, command...)
		cmd := exec.Command("goose", args...)
		cmd.Env = append(os.Environ(), "GOOSE_DRIVER=postgres", "GOOSE_DBSTRING="+os.Getenv("TEST_DATABASE_URL"), "GOOSE_TABLE=goose_db_version")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Log(string(out))
		}
		return err
	}
	if err := migrate("up-to", "7"); err != nil {
		t.Fatal(err)
	}
	check(`SELECT max(version_id)=7 FROM goose_db_version WHERE is_applied`)
	for _, table := range []string{"public.app_update_channels", "public.app_update_installations", "discord_cache.guilds", "discord_cache.channels", "discord_cache.users", "discord_cache.members", "discord_cache.roles", "discord_cache.application_emojis", "public.billing_customer_operations"} {
		var present bool
		if err := conn.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, table).Scan(&present); err != nil || !present {
			t.Fatalf("missing %s: %v", table, err)
		}
	}
	check(`SELECT initial_assignment_applied FROM billing_subscriptions WHERE user_id='old'`)
	run(`INSERT INTO billing_subscriptions(user_id,provider_subscription_id,status) VALUES ('new','sub_new','active')`)
	check(`SELECT NOT initial_assignment_applied FROM billing_subscriptions WHERE user_id='new'`)
	check(`SELECT NOT require_api_token_when_linking FROM servers WHERE id='123'`)
	check(`SELECT capital_gold_total=0 FROM basic_clan WHERE tag='#A'`)
	check(`SELECT capital_gold_rank=1 AND location_capital_gold_rank=1 FROM clan_leaderboards WHERE tag='#A'`)
	check(`SELECT to_regclass('public.roster_ai_budget_locks') IS NULL AND to_regclass('public.player_link_mutation_locks') IS NULL AND to_regclass('discord_cache.delivery_receipts') IS NULL AND to_regclass('public.subject_mutation_locks') IS NULL AND to_regclass('public.discord_managed_resources') IS NULL`)
	check(`SELECT to_regclass('discord_cache.dashboard_access') IS NULL AND to_regclass('discord_cache.request_limits') IS NULL`)
	// Ticket configuration is deliberately untouched until the Bot rewrite can
	// resolve legacy Discord IDs and duplicate custom IDs without changing behavior.
	check(`SELECT components='[{"id":0,"type":2,"custom_id":"old_button","label":"Apply"},{"id":0,"type":2,"custom_id":"duplicate","label":"First"},{"type":2,"custom_id":"duplicate","label":"Second"}]'::jsonb
	 AND data='{"old_button_settings":{"questions":["Why?"]},"duplicate_settings":{"questions":["Which one?"]}}'::jsonb
	 FROM ticket_panels WHERE server_id='123' AND name='existing'`)
	check(`SELECT NOT EXISTS (
	 SELECT 1 FROM information_schema.columns
	 WHERE table_schema='public' AND table_name='ticket_panels' AND column_name IN ('id','archived_at')
	)`)
	check(`SELECT confrelid='public.ticket_panel'::regclass AND confdeltype='c'
	 FROM pg_constraint WHERE conrelid='public.tickets'::regclass AND conname='tickets_panel_id_fkey'`)
	check(`SELECT to_regclass('public.ticket_runtime_operations') IS NULL`)

	run(`INSERT INTO app_update_channels(channel,platform,runtime_version,active_version,rollback_target_version) VALUES ('production','ios','1','v2','v1')`)
	if _, err := conn.Exec(ctx, `UPDATE app_update_channels SET rollback_target_version=active_version`); err == nil {
		t.Fatal("rollback constraint missing")
	}
	run(`INSERT INTO billing_customer_operations(user_id) VALUES ('old')`)
	check(`SELECT operation_id IS NOT NULL AND stripe_customer_id IS NULL FROM billing_customer_operations WHERE user_id='old'`)
	run(`INSERT INTO ranked_league_group_members(
 season_id,group_tag,league_tier_id,player_tag,player_name,placement,league_trophies,
 attack_win_count,attack_lose_count,defense_win_count,defense_lose_count
) VALUES (1,'#2PP',1,'#2PP','Existing',1,1000,3,2,4,1)`)
	run(`INSERT INTO ranked_league_group_members(
 season_id,group_tag,league_tier_id,player_tag,player_name,placement,league_trophies,
 attack_win_count,attack_lose_count,defense_win_count,defense_lose_count
) VALUES (1,'#P0Y',1,'#2PP','Stale duplicate',2,900,1,0,0,0)`)
	if err := migrate("up-to", "8"); err != nil {
		t.Fatal("repeat up", err)
	}
	check(`SELECT max(version_id)=8 FROM goose_db_version WHERE is_applied`)
	check(`SELECT player_tag='#2PP' AND player_name='Existing' AND attack_win_count=3 AND attack_loss_count=2
	 AND defense_win_count=4 AND defense_loss_count=1 AND maximum_battle_count=0
 FROM ranked_league_group_members WHERE season_id=1 AND group_tag='#2PP'`)
	check(`SELECT count(*)=1 FROM ranked_league_group_members WHERE season_id=1 AND player_tag='#2PP'`)
	for _, table := range []string{"public.battles_farming", "public.battles_ranked", "public.army_compositions"} {
		var present bool
		if err := conn.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, table).Scan(&present); err != nil || !present {
			t.Fatalf("missing %s after upgrade: %v", table, err)
		}
	}
	if err := migrate("down"); err != nil {
		t.Fatal("008 down", err)
	}
	check(`SELECT max(version_id)=7 FROM goose_db_version WHERE is_applied`)
	check(`SELECT to_regclass('public.battles_farming') IS NULL
 AND to_regclass('public.battles_ranked') IS NULL
 AND to_regclass('public.army_compositions') IS NULL`)
	if err := migrate("down"); err == nil {
		t.Fatal("irreversible migration allowed down")
	}
	check(`SELECT max(version_id)=7 FROM goose_db_version WHERE is_applied`)
	if err := migrate("up-to", "10"); err != nil {
		t.Fatal("009/010 upgrade", err)
	}
	check(`SELECT max(version_id)=10 FROM goose_db_version WHERE is_applied`)
	check(`SELECT to_regclass('public.league_hitrate_stats') IS NOT NULL
 AND to_regclass('public.ranked_league_tier_stats') IS NOT NULL
 AND to_regclass('public.legend_daily_stats') IS NOT NULL
 AND to_regclass('public.army_families') IS NOT NULL
 AND to_regclass('public.army_family_members') IS NOT NULL
 AND to_regclass('public.army_family_daily_stats') IS NOT NULL
 AND to_regclass('public.cwl_season_statistics') IS NOT NULL`)
	if err := migrate("down"); err != nil {
		t.Fatal("010 down", err)
	}
	check(`SELECT max(version_id)=9 FROM goose_db_version WHERE is_applied`)
	check(`SELECT to_regclass('public.cwl_season_statistics') IS NULL
 AND to_regclass('public.army_families') IS NOT NULL`)
	if err := migrate("down"); err != nil {
		t.Fatal("009 down", err)
	}
	check(`SELECT max(version_id)=8 FROM goose_db_version WHERE is_applied
 AND to_regclass('public.army_families') IS NULL`)
}
