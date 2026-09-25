package schema

import (
	"context"
	"testing"
)

func TestLegendLeaderboardUsesLivePlayerAndClanIdentity(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `
		INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received)
		VALUES('#2PP','Live Clan',true,1,1,'badge',0,0);
		INSERT INTO basic_player(tag,name,league_id,clan_tag,townhall_level,trophies)
		VALUES('#P0Y','First',105000036,'#2PP',18,6000),('#P0L','Second',105000036,NULL,18,5900),('#P0G','Not Legend',105000035,NULL,18,7000);
		TRUNCATE legend_rankings_current;
		INSERT INTO legend_rankings_current(tag,name,trophies,global_rank,clan_tag,clan_name)
		SELECT player.tag,player.name,player.trophies,row_number() OVER(ORDER BY player.trophies DESC,player.tag),clan.tag,clan.name
		FROM basic_player player LEFT JOIN basic_clan clan ON clan.tag=player.clan_tag
		WHERE player.league_id=105000036`)
	if err != nil {
		t.Fatal(err)
	}
	var count, firstRank int
	var clanName *string
	if err = tx.QueryRow(ctx, `SELECT count(*),min(global_rank) FROM legend_rankings_current`).Scan(&count, &firstRank); err != nil {
		t.Fatal(err)
	}
	if count != 2 || firstRank != 1 {
		t.Fatalf("rows=%d firstRank=%d", count, firstRank)
	}
	if err = tx.QueryRow(ctx, `SELECT clan_name FROM legend_rankings_current WHERE tag='#P0L'`).Scan(&clanName); err != nil || clanName != nil {
		t.Fatalf("absent clan was snapshotted: %v %v", clanName, err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO legend_rankings_history(day,tag,global_rank,trophies) VALUES('2026-09-10','#P0Y',1,6000)`)
	if err != nil {
		t.Fatal(err)
	}
}

func TestNotificationPreferencesAreUserLevelAndLinksReset(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `
		INSERT INTO auth_users(user_id,provider) VALUES('100','discord'),('200','discord');
		INSERT INTO player_links(tag,is_verified,source,user_id) VALUES('#P0Y',true,'api_token','100');
		INSERT INTO mobile_push_devices(user_id,device_id,platform,provider,environment,token_ciphertext,token_hash)
		VALUES('100','iphone','ios','fcm','production','cipher','hash');
		INSERT INTO mobile_notification_preferences(user_id,war_attacks_enabled,war_state_enabled,war_reminders_enabled,legend_defenses_enabled,reminder_timings)
		VALUES('100',true,true,true,true,'{60,120}');
		INSERT INTO mobile_notification_accounts(user_id,player_tag) VALUES('100','#P0Y')`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `UPDATE player_links SET user_id='200' WHERE tag='#P0Y'`); err != nil {
		t.Fatal(err)
	}
	var absent bool
	if err = tx.QueryRow(ctx, `SELECT NOT EXISTS(SELECT 1 FROM mobile_notification_accounts WHERE player_tag='#P0Y')`).Scan(&absent); err != nil || !absent {
		t.Fatalf("transferred account inherited enablement: %v", err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO mobile_notification_accounts(user_id,player_tag) VALUES('200','#P0Y')`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `UPDATE player_links SET is_verified=false WHERE tag='#P0Y'`); err != nil {
		t.Fatal(err)
	}
	if err = tx.QueryRow(ctx, `SELECT NOT EXISTS(SELECT 1 FROM mobile_notification_accounts WHERE player_tag='#P0Y')`).Scan(&absent); err != nil || !absent {
		t.Fatalf("unverified account retained enablement: %v", err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO mobile_notification_accounts(user_id,player_tag) VALUES('200','#P0Y')`); err == nil {
		t.Fatal("unverified account accepted")
	}
}

func TestBasesUseBigintRelationsAndPrivateVotes(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	var baseID int64
	err = tx.QueryRow(ctx, `INSERT INTO bases(message_id,base_link,description)
		VALUES('123','https://link.clashofclans.com/en?action=OpenLayout&id=TH17%3AHV%3AAAAA','Legacy row') RETURNING id`).Scan(&baseID)
	if err != nil {
		t.Fatal(err)
	}
	_, err = tx.Exec(ctx, `UPDATE bases SET images=ARRAY['https://api.clashk.ing/v2/media/base.png'] WHERE id=$1`, baseID)
	if err == nil {
		_, err = tx.Exec(ctx, `UPDATE bases SET downloads=jsonb_build_object('100','2026-09-15T12:00:00Z') WHERE id=$1`, baseID)
	}
	if err == nil {
		_, err = tx.Exec(ctx, `UPDATE bases SET votes=jsonb_build_object('100',jsonb_build_object('vote',1,'updatedAt',now())) WHERE id=$1`, baseID)
	}
	if err == nil {
		_, err = tx.Exec(ctx, `UPDATE bases SET server_id='200',channel_id='300' WHERE id=$1`, baseID)
	}
	if err != nil {
		t.Fatal(err)
	}
	var downloads, upvotes, downvotes int
	if err = tx.QueryRow(ctx, `SELECT download_count,upvote_count,downvote_count FROM base_public_counts WHERE base_id=$1`, baseID).Scan(&downloads, &upvotes, &downvotes); err != nil {
		t.Fatal(err)
	}
	if downloads != 1 || upvotes != 1 || downvotes != 0 {
		t.Fatalf("counts=%d/%d/%d", downloads, upvotes, downvotes)
	}
	for _, q := range []string{
		`INSERT INTO bases(message_id,base_link) VALUES('124','https://evil.example/?action=OpenLayout&id=TH17')`,
		`INSERT INTO bases(message_id,base_link,images) VALUES('125','https://link.clashofclans.com/en?action=OpenLayout&id=TH17',ARRAY['https://example.com/base.png'])`,
		`INSERT INTO bases(message_id,base_link,votes) VALUES('126','https://link.clashofclans.com/en?action=OpenLayout&id=TH17','{"101":{"vote":0,"updatedAt":"2026-09-17T00:00:00Z"}}')`,
	} {
		if _, err = tx.Exec(ctx, `SAVEPOINT invalid`); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec(ctx, q); err == nil {
			t.Fatalf("invalid base write accepted: %s", q)
		}
		if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT invalid`); err != nil {
			t.Fatal(err)
		}
	}
}

func TestPersonalLibrariesUseCanonicalBaseAndArmyIdentity(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `
		INSERT INTO auth_users(user_id,provider) VALUES('owner','discord');
		INSERT INTO bases(message_id,base_link,description)
		SELECT (900000000000000000+value)::text,
		       'https://link.clashofclans.com/en?action=OpenLayout&id=TH17%3AWB%3A'||value,
		       'Personal base '||value
		FROM generate_series(1,25) value;
		INSERT INTO user_saved_bases(user_id,base_id)
		SELECT 'owner',id FROM bases WHERE description LIKE 'Personal base %';
		INSERT INTO army_compositions(share_code) VALUES('u1x0');
		INSERT INTO user_saved_armies(user_id,share_code)
		VALUES('owner','u1x0')`)
	if err != nil {
		t.Fatal(err)
	}
	var savedCount int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM user_saved_bases WHERE user_id='owner'`).Scan(&savedCount); err != nil || savedCount != 25 {
		t.Fatalf("unlimited saved rows=%d err=%v", savedCount, err)
	}
	var kindAbsent bool
	if err = tx.QueryRow(ctx, `SELECT NOT EXISTS (
		SELECT 1 FROM information_schema.columns
		WHERE table_schema='public' AND table_name='user_saved_bases' AND column_name='kind'
	)`).Scan(&kindAbsent); err != nil || !kindAbsent {
		t.Fatalf("saved-base kind still exists: %v", err)
	}
	var armySaved bool
	if err = tx.QueryRow(ctx, `SELECT saved_at IS NOT NULL FROM user_saved_armies
		WHERE user_id='owner' AND share_code='u1x0'`).Scan(&armySaved); err != nil || !armySaved {
		t.Fatalf("personal army save missing: %v", err)
	}
	for _, q := range []string{
		`INSERT INTO user_saved_armies(user_id,share_code) VALUES('owner','u1x0')`,
		`INSERT INTO user_saved_armies(user_id,share_code) VALUES('owner','missing')`,
	} {
		if _, err = tx.Exec(ctx, `SAVEPOINT invalid_personal_army`); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec(ctx, q); err == nil {
			t.Fatalf("invalid personal army accepted: %s", q)
		}
		if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT invalid_personal_army`); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = tx.Exec(ctx, `DELETE FROM user_saved_armies WHERE user_id='owner' AND share_code='u1x0'`); err != nil {
		t.Fatal(err)
	}
	var compositionPresent bool
	if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM army_compositions WHERE share_code='u1x0')`).Scan(&compositionPresent); err != nil || !compositionPresent {
		t.Fatalf("unsave deleted canonical composition: %v", err)
	}
	if err = tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
}
