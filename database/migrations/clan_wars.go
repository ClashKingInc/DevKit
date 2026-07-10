//go:build ignore

package main

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"clashking_devkit_database_migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

func main() {
	migrateutil.Main("clan_wars", runClanWars)
}

func runClanWars(ctx context.Context, cfg migrateutil.Config) (err error) {
	profile := envBool(cfg.Env, "CLAN_WARS_PROFILE")
	started := time.Now()
	if profile {
		defer func() {
			printClanWarProfile(time.Since(started))
		}()
	}
	mongoClient, err := migrateutil.StatsClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer mongoClient.Disconnect(ctx)
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	cp, err := migrateutil.LoadCheckpoint(cfg, "clan_wars")
	if err != nil {
		return err
	}
	if envBool(cfg.Env, "CLAN_WARS_TRUNCATE") {
		if err := cp.Clear(); err != nil {
			return err
		}
		if _, err := pool.Exec(ctx, `TRUNCATE TABLE war_attacks, war_members, war_missed_attacks, wars`); err != nil {
			return err
		}
		chunkInterval := strings.TrimSpace(cfg.Env["CLAN_WARS_CHUNK_INTERVAL"])
		if chunkInterval == "" {
			chunkInterval = "3 months"
		}
		if _, err := pool.Exec(ctx, `SELECT set_chunk_time_interval('war_attacks', $1::interval)`, chunkInterval); err != nil {
			return err
		}
		if _, err := pool.Exec(ctx, `SELECT drop_chunks('war_attacks', older_than => TIMESTAMPTZ '9999-12-31')`); err != nil {
			return err
		}
	}
	dropIndexes := envBool(cfg.Env, "CLAN_WARS_DROP_INDEXES")
	if dropIndexes {
		if err := dropClanWarIndexes(ctx, pool); err != nil {
			return err
		}
		defer func() {
			rebuildErr := recreateClanWarIndexes(ctx, pool)
			if err == nil {
				err = rebuildErr
			} else if rebuildErr != nil {
				err = fmt.Errorf("%w; additionally failed to recreate clan war indexes: %v", err, rebuildErr)
			}
		}()
	}
	collection := mongoClient.Database("looper").Collection("clan_war")
	var wars []warIndexInsert
	var members []warMemberInsert
	var attacks []warAttackInsert
	var missedAttacks []warMissedAttackInsert
	var docsInBatch int
	docBatchSize := clanWarEnvInt(cfg.Env, "CLAN_WARS_BATCH_DOCS", 50000)
	maxRowsInBatch := clanWarEnvInt(cfg.Env, "CLAN_WARS_MAX_ROWS", 2500000)
	flush := func() error {
		if len(wars) == 0 && len(members) == 0 && len(attacks) == 0 && len(missedAttacks) == 0 {
			return nil
		}
		err := flushClanWarRows(ctx, pool, wars, members, missedAttacks, attacks)
		wars = nil
		members = nil
		missedAttacks = nil
		attacks = nil
		docsInBatch = 0
		return err
	}
	seen, err := streamClanWarDocs(ctx, cfg, cp, "clan_war_id", collection, clanWarProjection(), func(doc clanWarDoc) (bool, error) {
		accepted, err := appendClanWarDoc(doc, &wars, &members, &missedAttacks, &attacks)
		if err != nil || !accepted {
			return false, err
		}
		docsInBatch++
		return docsInBatch >= docBatchSize || len(wars)+len(members)+len(missedAttacks)+len(attacks) >= maxRowsInBatch, nil
	}, flush)
	if err != nil {
		return err
	}
	fmt.Printf("clan_wars: scanned_docs=%d\n", seen)
	return nil
}

func appendClanWarDoc(doc clanWarDoc, wars *[]warIndexInsert, members *[]warMemberInsert, missedAttacks *[]warMissedAttackInsert, attacks *[]warAttackInsert) (bool, error) {
	clanTag := doc.Data.Clan.Tag
	opponentTag := doc.Data.Opponent.Tag
	prepAt, prepOK := migrateutil.Time(doc.Data.PreparationStartTime)
	endAt, endOK := migrateutil.Time(firstWar(doc.Data.EndTime, doc.EndTime))
	if clanTag == "" || opponentTag == "" || !prepOK || !endOK {
		return false, nil
	}
	warID := computeWarKey(clanTag, opponentTag, prepAt)
	startAt, _ := migrateutil.Time(doc.Data.StartTime)
	var startValue *time.Time
	if !startAt.IsZero() {
		startValue = &startAt
	}
	warType := firstNonEmptyString(doc.Type, doc.Data.Type)
	warTag := firstNonEmptyString(doc.Data.Tag, doc.Data.WarTag, doc.Data.WarTagSnake, doc.WarTag)
	if warType == "" {
		if warTag != "" {
			warType = "cwl"
		} else {
			warType = "random"
		}
	}
	state := doc.Data.State
	battleModifier := normalizeBattleModifier(doc.Data.BattleModifier)
	size := doc.Data.TeamSize
	attacksPerMember := doc.Data.AttacksPerMember
	if attacksPerMember <= 0 {
		attacksPerMember = 1
	}
	if !isFinishedWar(state) {
		return false, nil
	}
	*wars = append(*wars,
		warIndexRow(warID, doc.Data.Clan, doc.Data.Opponent, prepAt, startValue, endAt, size, attacksPerMember, warType, state, battleModifier, warTag),
	)
	appendWarMemberRows(members, warID, endAt, doc.Data.Clan, doc.Data.Opponent)
	appendWarMissedAttackRows(missedAttacks, warID, endAt, attacksPerMember, doc.Data.Clan, doc.Data.Opponent)
	appendWarAttackRows(attacks, warID, endAt, warType, size, battleModifier, doc.Data.Clan, doc.Data.Opponent)
	return true, nil
}

type clanWarSQL interface {
	Begin(context.Context) (pgx.Tx, error)
}

type clanWarDoc struct {
	ID       bson.ObjectID `bson:"_id"`
	Type     string        `bson:"type"`
	WarTag   string        `bson:"war_tag"`
	EndTime  any           `bson:"endTime"`
	Data     clanWarData   `bson:"data"`
	CustomID string        `bson:"custom_id"`
	WarID    string        `bson:"war_id"`
}

type clanWarData struct {
	Tag                  string     `bson:"tag" json:"tag,omitempty"`
	WarTag               string     `bson:"warTag" json:"warTag,omitempty"`
	WarTagSnake          string     `bson:"war_tag" json:"war_tag,omitempty"`
	Type                 string     `bson:"type" json:"type,omitempty"`
	Clan                 warClanDoc `bson:"clan" json:"clan"`
	Opponent             warClanDoc `bson:"opponent" json:"opponent"`
	PreparationStartTime any        `bson:"preparationStartTime" json:"preparationStartTime"`
	StartTime            any        `bson:"startTime" json:"startTime,omitempty"`
	EndTime              any        `bson:"endTime" json:"endTime"`
	State                string     `bson:"state" json:"state"`
	BattleModifier       string     `bson:"battleModifier" json:"battleModifier,omitempty"`
	TeamSize             int        `bson:"teamSize" json:"teamSize"`
	AttacksPerMember     int        `bson:"attacksPerMember" json:"attacksPerMember,omitempty"`
}

type warClanDoc struct {
	Tag                   string         `bson:"tag" json:"tag"`
	Name                  string         `bson:"name" json:"name,omitempty"`
	BadgeURLs             badgeURLsDoc   `bson:"badgeUrls" json:"badgeUrls,omitempty"`
	ClanLevel             int            `bson:"clanLevel" json:"clanLevel,omitempty"`
	Attacks               int            `bson:"attacks" json:"attacks,omitempty"`
	Stars                 int            `bson:"stars" json:"stars,omitempty"`
	DestructionPercentage float64        `bson:"destructionPercentage" json:"destructionPercentage,omitempty"`
	Members               []warMemberDoc `bson:"members" json:"members,omitempty"`
}

type badgeURLsDoc struct {
	Small  string `bson:"small" json:"small,omitempty"`
	Medium string `bson:"medium" json:"medium,omitempty"`
	Large  string `bson:"large" json:"large,omitempty"`
}

type warMemberDoc struct {
	Tag           string         `bson:"tag" json:"tag"`
	Name          string         `bson:"name" json:"name,omitempty"`
	TownhallLevel int            `bson:"townhallLevel" json:"townhallLevel,omitempty"`
	MapPosition   int            `bson:"mapPosition" json:"mapPosition,omitempty"`
	Attacks       []warAttackDoc `bson:"attacks" json:"attacks,omitempty"`
}

type warAttackDoc struct {
	AttackerTag           string `bson:"attackerTag" json:"attackerTag"`
	DefenderTag           string `bson:"defenderTag" json:"defenderTag"`
	Stars                 int    `bson:"stars" json:"stars"`
	DestructionPercentage int    `bson:"destructionPercentage" json:"destructionPercentage"`
	Duration              int    `bson:"duration" json:"duration"`
	Order                 int    `bson:"order" json:"order"`
}

func clanWarProjection() bson.M {
	return bson.M{
		"data.clan.tag":                                       1,
		"data.clan.name":                                      1,
		"data.clan.badgeUrls":                                 1,
		"data.clan.clanLevel":                                 1,
		"data.clan.attacks":                                   1,
		"data.clan.stars":                                     1,
		"data.clan.destructionPercentage":                     1,
		"data.clan.members.tag":                               1,
		"data.clan.members.name":                              1,
		"data.clan.members.townhallLevel":                     1,
		"data.clan.members.mapPosition":                       1,
		"data.clan.members.attacks.attackerTag":               1,
		"data.clan.members.attacks.defenderTag":               1,
		"data.clan.members.attacks.stars":                     1,
		"data.clan.members.attacks.destructionPercentage":     1,
		"data.clan.members.attacks.duration":                  1,
		"data.clan.members.attacks.order":                     1,
		"data.opponent.tag":                                   1,
		"data.opponent.name":                                  1,
		"data.opponent.badgeUrls":                             1,
		"data.opponent.clanLevel":                             1,
		"data.opponent.attacks":                               1,
		"data.opponent.stars":                                 1,
		"data.opponent.destructionPercentage":                 1,
		"data.opponent.members.tag":                           1,
		"data.opponent.members.name":                          1,
		"data.opponent.members.townhallLevel":                 1,
		"data.opponent.members.mapPosition":                   1,
		"data.opponent.members.attacks.attackerTag":           1,
		"data.opponent.members.attacks.defenderTag":           1,
		"data.opponent.members.attacks.stars":                 1,
		"data.opponent.members.attacks.destructionPercentage": 1,
		"data.opponent.members.attacks.duration":              1,
		"data.opponent.members.attacks.order":                 1,
		"data.preparationStartTime":                           1,
		"data.startTime":                                      1,
		"data.endTime":                                        1,
		"data.state":                                          1,
		"data.battleModifier":                                 1,
		"data.teamSize":                                       1,
		"data.attacksPerMember":                               1,
		"data.tag":                                            1,
		"data.warTag":                                         1,
		"data.war_tag":                                        1,
		"data.type":                                           1,
		"type":                                                1,
		"war_tag":                                             1,
		"custom_id":                                           1,
		"war_id":                                              1,
		"endTime":                                             1,
	}
}

func streamClanWarDocs(
	ctx context.Context,
	cfg migrateutil.Config,
	cp *migrateutil.Checkpoint,
	cpKey string,
	collection *mongo.Collection,
	projection any,
	handle func(clanWarDoc) (bool, error),
	flush func() error,
) (int64, error) {
	var filter any = bson.D{}
	if raw := cp.Get(cpKey); raw != "" {
		id, err := bson.ObjectIDFromHex(raw)
		if err != nil {
			return 0, fmt.Errorf("bad checkpoint %s=%q: %w", cpKey, raw, err)
		}
		filter = bson.D{{Key: "_id", Value: bson.D{{Key: "$gt", Value: id}}}}
	}
	opts := options.Find().
		SetSort(bson.D{{Key: "_id", Value: 1}}).
		SetBatchSize(int32(minInt(cfg.BatchSize, 10000))).
		SetNoCursorTimeout(true).
		SetProjection(projection)
	cursor, err := collection.Find(ctx, filter, opts)
	if err != nil {
		return 0, err
	}
	defer cursor.Close(ctx)
	progress := migrateutil.NewProgress(ctx, cfg, collection, cpKey, filter)
	var seen int64
	var checkpointID string
	defer func() {
		progress.Done(seen)
	}()
	for cursor.Next(ctx) {
		var doc clanWarDoc
		if err := cursor.Decode(&doc); err != nil {
			return seen, err
		}
		ready, err := handle(doc)
		if err != nil {
			return seen, err
		}
		seen++
		if !doc.ID.IsZero() {
			checkpointID = doc.ID.Hex()
		}
		if ready {
			if err := flush(); err != nil {
				return seen, err
			}
			if checkpointID != "" {
				if err := cp.Set(cpKey, checkpointID); err != nil {
					return seen, err
				}
				checkpointID = ""
			}
		}
		progress.Tick(seen)
		if cfg.LimitDocs > 0 && seen >= cfg.LimitDocs {
			break
		}
	}
	if err := cursor.Err(); err != nil {
		return seen, err
	}
	if checkpointID != "" {
		if err := flush(); err != nil {
			return seen, err
		}
		if err := cp.Set(cpKey, checkpointID); err != nil {
			return seen, err
		}
	}
	return seen, nil
}

type warIndexInsert struct {
	warID                         string
	clanTag                       string
	opponentTag                   string
	prepAt                        time.Time
	startAt                       *time.Time
	endAt                         time.Time
	size                          int
	attacksPerMember              int
	warType                       string
	state                         string
	battleModifier                string
	warTag                        string
	clanName                      string
	opponentName                  string
	clanBadgeToken                string
	opponentBadgeToken            string
	clanLevel                     int
	opponentClanLevel             int
	clanAttacks                   int
	opponentAttacks               int
	clanStars                     int
	opponentStars                 int
	clanDestructionPercentage     float64
	opponentDestructionPercentage float64
}

type warMissedAttackInsert struct {
	warID           string
	warEndAt        time.Time
	clanTag         string
	opponentTag     string
	playerTag       string
	playerName      string
	townhall        int
	mapPosition     int
	expectedAttacks int
	attackCount     int
	missedAttacks   int
}

type warMemberInsert struct {
	warID       string
	warEndAt    time.Time
	clanTag     string
	opponentTag string
	playerTag   string
	playerName  string
	townhall    int
	mapPosition int
}

type warAttackInsert struct {
	warID                 string
	warEndAt              time.Time
	warType               string
	warSize               int
	attackingClanTag      string
	defendingClanTag      string
	attackerTag           string
	attackerName          string
	defenderTag           string
	defenderName          string
	attackerTownhall      int
	defenderTownhall      int
	attackerMapPosition   int
	defenderMapPosition   int
	stars                 int
	destructionPercentage int
	duration              int
	attackOrder           int
	battleModifier        string
}

func warIndexRow(warID string, clan warClanDoc, opponent warClanDoc, prepAt time.Time, startValue *time.Time, endAt time.Time, size int, attacksPerMember int, warType, state, battleModifier, warTag string) warIndexInsert {
	return warIndexInsert{
		warID:                         warID,
		clanTag:                       clan.Tag,
		opponentTag:                   opponent.Tag,
		prepAt:                        prepAt,
		startAt:                       startValue,
		endAt:                         endAt,
		size:                          size,
		attacksPerMember:              attacksPerMember,
		warType:                       warType,
		state:                         state,
		battleModifier:                battleModifier,
		warTag:                        warTag,
		clanName:                      clan.Name,
		opponentName:                  opponent.Name,
		clanBadgeToken:                badgeToken(clan.BadgeURLs),
		opponentBadgeToken:            badgeToken(opponent.BadgeURLs),
		clanLevel:                     clan.ClanLevel,
		opponentClanLevel:             opponent.ClanLevel,
		clanAttacks:                   clan.Attacks,
		opponentAttacks:               opponent.Attacks,
		clanStars:                     clan.Stars,
		opponentStars:                 opponent.Stars,
		clanDestructionPercentage:     clan.DestructionPercentage,
		opponentDestructionPercentage: opponent.DestructionPercentage,
	}
}

func badgeToken(badge badgeURLsDoc) string {
	return migrateutil.BadgeToken(badge.Large, badge.Medium, badge.Small)
}

func appendWarMemberRows(out *[]warMemberInsert, warID string, endAt time.Time, clan, opponent warClanDoc) {
	appendSide := func(source warClanDoc, other warClanDoc) {
		for _, member := range source.Members {
			if member.Tag == "" {
				continue
			}
			*out = append(*out, warMemberInsert{
				warID:       warID,
				warEndAt:    endAt,
				clanTag:     source.Tag,
				opponentTag: other.Tag,
				playerTag:   member.Tag,
				playerName:  member.Name,
				townhall:    member.TownhallLevel,
				mapPosition: member.MapPosition,
			})
		}
	}
	appendSide(clan, opponent)
	appendSide(opponent, clan)
}

func appendWarMissedAttackRows(out *[]warMissedAttackInsert, warID string, endAt time.Time, attacksPerMember int, clan, opponent warClanDoc) {
	appendSide := func(source warClanDoc, other warClanDoc) {
		for i := range source.Members {
			member := source.Members[i]
			if member.Tag == "" {
				continue
			}
			attackCount := len(member.Attacks)
			missed := attacksPerMember - attackCount
			if missed <= 0 {
				continue
			}
			*out = append(*out, warMissedAttackInsert{
				warID:           warID,
				warEndAt:        endAt,
				clanTag:         source.Tag,
				opponentTag:     other.Tag,
				playerTag:       member.Tag,
				playerName:      member.Name,
				townhall:        member.TownhallLevel,
				mapPosition:     member.MapPosition,
				expectedAttacks: attacksPerMember,
				attackCount:     attackCount,
				missedAttacks:   missed,
			})
		}
	}
	appendSide(clan, opponent)
	appendSide(opponent, clan)
}

func appendWarAttackRows(out *[]warAttackInsert, warID string, endAt time.Time, warType string, size int, battleModifier string, clan, opponent warClanDoc) {
	type memberInfo struct {
		clanTag       string
		name          string
		townhallLevel int
		mapPosition   int
	}
	members := make(map[string]memberInfo, len(clan.Members)+len(opponent.Members))
	addMembers := func(tag string, rawMembers []warMemberDoc) {
		for i := range rawMembers {
			member := rawMembers[i]
			if member.Tag == "" {
				continue
			}
			members[member.Tag] = memberInfo{
				clanTag:       tag,
				name:          member.Name,
				townhallLevel: member.TownhallLevel,
				mapPosition:   member.MapPosition,
			}
		}
	}
	addMembers(clan.Tag, clan.Members)
	addMembers(opponent.Tag, opponent.Members)
	appendAttacks := func(attackingClanTag string, rawMembers []warMemberDoc) {
		for i := range rawMembers {
			member := rawMembers[i]
			memberTag := member.Tag
			if memberTag == "" {
				continue
			}
			memberInfo := members[memberTag]
			for _, attack := range member.Attacks {
				attackerTag := memberTag
				attacker := memberInfo
				defenderTag := attack.DefenderTag
				defender := members[defenderTag]
				if defenderTag == "" {
					continue
				}
				if attack.AttackerTag != "" && attack.AttackerTag != memberTag {
					attackerTag = attack.AttackerTag
					attacker = members[attackerTag]
				}
				*out = append(*out, warAttackInsert{
					warID:                 warID,
					warEndAt:              endAt,
					warType:               warType,
					warSize:               size,
					attackingClanTag:      firstNonEmptyString(attacker.clanTag, attackingClanTag),
					defendingClanTag:      defender.clanTag,
					attackerTag:           attackerTag,
					attackerName:          attacker.name,
					defenderTag:           defenderTag,
					defenderName:          defender.name,
					attackerTownhall:      attacker.townhallLevel,
					defenderTownhall:      defender.townhallLevel,
					attackerMapPosition:   attacker.mapPosition,
					defenderMapPosition:   defender.mapPosition,
					stars:                 attack.Stars,
					destructionPercentage: attack.DestructionPercentage,
					duration:              attack.Duration,
					attackOrder:           attack.Order,
					battleModifier:        battleModifier,
				})
			}
		}
	}
	appendAttacks(clan.Tag, clan.Members)
	appendAttacks(opponent.Tag, opponent.Members)
}

func flushClanWarRows(ctx context.Context, pool clanWarSQL, wars []warIndexInsert, members []warMemberInsert, missedAttacks []warMissedAttackInsert, attacks []warAttackInsert) error {
	flushStarted := time.Now()
	defer func() {
		clanWarProfile.flushNanos.Add(time.Since(flushStarted).Nanoseconds())
	}()
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SET LOCAL synchronous_commit = off`); err != nil {
		return err
	}
	if len(wars) > 0 {
		copyStarted := time.Now()
		if _, err := tx.Exec(ctx, `
			CREATE TEMP TABLE _ck_wars (LIKE public.wars INCLUDING DEFAULTS) ON COMMIT DROP;
			CREATE TEMP TABLE _ck_inserted_wars (war_id text PRIMARY KEY) ON COMMIT DROP;
		`); err != nil {
			return err
		}
		if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_wars"}, warIndexCopyColumns, newWarIndexCopySource(wars)); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `
			WITH src AS (
				SELECT DISTINCT ON (war_id)
					war_id, clan_tag, opponent_tag, prep_time, start_time, end_time,
					size, attacks_per_member, war_type, state, battle_modifier, war_tag,
					clan_name, opponent_name, clan_badge_token, opponent_badge_token,
					clan_level, opponent_clan_level, clan_attacks, opponent_attacks,
					clan_stars, opponent_stars, clan_destruction_percentage, opponent_destruction_percentage
				FROM _ck_wars
				ORDER BY war_id, end_time DESC
			), inserted AS (
				INSERT INTO public.wars (
					war_id, clan_tag, opponent_tag, prep_time, start_time, end_time,
					size, attacks_per_member, war_type, state, battle_modifier, war_tag,
					clan_name, opponent_name, clan_badge_token, opponent_badge_token,
					clan_level, opponent_clan_level, clan_attacks, opponent_attacks,
					clan_stars, opponent_stars, clan_destruction_percentage, opponent_destruction_percentage
				)
				SELECT
					war_id, clan_tag, opponent_tag, prep_time, start_time, end_time,
					size, attacks_per_member, war_type, state, battle_modifier, NULLIF(war_tag, ''),
					clan_name, opponent_name, clan_badge_token, opponent_badge_token,
					clan_level, opponent_clan_level, clan_attacks, opponent_attacks,
					clan_stars, opponent_stars, clan_destruction_percentage, opponent_destruction_percentage
				FROM src
				ON CONFLICT (war_id) DO NOTHING
				RETURNING war_id
			)
			INSERT INTO _ck_inserted_wars (war_id)
			SELECT war_id FROM inserted
		`)
		if err != nil {
			return err
		}
		clanWarProfile.warsCopyNanos.Add(time.Since(copyStarted).Nanoseconds())
		clanWarProfile.warRows.Add(tag.RowsAffected())
	}
	if len(missedAttacks) > 0 {
		if _, err := tx.Exec(ctx, `CREATE TEMP TABLE _ck_war_missed_attacks (LIKE public.war_missed_attacks INCLUDING DEFAULTS) ON COMMIT DROP`); err != nil {
			return err
		}
		if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_war_missed_attacks"}, warMissedAttackCopyColumns, newWarMissedAttackCopySource(missedAttacks)); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO public.war_missed_attacks (
				war_id, war_end_time, clan_tag, opponent_tag, player_tag, player_name, townhall_level, map_position,
				expected_attacks, attack_count, missed_attacks
			)
			SELECT DISTINCT ON (m.war_id, m.war_end_time, m.player_tag)
				m.war_id, m.war_end_time, m.clan_tag, m.opponent_tag, m.player_tag, m.player_name,
				m.townhall_level, m.map_position, m.expected_attacks, m.attack_count, m.missed_attacks
			FROM _ck_war_missed_attacks m
			JOIN _ck_inserted_wars i ON i.war_id = m.war_id
			ORDER BY m.war_id, m.war_end_time, m.player_tag
		`); err != nil {
			return err
		}
	}
	if len(members) > 0 {
		if _, err := tx.Exec(ctx, `CREATE TEMP TABLE _ck_war_members (LIKE public.war_members INCLUDING DEFAULTS) ON COMMIT DROP`); err != nil {
			return err
		}
		if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_war_members"}, warMemberCopyColumns, newWarMemberCopySource(members)); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO public.war_members (
				war_id, war_end_time, clan_tag, opponent_tag, player_tag, player_name,
				townhall_level, map_position
			)
			SELECT DISTINCT ON (m.war_id, m.war_end_time, m.clan_tag, m.player_tag)
				m.war_id, m.war_end_time, m.clan_tag, m.opponent_tag, m.player_tag, m.player_name,
				m.townhall_level, m.map_position
			FROM _ck_war_members m
			JOIN _ck_inserted_wars i ON i.war_id = m.war_id
			ORDER BY m.war_id, m.war_end_time, m.clan_tag, m.player_tag
		`); err != nil {
			return err
		}
	}
	if len(attacks) > 0 {
		copyStarted := time.Now()
		if _, err := tx.Exec(ctx, `CREATE TEMP TABLE _ck_war_attacks (LIKE public.war_attacks INCLUDING DEFAULTS) ON COMMIT DROP`); err != nil {
			return err
		}
		if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_war_attacks"}, warAttackCopyColumns, newWarAttackCopySource(attacks)); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `
			INSERT INTO public.war_attacks (
				war_id, war_end_time, war_type, war_size, attacking_clan_tag, defending_clan_tag,
				attacker_tag, attacker_name, defender_tag, defender_name, attacker_townhall, defender_townhall,
				attacker_map_position, defender_map_position, stars, destruction_percentage,
				duration, attack_order, battle_modifier
			)
			SELECT DISTINCT ON (a.war_id, a.war_end_time, a.attacker_tag, a.defender_tag, a.attack_order)
				a.war_id, a.war_end_time, a.war_type, a.war_size, a.attacking_clan_tag, a.defending_clan_tag,
				a.attacker_tag, a.attacker_name, a.defender_tag, a.defender_name, a.attacker_townhall, a.defender_townhall,
				a.attacker_map_position, a.defender_map_position, a.stars, a.destruction_percentage,
				a.duration, a.attack_order, a.battle_modifier
			FROM _ck_war_attacks a
			JOIN _ck_inserted_wars i ON i.war_id = a.war_id
			ORDER BY a.war_id, a.war_end_time, a.attacker_tag, a.defender_tag, a.attack_order
		`)
		if err != nil {
			return err
		}
		clanWarProfile.attacksCopyNanos.Add(time.Since(copyStarted).Nanoseconds())
		clanWarProfile.attackRows.Add(tag.RowsAffected())
	}
	return tx.Commit(ctx)
}

var warIndexCopyColumns = []string{
	"war_id", "clan_tag", "opponent_tag", "prep_time", "start_time", "end_time",
	"size", "attacks_per_member", "war_type", "state", "battle_modifier", "war_tag",
	"clan_name", "opponent_name", "clan_badge_token", "opponent_badge_token",
	"clan_level", "opponent_clan_level", "clan_attacks", "opponent_attacks",
	"clan_stars", "opponent_stars", "clan_destruction_percentage", "opponent_destruction_percentage",
}

var warAttackCopyColumns = []string{
	"war_id", "war_end_time", "war_type", "war_size", "attacking_clan_tag", "defending_clan_tag",
	"attacker_tag", "attacker_name", "defender_tag", "defender_name", "attacker_townhall", "defender_townhall",
	"attacker_map_position", "defender_map_position", "stars", "destruction_percentage",
	"duration", "attack_order", "battle_modifier",
}

var warMemberCopyColumns = []string{
	"war_id", "war_end_time", "clan_tag", "opponent_tag", "player_tag", "player_name",
	"townhall_level", "map_position",
}

var warMissedAttackCopyColumns = []string{
	"war_id", "war_end_time", "clan_tag", "opponent_tag", "player_tag", "player_name", "townhall_level", "map_position",
	"expected_attacks", "attack_count", "missed_attacks",
}

type warIndexCopySource struct {
	rows   []warIndexInsert
	idx    int
	values []any
}

func newWarIndexCopySource(rows []warIndexInsert) *warIndexCopySource {
	return &warIndexCopySource{rows: rows, idx: -1, values: make([]any, 24)}
}

func (s *warIndexCopySource) Next() bool {
	s.idx++
	return s.idx < len(s.rows)
}

func (s *warIndexCopySource) Values() ([]any, error) {
	row := s.rows[s.idx]
	s.values[0] = row.warID
	s.values[1] = row.clanTag
	s.values[2] = row.opponentTag
	s.values[3] = row.prepAt
	s.values[4] = row.startAt
	s.values[5] = row.endAt
	s.values[6] = row.size
	s.values[7] = row.attacksPerMember
	s.values[8] = row.warType
	s.values[9] = row.state
	s.values[10] = row.battleModifier
	s.values[11] = row.warTag
	s.values[12] = row.clanName
	s.values[13] = row.opponentName
	s.values[14] = row.clanBadgeToken
	s.values[15] = row.opponentBadgeToken
	s.values[16] = row.clanLevel
	s.values[17] = row.opponentClanLevel
	s.values[18] = row.clanAttacks
	s.values[19] = row.opponentAttacks
	s.values[20] = row.clanStars
	s.values[21] = row.opponentStars
	s.values[22] = row.clanDestructionPercentage
	s.values[23] = row.opponentDestructionPercentage
	return s.values, nil
}

func (s *warIndexCopySource) Err() error { return nil }

type warMemberCopySource struct {
	rows   []warMemberInsert
	idx    int
	values []any
}

func newWarMemberCopySource(rows []warMemberInsert) *warMemberCopySource {
	return &warMemberCopySource{rows: rows, idx: -1, values: make([]any, 8)}
}

func (s *warMemberCopySource) Next() bool {
	s.idx++
	return s.idx < len(s.rows)
}

func (s *warMemberCopySource) Values() ([]any, error) {
	row := s.rows[s.idx]
	s.values[0] = row.warID
	s.values[1] = row.warEndAt
	s.values[2] = row.clanTag
	s.values[3] = row.opponentTag
	s.values[4] = row.playerTag
	s.values[5] = row.playerName
	s.values[6] = row.townhall
	s.values[7] = row.mapPosition
	return s.values, nil
}

func (s *warMemberCopySource) Err() error { return nil }

type warMissedAttackCopySource struct {
	rows   []warMissedAttackInsert
	idx    int
	values []any
}

func newWarMissedAttackCopySource(rows []warMissedAttackInsert) *warMissedAttackCopySource {
	return &warMissedAttackCopySource{rows: rows, idx: -1, values: make([]any, 11)}
}

func (s *warMissedAttackCopySource) Next() bool {
	s.idx++
	return s.idx < len(s.rows)
}

func (s *warMissedAttackCopySource) Values() ([]any, error) {
	row := s.rows[s.idx]
	s.values[0] = row.warID
	s.values[1] = row.warEndAt
	s.values[2] = row.clanTag
	s.values[3] = row.opponentTag
	s.values[4] = row.playerTag
	s.values[5] = row.playerName
	s.values[6] = row.townhall
	s.values[7] = row.mapPosition
	s.values[8] = row.expectedAttacks
	s.values[9] = row.attackCount
	s.values[10] = row.missedAttacks
	return s.values, nil
}

func (s *warMissedAttackCopySource) Err() error { return nil }

type warAttackCopySource struct {
	rows   []warAttackInsert
	idx    int
	values []any
}

func newWarAttackCopySource(rows []warAttackInsert) *warAttackCopySource {
	return &warAttackCopySource{rows: rows, idx: -1, values: make([]any, 19)}
}

func (s *warAttackCopySource) Next() bool {
	s.idx++
	return s.idx < len(s.rows)
}

func (s *warAttackCopySource) Values() ([]any, error) {
	row := s.rows[s.idx]
	s.values[0] = row.warID
	s.values[1] = row.warEndAt
	s.values[2] = row.warType
	s.values[3] = row.warSize
	s.values[4] = row.attackingClanTag
	s.values[5] = row.defendingClanTag
	s.values[6] = row.attackerTag
	s.values[7] = row.attackerName
	s.values[8] = row.defenderTag
	s.values[9] = row.defenderName
	s.values[10] = row.attackerTownhall
	s.values[11] = row.defenderTownhall
	s.values[12] = row.attackerMapPosition
	s.values[13] = row.defenderMapPosition
	s.values[14] = row.stars
	s.values[15] = row.destructionPercentage
	s.values[16] = row.duration
	s.values[17] = row.attackOrder
	s.values[18] = row.battleModifier
	return s.values, nil
}

func (s *warAttackCopySource) Err() error { return nil }

func dropClanWarIndexes(ctx context.Context, db interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}) error {
	_, err := db.Exec(ctx, `
		ALTER TABLE public.war_attacks DROP CONSTRAINT IF EXISTS war_attacks_pkey;
		ALTER TABLE public.war_members DROP CONSTRAINT IF EXISTS war_members_pkey;
		ALTER TABLE public.war_missed_attacks DROP CONSTRAINT IF EXISTS war_missed_attacks_pkey;
		DROP INDEX IF EXISTS public.idx_war_attacks_clan_time;
		DROP INDEX IF EXISTS public.idx_war_attacks_hitrate;
		DROP INDEX IF EXISTS public.idx_war_attacks_player_time;
		DROP INDEX IF EXISTS public.war_attacks_war_end_time_idx;
		DROP INDEX IF EXISTS public.idx_war_members_player_time;
		DROP INDEX IF EXISTS public.idx_war_missed_attacks_clan_time;
		DROP INDEX IF EXISTS public.idx_war_missed_attacks_player_time;
		DROP INDEX IF EXISTS public.idx_wars_clan_end_time;
		DROP INDEX IF EXISTS public.idx_wars_opponent_end_time;
		DROP INDEX IF EXISTS public.idx_wars_war_tag;
	`)
	return err
}

func recreateClanWarIndexes(ctx context.Context, db interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}) error {
	started := time.Now()
	defer func() {
		clanWarProfile.recreateNanos.Add(time.Since(started).Nanoseconds())
	}()
	_, err := db.Exec(ctx, `
		SET maintenance_work_mem = '1GB';
		SET max_parallel_maintenance_workers = 4;
		ALTER TABLE public.war_attacks ADD CONSTRAINT war_attacks_pkey PRIMARY KEY (war_id, war_end_time, attacker_tag, defender_tag, attack_order);
		ALTER TABLE public.war_members ADD CONSTRAINT war_members_pkey PRIMARY KEY (war_id, war_end_time, clan_tag, player_tag);
		ALTER TABLE public.war_missed_attacks ADD CONSTRAINT war_missed_attacks_pkey PRIMARY KEY (war_id, war_end_time, player_tag);
		CREATE INDEX IF NOT EXISTS idx_war_attacks_clan_time ON public.war_attacks USING btree (attacking_clan_tag, war_end_time DESC);
		CREATE INDEX IF NOT EXISTS idx_war_attacks_hitrate ON public.war_attacks USING btree (attacker_townhall, defender_townhall, war_type, war_end_time DESC);
		CREATE INDEX IF NOT EXISTS idx_war_attacks_player_time ON public.war_attacks USING btree (attacker_tag, war_end_time DESC);
		CREATE INDEX IF NOT EXISTS idx_war_members_player_time ON public.war_members USING btree (player_tag, war_end_time DESC);
		CREATE INDEX IF NOT EXISTS idx_war_missed_attacks_clan_time ON public.war_missed_attacks USING btree (clan_tag, war_end_time DESC);
		CREATE INDEX IF NOT EXISTS idx_war_missed_attacks_player_time ON public.war_missed_attacks USING btree (player_tag, war_end_time DESC);
		CREATE INDEX IF NOT EXISTS idx_wars_clan_end_time ON public.wars USING btree (clan_tag, end_time DESC);
		CREATE INDEX IF NOT EXISTS idx_wars_opponent_end_time ON public.wars USING btree (opponent_tag, end_time DESC);
		CREATE INDEX IF NOT EXISTS idx_wars_war_tag ON public.wars USING btree (war_tag) WHERE (war_tag IS NOT NULL);
	`)
	return err
}

var clanWarProfile clanWarProfileCounters

type clanWarProfileCounters struct {
	scanNanos        atomic.Int64
	flushNanos       atomic.Int64
	warsCopyNanos    atomic.Int64
	attacksCopyNanos atomic.Int64
	recreateNanos    atomic.Int64
	warRows          atomic.Int64
	attackRows       atomic.Int64
}

func printClanWarProfile(total time.Duration) {
	fmt.Fprintf(os.Stderr,
		"\nprofile total=%s scan_worker_sum=%s flush_sum=%s copy_wars=%s(%d rows) copy_attacks=%s(%d rows) recreate=%s\n",
		total.Round(time.Millisecond),
		time.Duration(clanWarProfile.scanNanos.Load()).Round(time.Millisecond),
		time.Duration(clanWarProfile.flushNanos.Load()).Round(time.Millisecond),
		time.Duration(clanWarProfile.warsCopyNanos.Load()).Round(time.Millisecond),
		clanWarProfile.warRows.Load(),
		time.Duration(clanWarProfile.attacksCopyNanos.Load()).Round(time.Millisecond),
		clanWarProfile.attackRows.Load(),
		time.Duration(clanWarProfile.recreateNanos.Load()).Round(time.Millisecond),
	)
}

func isFinishedWar(state string) bool {
	return state == "warEnded" || state == "ended" || state == "notInWar"
}

func computeWarKey(left, right string, prepAt time.Time) string {
	tags := []string{left, right}
	sort.Strings(tags)
	return tags[0] + "-" + tags[1] + "-" + fmt.Sprintf("%d", prepAt.Unix())
}

func firstWar(values ...any) any {
	for _, value := range values {
		if migrateutil.String(value) != "" {
			return value
		}
	}
	return nil
}

func firstWarString(values ...any) string {
	return migrateutil.String(firstWar(values...))
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func normalizeBattleModifier(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || strings.EqualFold(value, "null") {
		return "none"
	}
	return value
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}

func ceilDiv(value, by int) int {
	if by <= 0 {
		return value
	}
	return (value + by - 1) / by
}

func clanWarEnvInt(env map[string]string, key string, fallback int) int {
	if raw := migrateutil.String(env[key]); raw != "" {
		if out, err := strconv.Atoi(raw); err == nil {
			return out
		}
	}
	return fallback
}

func envBool(env map[string]string, key string) bool {
	value := strings.TrimSpace(strings.ToLower(env[key]))
	return value == "1" || value == "true" || value == "yes"
}
