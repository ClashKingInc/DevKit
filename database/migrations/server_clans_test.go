//go:build ignore

package main

import (
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestServerClanAddedAtUsesMongoObjectIDTimestamp(t *testing.T) {
	want := time.Date(2024, time.January, 15, 12, 30, 45, 0, time.UTC)
	objectID := bson.NewObjectIDFromTimestamp(want)

	got, err := serverClanAddedAt(bson.M{"_id": objectID})
	if err != nil {
		t.Fatalf("serverClanAddedAt: %v", err)
	}
	if !got.Equal(want) {
		t.Fatalf("serverClanAddedAt = %v, want %v", got, want)
	}
}

func TestServerClanAddedAtRejectsNonObjectID(t *testing.T) {
	if _, err := serverClanAddedAt(bson.M{"_id": "legacy-id"}); err == nil {
		t.Fatal("serverClanAddedAt accepted a non-ObjectID")
	}
}
