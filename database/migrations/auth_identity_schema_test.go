package main

import (
	"os"
	"strings"
	"testing"
)

func TestAuthUsersBaselineUsesProviderAndCanonicalUserID(t *testing.T) {
	raw, err := os.ReadFile("../timescale/002_initial_settings.sql")
	if err != nil {
		t.Fatal(err)
	}
	table := baselineTableDDL(t, string(raw), "auth_users")
	for _, required := range []string{
		"user_id text NOT NULL",
		"provider text NOT NULL",
		"auth_users_provider_check",
		"provider = 'discord'",
		"provider = 'email'",
	} {
		if !strings.Contains(table, required) {
			t.Errorf("auth_users baseline missing %q", required)
		}
	}
	if strings.Contains(table, "discord_user_id") {
		t.Fatal("auth_users baseline retains redundant discord_user_id")
	}
}
