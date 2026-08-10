//go:build ignore

package main

import (
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestMongoCommandTime(t *testing.T) {
	want := time.Date(2026, time.July, 29, 14, 16, 32, 0, time.UTC)
	unix := want.Unix()

	for name, value := range map[string]any{
		"int32":         int32(unix),
		"int64":         unix,
		"float64":       float64(unix),
		"bson datetime": bson.NewDateTimeFromTime(want),
		"time":          want,
	} {
		t.Run(name, func(t *testing.T) {
			got, ok := mongoCommandTime(value)
			if !ok || !got.Equal(want) {
				t.Fatalf("mongoCommandTime(%T) = %v, %v; want %v, true", value, got, ok, want)
			}
		})
	}
}

func TestMongoCommandTimeRejectsMissingOrInvalidValues(t *testing.T) {
	for name, value := range map[string]any{
		"nil":      nil,
		"string":   "1785334592",
		"zero":     int64(0),
		"negative": int64(-1),
	} {
		t.Run(name, func(t *testing.T) {
			if got, ok := mongoCommandTime(value); ok {
				t.Fatalf("mongoCommandTime(%T) = %v, true; want rejected", value, got)
			}
		})
	}
}
