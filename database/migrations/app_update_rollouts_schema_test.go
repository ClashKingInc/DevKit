package main

import (
	"os"
	"strings"
	"testing"
)

func TestAppUpdateRolloutSchema(t *testing.T) {
	raw, err := os.ReadFile("../timescale/007_worker_api.sql")
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.SplitN(strings.ToLower(string(raw)), "-- +goose down", 2)
	if len(parts) != 2 {
		t.Fatal("app update rollout migration is missing a Goose down section")
	}
	up := parts[0]

	for _, required := range []string{
		"create table public.app_update_channels",
		"primary key (channel, platform, runtime_version)",
		"check (channel in ('beta', 'production'))",
		"check (platform in ('ios', 'android'))",
		"rollout_basis_points integer default 0 not null",
		"check (rollout_basis_points between 0 and 10000)",
		"rollout_ends_at > rollout_starts_at",
		"create table public.app_update_installations",
		"installation_hash bytea not null",
		"check (octet_length(installation_hash) = 32)",
		"current_update_id uuid",
		"primary key (installation_hash, channel, platform, runtime_version)",
		"create index idx_app_update_installations_adoption",
	} {
		if !strings.Contains(up, required) {
			t.Errorf("app update rollout migration missing %q", required)
		}
	}

	for _, forbidden := range []string{
		"app_native_releases",
		"app_update_artifacts",
		"app_update_audit",
		"created_by",
		"release_notes",
	} {
		if strings.Contains(up, forbidden) {
			t.Errorf("app update rollout migration unexpectedly contains %q", forbidden)
		}
	}
}

func TestAppUpdateRollbackSchema(t *testing.T) {
	raw, err := os.ReadFile("../timescale/007_worker_api.sql")
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.SplitN(strings.ToLower(string(raw)), "-- +goose down", 2)
	if len(parts) != 2 {
		t.Fatal("app update rollback migration is missing a Goose down section")
	}
	up := parts[0]
	for _, required := range []string{
		"alter table public.app_update_channels",
		"add column rollback_target_version text",
		"rollback_target_version <> active_version",
	} {
		if !strings.Contains(up, required) {
			t.Errorf("app update rollback migration missing %q", required)
		}
	}
}
