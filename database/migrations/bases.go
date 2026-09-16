//go:build ignore

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.mongodb.org/mongo-driver/v2/bson"
)

var baseMention = regexp.MustCompile(`^<@!?([0-9]+)>(?:\s+\[.*\])?$`)
var baseDecimal = regexp.MustCompile(`^[1-9][0-9]*$`)
var baseLocalePath = regexp.MustCompile(`^/(?:[a-z]{2}(?:-[A-Za-z]{2})?)?/?$`)

type baseImportRow struct {
	MessageID string
	Link      string
	CreatedAt time.Time
	Downloads map[string]string
}

func main() { migrateutil.Main("bases", runBases) }

func runBases(ctx context.Context, cfg migrateutil.Config) error {
	dryRun := true
	if raw := strings.TrimSpace(cfg.Env["BASES_DRY_RUN"]); raw != "" {
		var err error
		dryRun, err = strconv.ParseBool(raw)
		if err != nil {
			return fmt.Errorf("BASES_DRY_RUN must be true or false")
		}
	}
	filter := bson.D{}
	if id := strings.TrimSpace(cfg.Env["BASES_MESSAGE_ID"]); id != "" {
		n, err := strconv.ParseInt(id, 10, 64)
		if err != nil || n <= 0 {
			return fmt.Errorf("invalid BASES_MESSAGE_ID")
		}
		filter = bson.D{{Key: "message_id", Value: bson.M{"$in": bson.A{id, n}}}}
	}
	client, err := migrateutil.StaticClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer client.Disconnect(ctx)
	var pool *pgxpool.Pool
	if !dryRun {
		pool, err = migrateutil.TimescalePool(ctx, cfg)
		if err != nil {
			return err
		}
		defer pool.Close()
		// Fail before importing if the download-storage migration is absent.
		if _, err = pool.Exec(ctx, `SELECT id,message_id,base_link,downloads FROM public.bases LIMIT 0`); err != nil {
			return fmt.Errorf("bases requires Timescale migration 019: %w", err)
		}
	}
	var valid, skipped, invalidMentions, written int64
	batch := make([]baseImportRow, 0, min(cfg.BatchSize, 1000))
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		for _, row := range batch {
			if err := writeBaseRow(ctx, tx, row); err != nil {
				return err
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		written += int64(len(batch))
		batch = batch[:0]
		return nil
	}
	fmt.Printf("bases: source=STATIC_MONGODB/usafam.bases dry_run=%t message_id=%q\n", dryRun, cfg.Env["BASES_MESSAGE_ID"])
	seen, err := migrateutil.StreamFilteredProjected(ctx, cfg, "bases", client.Database("usafam").Collection("bases"), filter,
		bson.M{"_id": 1, "message_id": 1, "link": 1, "base_link": 1, "created_at": 1, "downloaders": 1},
		func(doc bson.M) (bool, error) {
			row, rejected, err := parseBaseDocument(doc)
			if err != nil {
				skipped++
				fmt.Printf("bases: skipped message_id=%q reason=%s\n", migrateutil.String(doc["message_id"]), err)
				return false, nil
			}
			valid++
			invalidMentions += int64(rejected)
			if rejected > 0 {
				fmt.Printf("bases: message_id=%s ignored_downloader_entries=%d\n", row.MessageID, rejected)
			}
			if dryRun {
				return false, nil
			}
			batch = append(batch, row)
			return len(batch) >= min(cfg.BatchSize, 1000), nil
		}, flush)
	fmt.Printf("bases: scanned=%d valid=%d skipped=%d invalid_downloader_entries=%d committed_rows=%d dry_run=%t\n", seen, valid, skipped, invalidMentions, written, dryRun)
	return err
}

func parseBaseDocument(doc bson.M) (baseImportRow, int, error) {
	row := baseImportRow{Downloads: map[string]string{}}
	// BSON int64 or decimal strings preserve snowflakes; floats may already be rounded.
	switch id := doc["message_id"].(type) {
	case string:
		row.MessageID = strings.TrimSpace(id)
	case int64:
		row.MessageID = strconv.FormatInt(id, 10)
	case int32:
		row.MessageID = strconv.FormatInt(int64(id), 10)
	case int:
		row.MessageID = strconv.Itoa(id)
	default:
		return row, 0, fmt.Errorf("message_id must be an integer or decimal string")
	}
	id, err := strconv.ParseUint(row.MessageID, 10, 64)
	if err != nil || !baseDecimal.MatchString(row.MessageID) {
		return row, 0, fmt.Errorf("invalid message_id")
	}
	raw, _ := doc["link"].(string)
	if raw == "" {
		raw, _ = doc["base_link"].(string)
	}
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "https" || u.Host != "link.clashofclans.com" || u.User != nil || u.Fragment != "" {
		return row, 0, fmt.Errorf("invalid layout URL")
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil || len(q["action"]) != 1 || q.Get("action") != "OpenLayout" || len(q["id"]) != 1 || strings.TrimSpace(q.Get("id")) == "" || len(q) != 2 {
		return row, 0, fmt.Errorf("invalid OpenLayout query")
	}
	// Old links may use a game locale other than /en; normalize for the Worker.
	if !baseLocalePath.MatchString(u.Path) {
		return row, 0, fmt.Errorf("invalid layout path")
	}
	row.Link = "https://link.clashofclans.com/en?action=OpenLayout&id=" + strings.ReplaceAll(url.QueryEscape(q.Get("id")), "+", "%20")
	if rawDate, ok := doc["created_at"]; ok {
		var valid bool
		row.CreatedAt, valid = migrateutil.Time(rawDate)
		if !valid {
			return row, 0, fmt.Errorf("invalid created_at")
		}
	} else {
		row.CreatedAt = time.UnixMilli(int64(id>>22) + 1420070400000).UTC()
	}
	var entries []any
	switch values := doc["downloaders"].(type) {
	case nil:
	case bson.A:
		entries = []any(values)
	case []any:
		entries = values
	default:
		return row, 0, fmt.Errorf("downloaders must be an array")
	}
	rejected := 0
	for _, entry := range entries {
		text, ok := entry.(string)
		match := baseMention.FindStringSubmatch(strings.TrimSpace(text))
		if !ok || match == nil || !baseDecimal.MatchString(match[1]) {
			rejected++
			continue
		}
		if _, err := strconv.ParseUint(match[1], 10, 64); err != nil {
			rejected++
			continue
		}
		// Legacy data has no per-click timestamp; use base creation time as a documented approximation.
		row.Downloads[match[1]] = row.CreatedAt.Truncate(time.Microsecond).Format(time.RFC3339Nano)
	}
	return row, rejected, nil
}

func writeBaseRow(ctx context.Context, tx pgx.Tx, row baseImportRow) error {
	if _, err := tx.Exec(ctx, `INSERT INTO public.bases(message_id,base_link,created_at)
		VALUES ($1,$2,$3) ON CONFLICT(message_id) DO NOTHING`, row.MessageID, row.Link, row.CreatedAt); err != nil {
		return err
	}
	var id int64
	var existing string
	if err := tx.QueryRow(ctx, `SELECT id,base_link FROM public.bases WHERE message_id=$1 FOR UPDATE`, row.MessageID).Scan(&id, &existing); err != nil {
		return err
	}
	// Abort conflicting identities instead of overwriting a live base or attaching its downloads elsewhere.
	if existing != row.Link {
		return fmt.Errorf("base message %s already has a different layout link", row.MessageID)
	}
	downloads, err := json.Marshal(row.Downloads)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE public.bases SET downloads=$2::jsonb || downloads WHERE id=$1`, id, string(downloads))
	return err
}
