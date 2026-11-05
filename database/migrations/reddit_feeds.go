//go:build ignore

// Restore only verified legacy Reddit settings from an explicit source export.
// Preview is the default; no messages are sent by this tool.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

type discordStatusError struct{ code int }

func (e *discordStatusError) Error() string { return fmt.Sprintf("Discord returned HTTP %d", e.code) }

type object map[string]any

func str(m object, k string) string { s, _ := m[k].(string); return s }
func number(m object, k string) int { n, _ := m[k].(float64); return int(n) }

type discordReader struct {
	base, token string
	client      *http.Client
}

func (d discordReader) request(ctx context.Context, method, path string, body any) (json.RawMessage, error) {
	return d.requestAttempt(ctx, method, path, body, 0)
}
func (d discordReader) requestAttempt(ctx context.Context, method, path string, body any, attempt int) (json.RawMessage, error) {
	var payload io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		payload = bytes.NewReader(b)
	}
	req, e := http.NewRequestWithContext(ctx, method, d.base+path, payload)
	if e != nil {
		return nil, fmt.Errorf("invalid Discord request")
	}
	req.Header.Set("Authorization", "Bot "+d.token)
	req.Header.Set("Content-Type", "application/json")
	res, e := d.client.Do(req)
	if e != nil {
		if method == "GET" && attempt < 3 {
			if e := waitReadRetry(ctx, attempt); e != nil {
				return nil, e
			}
			return d.requestAttempt(ctx, method, path, body, attempt+1)
		}
		return nil, fmt.Errorf("Discord request failed")
	}
	defer res.Body.Close()
	// GET has no provider side effect. A transport error or temporary server
	// failure can be retried; an ambiguous webhook-creation POST never can.
	if method == "GET" && res.StatusCode >= 500 && attempt < 3 {
		res.Body.Close()
		if e := waitReadRetry(ctx, attempt); e != nil {
			return nil, e
		}
		return d.requestAttempt(ctx, method, path, body, attempt+1)
	}
	// A 429 explicitly rejects the request; retrying it cannot duplicate a
	// created webhook. Ambiguous POST transport/5xx failures are not retried.
	if res.StatusCode == 429 && attempt < 3 {
		var limit struct {
			RetryAfter float64 `json:"retry_after"`
		}
		if json.NewDecoder(io.LimitReader(res.Body, 4096)).Decode(&limit) != nil || limit.RetryAfter <= 0 || limit.RetryAfter > 60 {
			return nil, &discordStatusError{code: 429}
		}
		res.Body.Close()
		timer := time.NewTimer(time.Duration(limit.RetryAfter * float64(time.Second)))
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
		}
		return d.requestAttempt(ctx, method, path, body, attempt+1)
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, &discordStatusError{code: res.StatusCode}
	}
	b, e := io.ReadAll(io.LimitReader(res.Body, 4*1024*1024+1))
	if e != nil || len(b) > 4*1024*1024 {
		return nil, fmt.Errorf("invalid Discord response")
	}
	return b, nil
}
func waitReadRetry(ctx context.Context, attempt int) error {
	timer := time.NewTimer(time.Duration(1<<attempt) * time.Second)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
func (d discordReader) get(ctx context.Context, path string) (object, error) {
	b, e := d.request(ctx, "GET", path, nil)
	if e != nil {
		return nil, e
	}
	var v object
	e = json.Unmarshal(b, &v)
	return v, e
}
func owned(h object, app, server, channel string) bool {
	u, _ := h["user"].(map[string]any)
	return number(h, "type") == 1 && str(h, "guild_id") == server && str(h, "channel_id") == channel && str(h, "id") != "" && (str(h, "application_id") == app || str(u, "id") == app)
}

type redditSource struct {
	ServerID      string   `json:"server_id"`
	DestinationID string   `json:"destination_id"`
	RoleID        string   `json:"role_id"`
	Accounts      []string `json:"accounts"`
}

func main() { migrateutil.Main("reddit_feeds", runRedditFeeds) }
func runRedditFeeds(ctx context.Context, cfg migrateutil.Config) error {
	apply := os.Getenv("REDDIT_FEEDS_APPLY") == "1"
	source, e := os.ReadFile(os.Getenv("REDDIT_FEEDS_SOURCE"))
	if e != nil {
		return fmt.Errorf("explicit Reddit source export required")
	}
	var sources []redditSource
	if json.Unmarshal(source, &sources) != nil {
		return fmt.Errorf("invalid source export")
	}
	ids := map[string]bool{}
	decimal := regexp.MustCompile(`^[0-9]{15,20}$`)
	username := regexp.MustCompile(`^[A-Za-z0-9_-]{1,30}$`)
	for _, r := range sources {
		if !decimal.MatchString(r.ServerID) || !decimal.MatchString(r.DestinationID) || r.RoleID != "" && !decimal.MatchString(r.RoleID) || ids[r.ServerID] {
			return fmt.Errorf("invalid or duplicate source identity")
		}
		ids[r.ServerID] = true
		for _, a := range r.Accounts {
			// Preserve malformed legacy account values instead of inventing a
			// username or discarding an otherwise valid feed. Exact author
			// matching leaves these inert until the owner corrects them.
			if !username.MatchString(a) {
				fmt.Printf("server %s: malformed legacy account retained for review\n", r.ServerID)
			}
		}
	}
	sort.Slice(sources, func(i, j int) bool { return sources[i].ServerID < sources[j].ServerID })
	base := strings.TrimSuffix(os.Getenv("REDDIT_DISCORD_API_URL"), "/")
	if base == "" {
		base = "https://discord.com/api/v10"
	} else {
		u, e := url.Parse(base)
		if e != nil || (u.Hostname() != "localhost" && u.Hostname() != "127.0.0.1") {
			return fmt.Errorf("custom provider must be loopback")
		}
	}
	token := cfg.Env["BOT_TOKEN"]
	if token == "" {
		return fmt.Errorf("BOT_TOKEN required")
	}
	d := discordReader{base: base, token: token, client: &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	me, e := d.get(ctx, "/users/@me")
	if e != nil {
		return e
	}
	app := str(me, "id")
	if expected := os.Getenv("REDDIT_EXPECTED_APPLICATION_ID"); expected == "" || app != expected {
		return fmt.Errorf("explicit expected application does not match")
	}
	pool, e := migrateutil.TimescalePool(ctx, cfg)
	if e != nil {
		return e
	}
	defer pool.Close()
	scanned, updated, unavailable, conflict, created := 0, 0, 0, 0, 0
	defer func() {
		fmt.Printf("reddit repair: apply=%t scanned=%d total=%d updated=%d unavailable=%d conflicts=%d created=%d\n", apply, scanned, len(sources), updated, unavailable, conflict, created)
	}()
	for _, r := range sources {
		e = func() error {
			tx, e := pool.Begin(ctx)
			if e != nil {
				return e
			}
			defer tx.Rollback(ctx)
			var server string
			if e = tx.QueryRow(ctx, `SELECT id FROM servers WHERE id=$1 FOR UPDATE`, r.ServerID).Scan(&server); errors.Is(e, pgx.ErrNoRows) {
				unavailable++
				return nil
			} else if e != nil {
				return e
			}
			channel, e := d.get(ctx, "/channels/"+r.DestinationID)
			if e != nil {
				return e
			}
			if str(channel, "guild_id") != r.ServerID {
				return fmt.Errorf("source destination outside server")
			}
			parent, thread := r.DestinationID, ""
			typ := number(channel, "type")
			if typ == 10 || typ == 11 || typ == 12 {
				thread = parent
				parent = str(channel, "parent_id")
				channel, e = d.get(ctx, "/channels/"+parent)
				if e != nil {
					return e
				}
				typ = number(channel, "type")
			}
			if str(channel, "guild_id") != r.ServerID || (typ != 0 && typ != 5 && typ != 15) || (typ == 15 && thread == "") {
				return fmt.Errorf("unsupported source destination")
			}
			var existingHook, existingThread, existingRole string
			var existingAccounts []string
			e = tx.QueryRow(ctx, `SELECT webhook_id,COALESCE(thread_id,''),COALESCE(reddit_role_id,''),reddit_accounts FROM server_logs WHERE server_id=$1 AND clan_tag IS NULL AND type='reddit_feed' FOR UPDATE`, server).Scan(&existingHook, &existingThread, &existingRole, &existingAccounts)
			exists := e == nil
			if e != nil && !errors.Is(e, pgx.ErrNoRows) {
				return e
			}
			if exists {
				hook, e := d.get(ctx, "/webhooks/"+existingHook)
				if e != nil {
					return e
				}
				// Never overwrite a newer SQL destination or nonempty changed options.
				if !owned(hook, app, server, parent) || existingThread != thread || (existingRole != "" && existingRole != r.RoleID) || (len(existingAccounts) > 0 && !equalAccounts(existingAccounts, r.Accounts)) {
					conflict++
					fmt.Printf("server %s: newer SQL settings retained\n", server)
					return nil
				}
			}
			hookID := existingHook
			if hookID == "" {
				raw, e := d.request(ctx, "GET", "/channels/"+parent+"/webhooks", nil)
				if e != nil {
					return e
				}
				var hooks []object
				if json.Unmarshal(raw, &hooks) != nil || string(raw) == "null" {
					return fmt.Errorf("invalid webhook list")
				}
				for _, hook := range hooks {
					if owned(hook, app, server, parent) {
						hookID = str(hook, "id")
						break
					}
				}
				if hookID == "" && apply {
					raw, e = d.request(ctx, "POST", "/channels/"+parent+"/webhooks", object{"name": "ClashKing"})
					if e != nil {
						return e
					}
					var hook object
					if json.Unmarshal(raw, &hook) != nil || !owned(hook, app, server, parent) {
						return fmt.Errorf("created webhook ownership mismatch")
					}
					hookID = str(hook, "id")
					created++
				}
			}
			if !apply {
				fmt.Printf("server %s: verified destination role=%t accounts=%d existing=%t needs_webhook=%t\n", server, r.RoleID != "", len(r.Accounts), exists, hookID == "")
				return nil
			}
			if r.Accounts == nil {
				r.Accounts = []string{}
			}
			_, e = tx.Exec(ctx, `INSERT INTO server_logs(server_id,clan_tag,type,webhook_id,thread_id,reddit_role_id,reddit_accounts)
    VALUES($1,NULL,'reddit_feed',$2,NULLIF($3,''),NULLIF($4,''),$5)
    ON CONFLICT(server_id,clan_tag,type) DO UPDATE SET reddit_role_id=EXCLUDED.reddit_role_id,reddit_accounts=EXCLUDED.reddit_accounts,updated_at=now()`, server, hookID, thread, r.RoleID, r.Accounts)
			if e != nil {
				return e
			}
			if e = tx.Commit(ctx); e != nil {
				return e
			}
			updated++
			fmt.Printf("server %s: preserved Reddit configuration\n", server)
			return nil
		}()
		if e != nil {
			var status *discordStatusError
			if errors.As(e, &status) && (status.code == 403 || status.code == 404) {
				unavailable++
				fmt.Printf("server %s: unavailable HTTP %d; unchanged\n", r.ServerID, status.code)
			} else {
				return fmt.Errorf("server %s: %w", r.ServerID, e)
			}
		}
		scanned++
	}
	return nil
}
func equalAccounts(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
