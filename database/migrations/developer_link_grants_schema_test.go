package main

import (
	"os"
	"strings"
	"testing"
)

func TestDeveloperLinkGrantSchema(t *testing.T) {
	raw, err := os.ReadFile("../timescale/004_developer_link_grants.sql")
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.SplitN(strings.ToLower(string(raw)), "-- +goose down", 2)
	if len(parts) != 2 {
		t.Fatal("developer link grant migration is missing a Goose down section")
	}
	up := parts[0]

	for _, required := range []string{
		"create table public.developer_applications",
		"application_id uuid default uuidv7() not null",
		"token_hash bytea not null",
		"check (octet_length(token_hash) = 32)",
		"unique (token_hash)",
		"token_prefix text not null",
		"redirect_uri text",
		"token_last_used_at timestamp with time zone",
		"created_by_admin_id uuid not null",
		"references public.admin_users(id) on delete restrict",
		"create table public.developer_link_grants",
		"application_id uuid not null",
		"user_id text not null",
		"check (access_mode in ('selected', 'all_current_and_future'))",
		"references public.auth_users(user_id) on delete cascade",
		"create unique index uq_developer_link_grants_current_application_user",
		"where revoked_at is null",
		"create table public.developer_link_grant_accounts",
		"primary key (grant_id, player_tag)",
		"references public.player_links(tag) on delete cascade",
	} {
		if !strings.Contains(up, required) {
			t.Errorf("developer link grant migration missing %q", required)
		}
	}

	for _, forbidden := range []string{
		"token_ciphertext",
		"token_plaintext",
		"permission",
		"scope",
		"write",
	} {
		if strings.Contains(up, forbidden) {
			t.Errorf("developer link grant migration unexpectedly contains %q", forbidden)
		}
	}
}
