//go:build ignore

package main

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func baseFixture() bson.M {
	return bson.M{"message_id": int64(1396633326726549545), "link": "https://link.clashofclans.com/en?action=OpenLayout&id=TH17%3Atest",
		"downloaders": bson.A{"<@123> [name]", "<@!456> [old name]", "<@123>", "123", "prefix <@789>"}}
}

func TestParseMongoBase(t *testing.T) {
	row, rejected, err := parseBaseDocument(baseFixture())
	if err != nil {
		t.Fatal(err)
	}
	if row.MessageID != "1396633326726549545" || len(row.Downloads) != 2 || rejected != 2 {
		t.Fatalf("unexpected row: %+v rejected=%d", row, rejected)
	}
	if row.Downloads["123"] == "" || row.Downloads["456"] == "" {
		t.Fatal("lost legacy mention identities")
	}
	want := time.UnixMilli((1396633326726549545 >> 22) + 1420070400000).UTC()
	if !row.CreatedAt.Equal(want) {
		t.Fatalf("timestamp=%s want=%s", row.CreatedAt, want)
	}
}

func TestBaseInvalidInputs(t *testing.T) {
	for name, change := range map[string]bson.M{
		"rounded snowflake": {"message_id": float64(1396633326726549545)},
		"invalid id":        {"message_id": "bad"},
		"wrong host":        {"link": "https://evil.test/en?action=OpenLayout&id=x"},
		"wrong action":      {"link": "https://link.clashofclans.com/en?action=CopyArmy&id=x"},
		"empty id":          {"link": "https://link.clashofclans.com/en?action=OpenLayout&id="},
		"duplicate id":      {"link": "https://link.clashofclans.com/en?action=OpenLayout&id=x&id=y"},
		"bad date":          {"created_at": "not-a-date"},
		"bad downloaders":   {"downloaders": "unexpected"},
	} {
		t.Run(name, func(t *testing.T) {
			doc := baseFixture()
			for k, v := range change {
				doc[k] = v
			}
			if _, _, err := parseBaseDocument(doc); err == nil {
				t.Fatal("accepted invalid input")
			}
		})
	}
}

func TestBaseLocaleAndExplicitDate(t *testing.T) {
	doc := baseFixture()
	doc["message_id"] = "1396633326726549545"
	doc["link"] = "https://link.clashofclans.com/de?action=OpenLayout&id=TH17:test"
	doc["created_at"] = bson.NewDateTimeFromTime(time.Date(2025, 7, 20, 1, 2, 3, 0, time.UTC))
	row, _, err := parseBaseDocument(doc)
	if err != nil {
		t.Fatal(err)
	}
	if row.Link != "https://link.clashofclans.com/en?action=OpenLayout&id=TH17%3Atest" || row.Downloads["123"] != "2025-07-20T01:02:03Z" {
		t.Fatalf("unexpected conversion: %+v", row)
	}
}

func TestBaseImportPostgres(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" {
		t.Skip("requires disposable Timescale fixture")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	row, _, err := parseBaseDocument(baseFixture())
	if err != nil {
		t.Fatal(err)
	}
	if err := writeBaseRow(ctx, tx, row); err != nil {
		t.Fatal(err)
	}
	var id int64
	var original string
	var unbound bool
	if err := tx.QueryRow(ctx, `SELECT id,downloads->>'123',server_id IS NULL AND channel_id IS NULL AND description='' FROM bases WHERE message_id=$1`, row.MessageID).Scan(&id, &original, &unbound); err != nil {
		t.Fatal(err)
	}
	if !unbound {
		t.Fatal("import finalized the legacy message")
	}
	if _, err := tx.Exec(ctx, `UPDATE bases SET server_id='1',channel_id='2',description='converted' WHERE id=$1`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO base_votes(base_id,user_id,vote) VALUES($1,'123',1)`, id); err != nil {
		t.Fatal(err)
	}
	row.Downloads["123"] = "2026-09-16T00:00:00Z"
	row.Downloads["789"] = "2026-09-16T00:00:00Z"
	if err := writeBaseRow(ctx, tx, row); err != nil {
		t.Fatal(err)
	}
	var preserved bool
	if err := tx.QueryRow(ctx, `SELECT id=$2 AND downloads->>'123'=$3 AND (SELECT count(*) FROM jsonb_object_keys(downloads))=3
		AND server_id='1' AND channel_id='2' AND description='converted'
		AND EXISTS(SELECT 1 FROM base_votes WHERE base_id=$2 AND vote=1)
		FROM bases WHERE message_id=$1`, row.MessageID, id, original).Scan(&preserved); err != nil {
		t.Fatal(err)
	}
	if !preserved {
		t.Fatal("rerun changed existing identity, metadata or downloads")
	}
	row.Link = "https://link.clashofclans.com/en?action=OpenLayout&id=other"
	if err := writeBaseRow(ctx, tx, row); err == nil {
		t.Fatal("accepted conflicting base link")
	}
}
