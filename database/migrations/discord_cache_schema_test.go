package main

import (
	"os"
	"strings"
	"testing"
)

func TestDiscordCacheSchema(t *testing.T) {
	raw, err := os.ReadFile("../timescale/008_discord_cache.sql")
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.SplitN(strings.ToLower(string(raw)), "-- +goose down", 2)
	if len(parts) != 2 {
		t.Fatal("discord cache migration is missing a Goose down section")
	}
	up := parts[0]

	for _, required := range []string{
		"create schema if not exists discord_cache",
		"create table discord_cache.guilds",
		"create table discord_cache.channels",
		"create table discord_cache.users",
		"create table discord_cache.members",
		"primary key (guild_id, user_id)",
		"create table discord_cache.roles",
		"primary key (guild_id, id)",
		"create table discord_cache.application_emojis",
		"primary key (application_id, logical_name)",
		"source_key text not null",
		"source_updated_at timestamp with time zone not null",
		"create table discord_cache.delivery_receipts",
		"primary key (stream_id, destination_id)",
	} {
		if !strings.Contains(up, required) {
			t.Errorf("discord cache migration missing %q", required)
		}
	}

	for _, forbidden := range []string{"messages", "presences", "voice_states", "gateway_sessions"} {
		if strings.Contains(up, forbidden) {
			t.Errorf("discord cache migration unexpectedly contains %q", forbidden)
		}
	}
}
