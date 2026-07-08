//go:build ignore

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"clashking_schemas_migrations/migrateutil"
	"github.com/disgoorg/disgo/discord"
	disgo "github.com/disgoorg/disgo/rest"
	"github.com/disgoorg/snowflake/v2"
	"github.com/jackc/pgx/v5"
)

const (
	defaultLinkAPIBaseURL = "https://cocdiscord.link"
	defaultLinkBatchSize  = 1000
	linkSource            = "discord_links_import"
)

type settings struct {
	BotToken        string
	LinkAPIUser     string
	LinkAPIPassword string
	LinkAPIBaseURL  string
	GuildIDs        []string
	BatchSize       int
	DryRun          bool
	DiscordDelay    time.Duration
}

type guildRef struct {
	ID   string
	Name string
}

type linkRow struct {
	Tag        string
	UserID     string
	OrderIndex int
}

type linkAPIClient struct {
	baseURL  string
	username string
	password string
	http     *http.Client
	token    string
}

type discordSource struct {
	client disgo.Rest
	delay  time.Duration
}

func main() {
	migrateutil.Main("player_links", runPlayerLinks)
}

func runPlayerLinks(ctx context.Context, cfg migrateutil.Config) error {
	s, err := loadSettings(cfg)
	if err != nil {
		return err
	}

	cp, err := migrateutil.LoadCheckpoint(cfg, "player_links")
	if err != nil {
		return err
	}
	var pool interface {
		Begin(context.Context) (pgx.Tx, error)
	}
	if !s.DryRun {
		dbPool, err := migrateutil.TimescalePool(ctx, cfg)
		if err != nil {
			return err
		}
		defer dbPool.Close()
		pool = dbPool
	}

	discordClient := disgo.New(disgo.NewClient(s.BotToken))
	defer discordClient.Close(ctx)
	discord := &discordSource{client: discordClient, delay: s.DiscordDelay}
	linkClient := newLinkAPIClient(s)

	guilds, err := guildsForRun(ctx, discord, s)
	if err != nil {
		return err
	}
	if len(guilds) == 0 {
		return errors.New("no bot guilds found")
	}
	fmt.Fprintf(os.Stderr, "player_links: guilds=%d batch_size=%d dry_run=%t link_api=%s\n", len(guilds), s.BatchSize, s.DryRun, s.LinkAPIBaseURL)

	seenDiscordIDs := map[string]struct{}{}
	var scannedGuilds, skippedGuilds, membersSeen, linkBatches, rowsWritten int64
	for i, guild := range guilds {
		if cp.Get(completedGuildKey(guild.ID)) == "true" {
			skippedGuilds++
			fmt.Fprintf(os.Stderr, "player_links: skip completed guild=%s name=%q index=%d/%d\n", guild.ID, guild.Name, i+1, len(guilds))
			continue
		}

		memberIDs, err := discord.guildMemberIDs(ctx, guild.ID)
		if err != nil {
			return fmt.Errorf("guild %s members: %w", guild.ID, err)
		}
		scannedGuilds++
		membersSeen += int64(len(memberIDs))
		newIDs := uniqueNewIDs(seenDiscordIDs, memberIDs)
		fmt.Fprintf(os.Stderr, "player_links: guild=%s name=%q index=%d/%d members=%d new_unique_ids=%d run_unique_ids=%d\n",
			guild.ID, guild.Name, i+1, len(guilds), len(memberIDs), len(newIDs), len(seenDiscordIDs))

		for _, batch := range chunkStrings(newIDs, s.BatchSize) {
			links, err := linkClient.LinkedPlayers(ctx, batch)
			if err != nil {
				return fmt.Errorf("link api batch guild=%s size=%d: %w", guild.ID, len(batch), err)
			}
			linkBatches++
			rows := rowsFromLinks(links)
			if len(rows) == 0 {
				fmt.Fprintf(os.Stderr, "player_links: guild=%s link_batch=%d ids=%d rows=0\n", guild.ID, linkBatches, len(batch))
				continue
			}
			if s.DryRun {
				rowsWritten += int64(len(rows))
				fmt.Fprintf(os.Stderr, "player_links: dry_run guild=%s link_batch=%d ids=%d rows=%d\n", guild.ID, linkBatches, len(batch), len(rows))
				continue
			}
			written, err := flushPlayerLinkRows(ctx, pool, rows)
			if err != nil {
				return fmt.Errorf("write guild=%s rows=%d: %w", guild.ID, len(rows), err)
			}
			rowsWritten += written
			fmt.Fprintf(os.Stderr, "player_links: wrote guild=%s link_batch=%d ids=%d rows=%d total_rows=%d\n", guild.ID, linkBatches, len(batch), written, rowsWritten)
		}

		if !s.DryRun {
			if err := cp.Set(completedGuildKey(guild.ID), "true"); err != nil {
				return err
			}
		}
	}

	fmt.Printf("player_links: guilds_scanned=%d guilds_skipped=%d members_seen=%d unique_discord_ids=%d link_api_batches=%d rows_%s=%d\n",
		scannedGuilds, skippedGuilds, membersSeen, len(seenDiscordIDs), linkBatches, ternary(s.DryRun, "staged", "written"), rowsWritten)
	return nil
}

func loadSettings(cfg migrateutil.Config) (settings, error) {
	s := settings{
		BotToken:        strings.TrimSpace(cfg.Env["BOT_TOKEN"]),
		LinkAPIUser:     strings.TrimSpace(cfg.Env["LINK_API_USER"]),
		LinkAPIPassword: strings.TrimSpace(cfg.Env["LINK_API_PW"]),
		LinkAPIBaseURL:  strings.TrimRight(firstNonEmpty(cfg.Env["LINK_API_BASE_URL"], defaultLinkAPIBaseURL), "/"),
		BatchSize:       envInt(cfg.Env, "PLAYER_LINKS_BATCH_SIZE", defaultLinkBatchSize),
		DryRun:          envBool(cfg.Env, "PLAYER_LINKS_DRY_RUN"),
		DiscordDelay:    time.Duration(envInt(cfg.Env, "DISCORD_REQUEST_DELAY_MS", 250)) * time.Millisecond,
	}
	if s.BotToken == "" {
		return settings{}, errors.New("missing BOT_TOKEN in .env")
	}
	if s.LinkAPIUser == "" || s.LinkAPIPassword == "" {
		return settings{}, errors.New("missing LINK_API_USER/LINK_API_PW in .env")
	}
	if s.LinkAPIBaseURL == "" {
		return settings{}, errors.New("missing LINK_API_BASE_URL")
	}
	if s.BatchSize <= 0 {
		s.BatchSize = defaultLinkBatchSize
	}
	if s.BatchSize > defaultLinkBatchSize {
		s.BatchSize = defaultLinkBatchSize
	}
	s.GuildIDs = splitCSV(cfg.Env["PLAYER_LINKS_GUILD_IDS"])
	return s, nil
}

func guildsForRun(ctx context.Context, source *discordSource, s settings) ([]guildRef, error) {
	if len(s.GuildIDs) > 0 {
		guilds := make([]guildRef, 0, len(s.GuildIDs))
		for _, id := range s.GuildIDs {
			if _, err := parseSnowflake(id); err != nil {
				return nil, fmt.Errorf("bad PLAYER_LINKS_GUILD_IDS value %q: %w", id, err)
			}
			guilds = append(guilds, guildRef{ID: id})
		}
		return guilds, nil
	}
	return source.botGuilds(ctx)
}

func (s *discordSource) botGuilds(ctx context.Context) ([]guildRef, error) {
	var guilds []guildRef
	var before snowflake.ID
	for {
		if err := s.wait(ctx); err != nil {
			return nil, err
		}
		page, err := s.client.GetCurrentUserGuilds("", before, 0, 200, false, disgo.WithCtx(ctx))
		if err != nil {
			return nil, err
		}
		if len(page) == 0 {
			break
		}
		for _, guild := range page {
			guilds = append(guilds, guildRef{ID: guild.ID.String(), Name: guild.Name})
		}
		before = page[len(page)-1].ID
		if len(page) < 200 {
			break
		}
	}
	sort.Slice(guilds, func(i, j int) bool { return guilds[i].ID < guilds[j].ID })
	return guilds, nil
}

func (s *discordSource) guildMemberIDs(ctx context.Context, guildID string) ([]string, error) {
	id, err := parseSnowflake(guildID)
	if err != nil {
		return nil, err
	}
	ids := map[string]struct{}{}
	var after snowflake.ID
	for {
		if err := s.wait(ctx); err != nil {
			return nil, err
		}
		batch, err := s.client.GetMembers(id, 1000, after, disgo.WithCtx(ctx))
		if err != nil {
			return nil, err
		}
		if len(batch) == 0 {
			break
		}
		addMemberIDs(ids, batch)
		for _, member := range batch {
			if member.User.ID > after {
				after = member.User.ID
			}
		}
		if len(batch) < 1000 {
			break
		}
	}
	out := make([]string, 0, len(ids))
	for id := range ids {
		out = append(out, id)
	}
	sort.Strings(out)
	return out, nil
}

func (s *discordSource) wait(ctx context.Context) error {
	if s.delay <= 0 {
		return nil
	}
	timer := time.NewTimer(s.delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func addMemberIDs(dst map[string]struct{}, members []discord.Member) {
	for _, member := range members {
		id := member.User.ID.String()
		if id != "" && id != "0" {
			dst[id] = struct{}{}
		}
	}
}

func uniqueNewIDs(seen map[string]struct{}, ids []string) []string {
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

func newLinkAPIClient(s settings) *linkAPIClient {
	return &linkAPIClient{
		baseURL:  s.LinkAPIBaseURL,
		username: s.LinkAPIUser,
		password: s.LinkAPIPassword,
		http:     &http.Client{Timeout: 30 * time.Second},
	}
}

func (c *linkAPIClient) LinkedPlayers(ctx context.Context, discordIDs []string) ([]linkRow, error) {
	if len(discordIDs) == 0 {
		return nil, nil
	}
	if len(discordIDs) > defaultLinkBatchSize {
		return nil, fmt.Errorf("link api batch too large: %d > %d", len(discordIDs), defaultLinkBatchSize)
	}
	if c.token == "" {
		if err := c.login(ctx); err != nil {
			return nil, err
		}
	}

	var lastErr error
	for attempt := 0; attempt < 4; attempt++ {
		rows, status, err := c.postBatch(ctx, discordIDs)
		if err == nil {
			return rows, nil
		}
		lastErr = err
		if status == http.StatusUnauthorized && attempt == 0 {
			c.token = ""
			if err := c.login(ctx); err != nil {
				return nil, err
			}
			continue
		}
		if status != http.StatusTooManyRequests && (status < 500 || status == 0) {
			break
		}
		if err := sleepBackoff(ctx, attempt); err != nil {
			return nil, err
		}
	}
	return nil, lastErr
}

func (c *linkAPIClient) login(ctx context.Context) error {
	payload, err := json.Marshal(map[string]string{
		"username": c.username,
		"password": c.password,
	})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/login", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("link api login failed: status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var out struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return err
	}
	if out.Token == "" {
		return errors.New("link api login response missing token")
	}
	c.token = out.Token
	return nil
}

func (c *linkAPIClient) postBatch(ctx context.Context, discordIDs []string) ([]linkRow, int, error) {
	payload, err := json.Marshal(discordIDs)
	if err != nil {
		return nil, 0, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/batch", bytes.NewReader(payload))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, resp.StatusCode, fmt.Errorf("link api batch failed: status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	rows, err := decodeLinkRows(bytes.NewReader(body))
	if err != nil {
		return nil, resp.StatusCode, err
	}
	return rows, resp.StatusCode, nil
}

func decodeLinkRows(r io.Reader) ([]linkRow, error) {
	var payload []struct {
		PlayerTag string `json:"playerTag"`
		DiscordID string `json:"discordId"`
	}
	if err := json.NewDecoder(r).Decode(&payload); err != nil {
		return nil, err
	}
	rows := make([]linkRow, 0, len(payload))
	for _, item := range payload {
		tag := normalizeTag(item.PlayerTag)
		userID := strings.TrimSpace(item.DiscordID)
		if tag == "" || userID == "" {
			continue
		}
		rows = append(rows, linkRow{Tag: tag, UserID: userID})
	}
	return rows, nil
}

func rowsFromLinks(links []linkRow) []linkRow {
	rows := make([]linkRow, 0, len(links))
	seen := map[string]struct{}{}
	for _, link := range links {
		tag := normalizeTag(link.Tag)
		userID := strings.TrimSpace(link.UserID)
		if tag == "" || userID == "" {
			continue
		}
		key := tag + "\x00" + userID
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		rows = append(rows, linkRow{Tag: tag, UserID: userID})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].UserID == rows[j].UserID {
			return rows[i].Tag < rows[j].Tag
		}
		return rows[i].UserID < rows[j].UserID
	})
	lastUser := ""
	order := 0
	for i := range rows {
		if rows[i].UserID != lastUser {
			lastUser = rows[i].UserID
			order = 0
		}
		rows[i].OrderIndex = order
		order++
	}
	return rows
}

func flushPlayerLinkRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows []linkRow) (int64, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_player_links (
			tag text,
			user_id text,
			order_index int
		) ON COMMIT DROP
	`); err != nil {
		return 0, err
	}
	copyRows := make([][]any, 0, len(rows))
	for _, row := range rows {
		copyRows = append(copyRows, []any{row.Tag, row.UserID, row.OrderIndex})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_player_links"}, []string{"tag", "user_id", "order_index"}, pgx.CopyFromRows(copyRows)); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO public.player_links (tag, is_main, order_index, is_verified, source, added_at, user_id, verified_at, updated_at)
		SELECT tag, false, order_index, true, $1, now(), user_id, now(), now()
		FROM _ck_player_links
		WHERE tag <> '' AND user_id <> ''
		ON CONFLICT (tag) DO UPDATE SET
			user_id = EXCLUDED.user_id,
			order_index = EXCLUDED.order_index,
			source = EXCLUDED.source,
			is_verified = true,
			verified_at = COALESCE(public.player_links.verified_at, EXCLUDED.verified_at),
			updated_at = now()
	`, linkSource); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return int64(len(rows)), nil
}

func normalizeTag(value string) string {
	tag := strings.ToUpper(strings.TrimSpace(value))
	tag = strings.TrimPrefix(tag, "#")
	tag = strings.ReplaceAll(tag, " ", "")
	tag = strings.ReplaceAll(tag, "O", "0")
	if tag == "" {
		return ""
	}
	var b strings.Builder
	for _, r := range tag {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	if b.Len() == 0 {
		return ""
	}
	return "#" + b.String()
}

func chunkStrings(values []string, size int) [][]string {
	if size <= 0 || size > defaultLinkBatchSize {
		size = defaultLinkBatchSize
	}
	chunks := make([][]string, 0, (len(values)+size-1)/size)
	for start := 0; start < len(values); start += size {
		end := start + size
		if end > len(values) {
			end = len(values)
		}
		chunks = append(chunks, values[start:end])
	}
	return chunks
}

func splitCSV(raw string) []string {
	var out []string
	for _, item := range strings.Split(raw, ",") {
		item = strings.TrimSpace(item)
		if item != "" {
			out = append(out, item)
		}
	}
	return out
}

func parseSnowflake(raw string) (snowflake.ID, error) {
	value, err := strconv.ParseUint(strings.TrimSpace(raw), 10, 64)
	if err != nil {
		return 0, err
	}
	id := snowflake.ID(value)
	if id == 0 {
		return 0, errors.New("zero snowflake")
	}
	return id, nil
}

func completedGuildKey(guildID string) string {
	return "guild:" + guildID + ":complete"
}

func sleepBackoff(ctx context.Context, attempt int) error {
	delay := time.Duration(1<<attempt) * time.Second
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func envInt(env map[string]string, key string, fallback int) int {
	raw := strings.TrimSpace(env[key])
	if raw == "" {
		return fallback
	}
	out, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return out
}

func envBool(env map[string]string, key string) bool {
	raw := strings.TrimSpace(env[key])
	return raw == "1" || strings.EqualFold(raw, "true") || strings.EqualFold(raw, "yes")
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func ternary(ok bool, yes, no string) string {
	if ok {
		return yes
	}
	return no
}
