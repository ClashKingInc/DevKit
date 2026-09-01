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

func TestLegacyAdminCleanupSchema(t *testing.T) {
	raw, err := os.ReadFile("../timescale/005_remove_legacy_admin_auth.sql")
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.SplitN(strings.ToLower(string(raw)), "-- +goose down", 2)
	if len(parts) != 2 {
		t.Fatal("legacy admin cleanup migration is missing a Goose down section")
	}
	up := parts[0]

	for _, required := range []string{
		"drop constraint if exists developer_applications_created_by_admin_id_fkey",
		"drop index if exists public.idx_developer_applications_created_by_admin_id",
		"drop column if exists created_by_admin_id",
		"drop table if exists public.admin_sessions",
		"drop table if exists public.admin_users",
	} {
		if !strings.Contains(up, required) {
			t.Errorf("legacy admin cleanup migration missing %q", required)
		}
	}
}

func TestSimplifiedDeveloperApplicationSchema(t *testing.T) {
	raw, err := os.ReadFile("../timescale/006_simplify_developer_applications.sql")
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.SplitN(strings.ToLower(string(raw)), "-- +goose down", 2)
	if len(parts) != 2 {
		t.Fatal("simplified developer application migration is missing a Goose down section")
	}
	up := parts[0]
	down := parts[1]

	for _, required := range []string{
		"set developer_name = application_name",
		"where developer_name is null",
		"alter column developer_name set not null",
		"add column api_request_count bigint default 0 not null",
		"add column links_lookup_count bigint default 0 not null",
		"check (api_request_count >= 0)",
		"check (links_lookup_count >= 0)",
		"drop table public.developer_link_grant_accounts",
		"drop table public.developer_link_grants",
		"drop column application_name",
		"drop column contact_email",
		"drop column redirect_uri",
	} {
		if !strings.Contains(up, required) {
			t.Errorf("simplified developer application migration missing %q", required)
		}
	}

	backfillPosition := strings.Index(up, "set developer_name = application_name")
	requirePosition := strings.Index(up, "alter column developer_name set not null")
	dropNamePosition := strings.Index(up, "drop column application_name")
	if backfillPosition == -1 || requirePosition == -1 || dropNamePosition == -1 ||
		!(backfillPosition < requirePosition && requirePosition < dropNamePosition) {
		t.Error("developer_name must be backfilled before it becomes required and application_name is dropped")
	}

	for _, preserved := range []string{
		"application_id",
		"token_hash",
		"token_prefix",
		"token_last_used_at",
		"created_at",
		"updated_at",
		"revoked_at",
	} {
		if strings.Contains(up, "drop column "+preserved) {
			t.Errorf("simplified developer application migration drops preserved column %q", preserved)
		}
	}

	if !strings.Contains(down, "migration 006 is irreversible") {
		t.Error("simplified developer application migration must reject lossy rollback")
	}
}
