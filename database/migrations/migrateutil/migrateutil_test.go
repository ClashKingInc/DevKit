package migrateutil

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestMigrationEnvPathPrefersRepositoryRoot(t *testing.T) {
	repositoryRoot := t.TempDir()
	databaseRoot := filepath.Join(repositoryRoot, "database")
	if err := os.MkdirAll(databaseRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repositoryRoot, ".env"), []byte("ROOT=true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(databaseRoot, ".env"), []byte("DATABASE=true\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if got, want := migrationEnvPath(databaseRoot), filepath.Join(repositoryRoot, ".env"); got != want {
		t.Fatalf("migrationEnvPath() = %q, want %q", got, want)
	}
}

func TestMigrationEnvPathFallsBackToDatabaseRoot(t *testing.T) {
	repositoryRoot := t.TempDir()
	databaseRoot := filepath.Join(repositoryRoot, "database")
	if err := os.MkdirAll(databaseRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(databaseRoot, ".env"), []byte("DATABASE=true\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if got, want := migrationEnvPath(databaseRoot), filepath.Join(databaseRoot, ".env"); got != want {
		t.Fatalf("migrationEnvPath() = %q, want %q", got, want)
	}
}

func TestStableCWLID(t *testing.T) {
	const legacy = "2023-09-2002C8PC-2L292Y80C-2YPJUCRYP-92QJ9RR8-9RR8UL2Y-JU2QLQ8L-P8YLGLGL-YQLJUQ8U"

	first := StableCWLID(legacy)
	second := StableCWLID(legacy)
	if first != "F1PPW_hG-A3h" {
		t.Fatalf("StableCWLID() = %q, want F1PPW_hG-A3h", first)
	}
	if first != second {
		t.Fatalf("StableCWLID() changed between calls: %q != %q", first, second)
	}
	if len(first) != 12 {
		t.Fatalf("StableCWLID() length = %d, want 12 (%q)", len(first), first)
	}
	if !regexp.MustCompile(`^[A-Za-z0-9_-]{12}$`).MatchString(first) {
		t.Fatalf("StableCWLID() = %q, want URL-safe identifier", first)
	}
	if first == StableCWLID(legacy+"-different") {
		t.Fatalf("StableCWLID() returned the same value for different legacy identities")
	}
}

func TestBadgeTokenStripsAssetURL(t *testing.T) {
	const fullURL = "https://api-assets.clashofclans.com/badges/200/zNRhkSZr3Wb2b_vDCkce3OuYIIyUhfdyKO_nz0TWMzk.png"
	const want = "zNRhkSZr3Wb2b_vDCkce3OuYIIyUhfdyKO_nz0TWMzk"

	if got := BadgeToken(fullURL); got != want {
		t.Fatalf("BadgeToken() = %q, want %q", got, want)
	}
}
