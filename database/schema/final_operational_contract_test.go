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
	_, err = tx.Exec(ctx, `INSERT INTO leaderboard_history_player_home(day,tag,global_rank,trophies) VALUES('2026-09-10','#P0Y',1,6000)`)
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
	_, err = tx.Exec(ctx, `INSERT INTO base_images(base_id,position,image_url) VALUES($1,1,'https://api.clashk.ing/v2/media/base.png')`, baseID)
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO base_downloaders(base_id,user_id) VALUES($1,'100')`, baseID)
	}
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO base_votes(base_id,user_id,vote) VALUES($1,'100',1)`, baseID)
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
		`INSERT INTO base_images(base_id,position,image_url) VALUES(1,1,'https://example.com/base.png')`,
		`INSERT INTO base_votes(base_id,user_id,vote) VALUES(1,'101',0)`,
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

func TestPersonalBaseLibraryAndSlotsFollowVerifiedOwnership(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	var baseID int64
	_, err = tx.Exec(ctx, `
		INSERT INTO auth_users(user_id,provider) VALUES('owner','discord'),('next-owner','discord');
		INSERT INTO player_links(tag,is_verified,source,user_id)
		VALUES('#P0Y',true,'api_token','owner'),('#2PP',false,'api_token','owner')`)
	if err == nil {
		err = tx.QueryRow(ctx, `INSERT INTO bases(message_id,base_link)
			VALUES('987654321012345678','https://link.clashofclans.com/en?action=OpenLayout&id=TH17%3AWB%3AAAAA') RETURNING id`).Scan(&baseID)
	}
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO user_saved_bases(user_id,base_id) VALUES('owner',$1)`, baseID)
	}
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO user_base_slots(user_id,player_tag,slot_kind,slot_number,base_id)
			VALUES('owner','#P0Y','war',1,$1),('owner','#P0Y','legend',1,$1)`, baseID)
	}
	if err != nil {
		t.Fatal(err)
	}

	reject := func(query string, args ...any) {
		t.Helper()
		if _, err = tx.Exec(ctx, `SAVEPOINT invalid_personal_base`); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec(ctx, query, args...); err == nil {
			t.Fatalf("invalid personal-base write accepted: %s", query)
		}
		if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT invalid_personal_base`); err != nil {
			t.Fatal(err)
		}
	}
	reject(`INSERT INTO user_base_slots(user_id,player_tag,slot_kind,slot_number,base_id)
		VALUES('owner','#P0Y','war',2,$1)`, baseID)
	reject(`INSERT INTO user_base_slots(user_id,player_tag,slot_kind,slot_number,base_id)
		VALUES('owner','#P0Y','war',4,$1)`, baseID)
	reject(`INSERT INTO user_base_slots(user_id,player_tag,slot_kind,slot_number,base_id)
		VALUES('owner','#2PP','war',1,$1)`, baseID)
	reject(`INSERT INTO user_base_slots(user_id,player_tag,slot_kind,slot_number,base_id)
		VALUES('next-owner','#P0Y','war',1,$1)`, baseID)

	if _, err = tx.Exec(ctx, `UPDATE player_links SET is_verified=false WHERE tag='#P0Y'`); err != nil {
		t.Fatal(err)
	}
	var slotCount, savedCount int
	if err = tx.QueryRow(ctx, `SELECT
		(SELECT count(*) FROM user_base_slots WHERE player_tag='#P0Y'),
		(SELECT count(*) FROM user_saved_bases WHERE user_id='owner' AND base_id=$1)`, baseID).Scan(&slotCount, &savedCount); err != nil {
		t.Fatal(err)
	}
	if slotCount != 0 || savedCount != 1 {
		t.Fatalf("unverification left slots or removed personal library: slots=%d saved=%d", slotCount, savedCount)
	}
	if _, err = tx.Exec(ctx, `UPDATE player_links SET is_verified=true WHERE tag='#P0Y'`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO user_base_slots(user_id,player_tag,slot_kind,slot_number,base_id)
		VALUES('owner','#P0Y','war',1,$1),('owner','#P0Y','legend',1,$1)`, baseID); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `UPDATE player_links SET user_id='next-owner' WHERE tag='#P0Y'`); err != nil {
		t.Fatal(err)
	}
	if err = tx.QueryRow(ctx, `SELECT
		(SELECT count(*) FROM user_base_slots WHERE player_tag='#P0Y'),
		(SELECT count(*) FROM user_saved_bases WHERE user_id='owner' AND base_id=$1)`, baseID).Scan(&slotCount, &savedCount); err != nil {
		t.Fatal(err)
	}
	if slotCount != 0 || savedCount != 1 {
		t.Fatalf("transfer left slots or removed personal library: slots=%d saved=%d", slotCount, savedCount)
	}

	if _, err = tx.Exec(ctx, `UPDATE player_links SET user_id='owner',is_verified=true WHERE tag='#P0Y'`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO user_base_slots(user_id,player_tag,slot_kind,slot_number,base_id)
		VALUES('owner','#P0Y','war',1,$1)`, baseID); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `DELETE FROM user_saved_bases WHERE user_id='owner' AND base_id=$1`, baseID); err != nil {
		t.Fatal(err)
	}
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM user_base_slots WHERE player_tag='#P0Y'`).Scan(&slotCount); err != nil || slotCount != 0 {
		t.Fatalf("unsave did not clear slots: slots=%d err=%v", slotCount, err)
	}

	if _, err = tx.Exec(ctx, `INSERT INTO user_saved_bases(user_id,base_id) VALUES('owner',$1)`, baseID); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO user_base_slots(user_id,player_tag,slot_kind,slot_number,base_id)
		VALUES('owner','#P0Y','legend',1,$1)`, baseID); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `DELETE FROM player_links WHERE tag='#P0Y'`); err != nil {
		t.Fatal(err)
	}
	if err = tx.QueryRow(ctx, `SELECT
		(SELECT count(*) FROM user_base_slots WHERE player_tag='#P0Y'),
		(SELECT count(*) FROM user_saved_bases WHERE user_id='owner' AND base_id=$1)`, baseID).Scan(&slotCount, &savedCount); err != nil {
		t.Fatal(err)
	}
	if slotCount != 0 || savedCount != 1 {
		t.Fatalf("unlink left slots or removed personal library: slots=%d saved=%d", slotCount, savedCount)
	}

	if _, err = tx.Exec(ctx, `DELETE FROM bases WHERE id=$1`, baseID); err != nil {
		t.Fatal(err)
	}
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM user_saved_bases WHERE base_id=$1`, baseID).Scan(&savedCount); err != nil || savedCount != 0 {
		t.Fatalf("base delete retained personal reference: saved=%d err=%v", savedCount, err)
	}
}
