// Package wararchive defines ClashKing's shared R2 war archive format.
package wararchive

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/klauspost/compress/zstd"
)

// War is the canonical representation stored in R2. It deliberately resembles
// the Clash API response, but badge URL objects become stable badge tokens and
// redundant best-attack fields are not represented.
type War struct {
	// ID identifies the SQL row and is never serialized into an archive frame.
	ID                   uuid.UUID  `json:"-"`
	WarTag               string     `json:"warTag,omitempty"`
	Type                 string     `json:"type"`
	State                string     `json:"state"`
	TeamSize             int        `json:"teamSize"`
	AttacksPerMember     int        `json:"attacksPerMember"`
	PreparationStartTime time.Time  `json:"preparationStartTime"`
	StartTime            *time.Time `json:"startTime,omitempty"`
	EndTime              time.Time  `json:"endTime"`
	BattleModifier       string     `json:"battleModifier,omitempty"`
	Clan                 Clan       `json:"clan"`
	Opponent             Clan       `json:"opponent"`
}

type Clan struct {
	Tag                   string   `json:"tag"`
	Name                  string   `json:"name,omitempty"`
	BadgeToken            string   `json:"badgeToken,omitempty"`
	ClanLevel             int      `json:"clanLevel,omitempty"`
	Attacks               int      `json:"attacks,omitempty"`
	Stars                 int      `json:"stars,omitempty"`
	DestructionPercentage float64  `json:"destructionPercentage,omitempty"`
	Members               []Member `json:"members"`
}

type Member struct {
	Tag           string   `json:"tag"`
	Name          string   `json:"name,omitempty"`
	TownhallLevel int      `json:"townhallLevel,omitempty"`
	MapPosition   int      `json:"mapPosition,omitempty"`
	Attacks       []Attack `json:"attacks,omitempty"`
}

// AttackerTag is intentionally omitted because an attack is nested beneath its
// attacker. The original shape is reconstructed by copying Member.Tag.
type Attack struct {
	DefenderTag           string `json:"defenderTag"`
	Stars                 int    `json:"stars"`
	DestructionPercentage int    `json:"destructionPercentage"`
	Duration              int    `json:"duration"`
	Order                 int    `json:"order"`
}

const (
	BattleModifierNone       = "none"
	BattleModifierHardMode   = "hardMode"
	BattleModifierMinusOne   = "minusOne"
	BattleModifierMinusTwo   = "minusTwo"
	BattleModifierMinusThree = "minusThree"
)

// NormalizeBattleModifier maps absent legacy values and historical spellings
// onto the camel-case enum emitted by the current Clash API.
func NormalizeBattleModifier(value string) string {
	key := strings.ToLower(strings.TrimSpace(value))
	key = strings.NewReplacer("_", "", "-", "", " ", "").Replace(key)
	switch key {
	case "", "null", BattleModifierNone:
		return BattleModifierNone
	case "hardmode":
		return BattleModifierHardMode
	case "minusone":
		return BattleModifierMinusOne
	case "minustwo":
		return BattleModifierMinusTwo
	case "minusthree":
		return BattleModifierMinusThree
	default:
		return BattleModifierNone
	}
}

type Locator struct {
	WarID           uuid.UUID `json:"war_id"`
	PackID          uint64    `json:"pack_id"`
	Offset          int64     `json:"offset"`
	CompressedBytes int       `json:"compressed_bytes"`
	RawBytes        int       `json:"raw_bytes"`
}

// PackStats contains additive values only. That lets callers merge statistics
// from many packs without reconstructing the archived wars or averaging
// already-averaged values.
type PackStats struct {
	Wars    WarStats    `json:"wars"`
	Sides   SideStats   `json:"sides"`
	Attacks AttackStats `json:"attacks"`
}

type WarStats struct {
	Total             int            `json:"total"`
	ByType            map[string]int `json:"byType"`
	BySize            map[string]int `json:"bySize"`
	ByBattleModifier  map[string]int `json:"byBattleModifier"`
	ByTypeAndSize     map[string]int `json:"byTypeAndSize"`
	ByModifierAndSize map[string]int `json:"byModifierAndSize"`
}

type SideStats struct {
	Clan     ClanSideStats `json:"clan"`
	Opponent ClanSideStats `json:"opponent"`
}

type ClanSideStats struct {
	MembersByTownhall map[string]int `json:"membersByTownhall"`
	WarsByStars       map[string]int `json:"warsByStars"`
	WarsByAttacksUsed map[string]int `json:"warsByAttacksUsed"`
}

type AttackStats struct {
	Total             int                        `json:"total"`
	Stars             map[string]int             `json:"stars"`
	AttackerTownhalls map[string]int             `json:"attackerTownhalls"`
	DefenderTownhalls map[string]int             `json:"defenderTownhalls"`
	TownhallMatchups  map[string]AttackAggregate `json:"townhallMatchups"`
	ByWarType         map[string]AttackAggregate `json:"byWarType"`
	ByWarSize         map[string]AttackAggregate `json:"byWarSize"`
	ByBattleModifier  map[string]AttackAggregate `json:"byBattleModifier"`
	ByWeekTypeMatchup map[string]AttackAggregate `json:"byWeekTypeMatchup"`
	ByDayTypeMatchup  map[string]AttackAggregate `json:"byDayTypeMatchup"`
}

type AttackAggregate struct {
	Attacks            int   `json:"attacks"`
	Stars              int   `json:"stars"`
	Triples            int   `json:"triples"`
	ZeroStars          int   `json:"zeroStars"`
	OneStars           int   `json:"oneStars"`
	TwoStars           int   `json:"twoStars"`
	DestructionPercent int64 `json:"destructionPercent"`
	DurationSeconds    int64 `json:"durationSeconds"`
}

// DeterministicV7 makes historical imports idempotent while retaining the same
// UUIDv7 shape used by live tracking. The timestamp comes from preparation time
// and the remaining bits come from stable war identity fields.
func DeterministicV7(clanTag, opponentTag string, preparation time.Time, warTag string) uuid.UUID {
	tags := []string{strings.ToUpper(clanTag), strings.ToUpper(opponentTag)}
	sort.Strings(tags)
	identity := fmt.Sprintf("%s\x00%s\x00%d\x00%s", tags[0], tags[1], preparation.UTC().UnixMilli(), strings.ToUpper(warTag))
	hash := sha256.Sum256([]byte(identity))
	var id uuid.UUID
	milliseconds := uint64(preparation.UTC().UnixMilli())
	id[0] = byte(milliseconds >> 40)
	id[1] = byte(milliseconds >> 32)
	id[2] = byte(milliseconds >> 24)
	id[3] = byte(milliseconds >> 16)
	id[4] = byte(milliseconds >> 8)
	id[5] = byte(milliseconds)
	copy(id[6:], hash[:10])
	id[6] = (id[6] & 0x0f) | 0x70
	id[8] = (id[8] & 0x3f) | 0x80
	return id
}

func Marshal(war War) ([]byte, error) {
	return json.Marshal(war)
}

func Unmarshal(data []byte) (War, error) {
	var war War
	err := json.Unmarshal(data, &war)
	return war, err
}

type PackBuilder struct {
	id      uint64
	buffer  bytes.Buffer
	encoder *zstd.Encoder
	rows    []Locator
}

func NewPackBuilder(id uint64, dictionary []byte) (*PackBuilder, error) {
	options := []zstd.EOption{
		zstd.WithEncoderLevel(zstd.EncoderLevelFromZstd(3)),
		zstd.WithEncoderConcurrency(1),
		zstd.WithEncoderCRC(true),
	}
	if len(dictionary) > 0 {
		options = append(options, zstd.WithEncoderDict(dictionary))
	}
	encoder, err := zstd.NewWriter(nil, options...)
	if err != nil {
		return nil, err
	}
	return &PackBuilder{id: id, encoder: encoder}, nil
}

func (b *PackBuilder) Add(warID uuid.UUID, war War) (Locator, error) {
	raw, err := Marshal(war)
	if err != nil {
		return Locator{}, err
	}
	compressed := b.encoder.EncodeAll(raw, nil)
	locator := Locator{
		WarID:           warID,
		PackID:          b.id,
		Offset:          int64(b.buffer.Len()),
		CompressedBytes: len(compressed),
		RawBytes:        len(raw),
	}
	if _, err := b.buffer.Write(compressed); err != nil {
		return Locator{}, err
	}
	b.rows = append(b.rows, locator)
	return locator, nil
}

func (b *PackBuilder) Bytes() []byte       { return b.buffer.Bytes() }
func (b *PackBuilder) Locators() []Locator { return b.rows }
func (b *PackBuilder) Len() int            { return len(b.rows) }
func (b *PackBuilder) Close()              { b.encoder.Close() }

func ObjectKey(packID uint64) string {
	return fmt.Sprintf("packs/%06d.pack", packID)
}

func DecodeFrame(frame, dictionary []byte) ([]byte, error) {
	options := []zstd.DOption{zstd.WithDecoderConcurrency(1)}
	if len(dictionary) > 0 {
		options = append(options, zstd.WithDecoderDicts(dictionary))
	}
	decoder, err := zstd.NewReader(nil, options...)
	if err != nil {
		return nil, err
	}
	defer decoder.Close()
	return decoder.DecodeAll(frame, nil)
}

func NewPackStats() PackStats {
	return PackStats{
		Wars: WarStats{
			ByType: map[string]int{}, BySize: map[string]int{}, ByBattleModifier: map[string]int{},
			ByTypeAndSize: map[string]int{}, ByModifierAndSize: map[string]int{},
		},
		Sides: SideStats{
			Clan: newClanSideStats(), Opponent: newClanSideStats(),
		},
		Attacks: AttackStats{
			Stars: map[string]int{}, AttackerTownhalls: map[string]int{}, DefenderTownhalls: map[string]int{},
			TownhallMatchups: map[string]AttackAggregate{}, ByWarType: map[string]AttackAggregate{},
			ByWarSize: map[string]AttackAggregate{}, ByBattleModifier: map[string]AttackAggregate{},
			ByWeekTypeMatchup: map[string]AttackAggregate{}, ByDayTypeMatchup: map[string]AttackAggregate{},
		},
	}
}

func newClanSideStats() ClanSideStats {
	return ClanSideStats{MembersByTownhall: map[string]int{}, WarsByStars: map[string]int{}, WarsByAttacksUsed: map[string]int{}}
}

func (s *PackStats) Add(war War) {
	warType := defaultDimension(war.Type, "random")
	modifier := defaultDimension(war.BattleModifier, "none")
	size := fmt.Sprint(war.TeamSize)
	s.Wars.Total++
	s.Wars.ByType[warType]++
	s.Wars.BySize[size]++
	s.Wars.ByBattleModifier[modifier]++
	s.Wars.ByTypeAndSize[warType+":"+size]++
	s.Wars.ByModifierAndSize[modifier+":"+size]++
	s.addClanSide(&s.Sides.Clan, war.Clan)
	s.addClanSide(&s.Sides.Opponent, war.Opponent)
	s.addAttacks(war, war.Clan, war.Opponent)
	s.addAttacks(war, war.Opponent, war.Clan)
}

func (s *PackStats) addClanSide(side *ClanSideStats, clan Clan) {
	side.WarsByStars[fmt.Sprint(clan.Stars)]++
	side.WarsByAttacksUsed[fmt.Sprint(clan.Attacks)]++
	for _, member := range clan.Members {
		side.MembersByTownhall[fmt.Sprint(member.TownhallLevel)]++
	}
}

func (s *PackStats) addAttacks(war War, attacking, defending Clan) {
	defenders := make(map[string]int, len(defending.Members))
	for _, member := range defending.Members {
		defenders[member.Tag] = member.TownhallLevel
	}
	warType := defaultDimension(war.Type, "random")
	size := fmt.Sprint(war.TeamSize)
	modifier := defaultDimension(war.BattleModifier, "none")
	for _, member := range attacking.Members {
		for _, attack := range member.Attacks {
			defenderTH := defenders[attack.DefenderTag]
			s.Attacks.Total++
			s.Attacks.Stars[fmt.Sprint(attack.Stars)]++
			s.Attacks.AttackerTownhalls[fmt.Sprint(member.TownhallLevel)]++
			s.Attacks.DefenderTownhalls[fmt.Sprint(defenderTH)]++
			addAttackAggregate(s.Attacks.TownhallMatchups, fmt.Sprintf("%d:%d", member.TownhallLevel, defenderTH), attack)
			addAttackAggregate(s.Attacks.ByWarType, warType, attack)
			addAttackAggregate(s.Attacks.ByWarSize, size, attack)
			addAttackAggregate(s.Attacks.ByBattleModifier, modifier, attack)
			week := war.EndTime.UTC().AddDate(0, 0, -int(war.EndTime.UTC().Weekday()+6)%7).Format("2006-01-02")
			addAttackAggregate(s.Attacks.ByWeekTypeMatchup, fmt.Sprintf("%s|%s|%d|%d", week, warType, member.TownhallLevel, defenderTH), attack)
			day := war.EndTime.UTC().Format("2006-01-02")
			addAttackAggregate(s.Attacks.ByDayTypeMatchup, fmt.Sprintf("%s|%s|%d|%d", day, warType, member.TownhallLevel, defenderTH), attack)
		}
	}
}

func addAttackAggregate(values map[string]AttackAggregate, key string, attack Attack) {
	value := values[key]
	value.Attacks++
	value.Stars += attack.Stars
	if attack.Stars == 3 {
		value.Triples++
	} else if attack.Stars == 2 {
		value.TwoStars++
	} else if attack.Stars == 1 {
		value.OneStars++
	} else {
		value.ZeroStars++
	}
	value.DestructionPercent += int64(attack.DestructionPercentage)
	value.DurationSeconds += int64(attack.Duration)
	values[key] = value
}

func defaultDimension(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return strings.ToLower(value)
}
