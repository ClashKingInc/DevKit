//go:build ignore

// Backfill reminder destinations using existing bot-owned incoming webhooks.
// Default is read-only. Set REMINDER_WEBHOOKS_APPLY=1 only after reviewing dry-run.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"io"
	"net/http"
	"net/url"
	"os"
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
func main() { migrateutil.Main("reminder_webhooks", run) }
func run(ctx context.Context, cfg migrateutil.Config) error {
	apply := os.Getenv("REMINDER_WEBHOOKS_APPLY") == "1"
	base := strings.TrimSuffix(os.Getenv("REMINDER_DISCORD_API_URL"), "/")
	if base == "" {
		base = "https://discord.com/api/v10"
	} else {
		u, e := url.Parse(base)
		if e != nil || (u.Hostname() != "localhost" && u.Hostname() != "127.0.0.1" && u.Hostname() != "::1") {
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
	if app == "" {
		return fmt.Errorf("Discord user has no ID")
	}
	pool, e := migrateutil.TimescalePool(ctx, cfg)
	if e != nil {
		return e
	}
	defer pool.Close()
	rows, e := pool.Query(ctx, `SELECT id::text FROM reminders ORDER BY server_id,channel_id,id`)
	if e != nil {
		return e
	}
	var ids []string
	for rows.Next() {
		var id string
		if e = rows.Scan(&id); e != nil {
			rows.Close()
			return e
		}
		ids = append(ids, id)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	// Resume inclusively at the failed reminder in the same stable SQL order.
	// Resolve the anchor from the current real IDs; an unknown anchor must not
	// silently turn a partial repair into a successful empty run.
	if anchor := strings.TrimSpace(os.Getenv("REMINDER_WEBHOOKS_START_AT")); anchor != "" {
		found := -1
		for i, id := range ids {
			if id == anchor {
				found = i
				break
			}
		}
		if found < 0 {
			return fmt.Errorf("resume reminder does not exist")
		}
		ids = ids[found:]
	}
	reused, created, updated, unavailable, scanned := 0, 0, 0, 0, 0
	defer func() {
		fmt.Printf("reminder webhook migration: apply=%t scanned=%d total=%d reused=%d created=%d updated=%d unavailable=%d\n", apply, scanned, len(ids), reused, created, updated, unavailable)
	}()
	process := func(id string) error {
		tx, e := pool.Begin(ctx)
		if e != nil {
			return e
		}
		fail := func(e error) error { _ = tx.Rollback(ctx); return fmt.Errorf("reminder %s: %w", id, e) }
		var server, channel, thread string
		e = tx.QueryRow(ctx, `SELECT server_id,COALESCE(channel_id,''),COALESCE(thread_id,'') FROM reminders WHERE id=$1::uuid`, id).Scan(&server, &channel, &thread)
		if e != nil {
			return fail(e)
		}
		// Match API's server lock before inspecting/creating shared channel hooks.
		var locked string
		e = tx.QueryRow(ctx, `SELECT id FROM servers WHERE id=$1 FOR UPDATE`, server).Scan(&locked)
		if e != nil {
			return fail(e)
		}
		e = tx.QueryRow(ctx, `SELECT COALESCE(channel_id,''),COALESCE(thread_id,'') FROM reminders WHERE id=$1::uuid AND server_id=$2 FOR UPDATE`, id, server).Scan(&channel, &thread)
		if e != nil {
			return fail(e)
		}
		c, e := d.get(ctx, "/channels/"+channel)
		if e != nil {
			return fail(e)
		}
		if str(c, "guild_id") != server {
			return fail(fmt.Errorf("destination is outside server"))
		}
		typ := number(c, "type")
		if typ == 10 || typ == 11 || typ == 12 {
			if thread != "" && thread != channel {
				return fail(fmt.Errorf("conflicting thread destinations"))
			}
			thread = channel
			channel = str(c, "parent_id")
			c, e = d.get(ctx, "/channels/"+channel)
			if e != nil {
				return fail(e)
			}
			typ = number(c, "type")
		}
		if str(c, "guild_id") != server || (typ != 0 && typ != 5 && typ != 15) || (typ == 15 && thread == "") {
			return fail(fmt.Errorf("unsupported reminder parent channel"))
		}
		if thread != "" {
			t, e := d.get(ctx, "/channels/"+thread)
			if e != nil {
				return fail(e)
			}
			tt := number(t, "type")
			if str(t, "guild_id") != server || str(t, "parent_id") != channel || (tt != 10 && tt != 11 && tt != 12) {
				return fail(fmt.Errorf("thread is outside destination"))
			}
		}
		raw, e := d.request(ctx, "GET", "/channels/"+channel+"/webhooks", nil)
		if e != nil {
			return fail(e)
		}
		var hooks []object
		if e = json.Unmarshal(raw, &hooks); e != nil || string(raw) == "null" {
			return fail(fmt.Errorf("invalid webhook list"))
		}
		hookID := ""
		for _, h := range hooks {
			if owned(h, app, server, channel) {
				hookID = str(h, "id")
				break
			}
		}
		if hookID != "" {
			reused++
		} else if apply {
			raw, e = d.request(ctx, "POST", "/channels/"+channel+"/webhooks", object{"name": "ClashKing"})
			if e != nil {
				return fail(e)
			}
			var h object
			if json.Unmarshal(raw, &h) != nil || !owned(h, app, server, channel) {
				return fail(fmt.Errorf("created webhook failed ownership check"))
			}
			hookID = str(h, "id")
			created++
		} else {
			fmt.Printf("reminder %s: needs a shared channel webhook\n", id)
		}
		if apply {
			_, e = tx.Exec(ctx, `UPDATE reminders SET webhook_id=$2,webhook_token='',channel_id=$3,thread_id=NULLIF($4,''),updated_at=now() WHERE id=$1::uuid`, id, hookID, channel, thread)
			if e != nil {
				return fail(e)
			}
			if e = tx.Commit(ctx); e != nil {
				return e
			}
			updated++
		} else {
			_ = tx.Rollback(ctx)
		}
		return nil
	}
	for _, id := range ids {
		if err := process(id); err != nil {
			var status *discordStatusError
			// Old configurations can reference removed channels or servers the
			// bot has left. Retain those rows untouched and keep repairing the
			// reachable destinations; never delete configuration or fall back
			// to bot messages because a webhook cannot be resolved.
			if errors.As(err, &status) && (status.code == 403 || status.code == 404) {
				unavailable++
				scanned++
				fmt.Printf("reminder %s: unavailable destination (HTTP %d); unchanged\n", id, status.code)
				continue
			}
			return err
		}
		scanned++
	}
	return nil
}
