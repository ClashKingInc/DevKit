package migrateutil

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

type recordingExecutor struct {
	statements []string
}

func (r *recordingExecutor) Exec(_ context.Context, statement string, _ ...any) (pgconn.CommandTag, error) {
	r.statements = append(r.statements, statement)
	return pgconn.CommandTag{}, nil
}

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

func TestMigrationEnvPathDoesNotFallBackToDatabaseRoot(t *testing.T) {
	repositoryRoot := t.TempDir()
	databaseRoot := filepath.Join(repositoryRoot, "database")
	if err := os.MkdirAll(databaseRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(databaseRoot, ".env"), []byte("DATABASE=true\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if got, want := migrationEnvPath(databaseRoot), filepath.Join(repositoryRoot, ".env"); got != want {
		t.Fatalf("migrationEnvPath() = %q, want %q", got, want)
	}
}

func TestTimescaleURLFromCanonicalEnvironment(t *testing.T) {
	env := map[string]string{
		"TIMESCALE_HOST":     "timescale",
		"TIMESCALE_PORT":     "5432",
		"TIMESCALE_DATABASE": "tracking data",
		"TIMESCALE_USERNAME": "tracking",
		"TIMESCALE_PASSWORD": "p@ss/word",
		"TIMESCALE_SSLMODE":  "require",
	}
	got, err := timescaleURLFromEnv(env)
	if err != nil {
		t.Fatal(err)
	}
	if want := "postgres://tracking:p%40ss%2Fword@timescale:5432/tracking%20data?sslmode=require"; got != want {
		t.Fatalf("timescaleURLFromEnv() = %q, want %q", got, want)
	}
}

func TestTimescaleURLFromExplicitURL(t *testing.T) {
	const want = "postgres://tracking:secret@127.0.0.1:5432/clashking?sslmode=disable"
	got, err := timescaleURLFromEnv(map[string]string{"TIMESCALE_URL": want})
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("timescaleURLFromEnv() = %q, want %q", got, want)
	}
}

func TestTimescaleURLRejectsIncompleteExplicitURL(t *testing.T) {
	_, err := timescaleURLFromEnv(map[string]string{
		"TIMESCALE_URL": "postgres://legacy",
		"DATABASE_URL":  "postgres://legacy",
	})
	if err == nil {
		t.Fatal("timescaleURLFromEnv() accepted an explicit URL without a database")
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

func TestLoadCheckpointRejectsNonClanWarImporters(t *testing.T) {
	if _, err := LoadCheckpoint(Config{Root: t.TempDir()}, "player_stats"); err == nil {
		t.Fatal("LoadCheckpoint() allowed player_stats; only clan_wars may be resumable")
	}
}

func TestOneShotLifecycleDropsThenResetsAndBuildsOnlyWhenFinished(t *testing.T) {
	exec := &recordingExecutor{}
	plan := OneShotPlan{
		DropIndexes:   []string{"drop-a", "drop-b"},
		ResetSQL:      []string{"clear-child", "clear-parent"},
		CreateIndexes: []string{"create-a", "create-b"},
	}

	if err := StartOneShot(context.Background(), exec, plan); err != nil {
		t.Fatal(err)
	}
	wantStart := []string{"drop-a", "drop-b", "clear-child", "clear-parent"}
	if len(exec.statements) != len(wantStart) {
		t.Fatalf("StartOneShot statements = %v, want %v", exec.statements, wantStart)
	}
	for index := range wantStart {
		if exec.statements[index] != wantStart[index] {
			t.Fatalf("StartOneShot statements = %v, want %v", exec.statements, wantStart)
		}
	}

	if err := FinishOneShot(context.Background(), exec, plan); err != nil {
		t.Fatal(err)
	}
	wantAll := append(wantStart, "create-a", "create-b")
	if len(exec.statements) != len(wantAll) {
		t.Fatalf("full lifecycle statements = %v, want %v", exec.statements, wantAll)
	}
	for index := range wantAll {
		if exec.statements[index] != wantAll[index] {
			t.Fatalf("full lifecycle statements = %v, want %v", exec.statements, wantAll)
		}
	}
}

func TestClanWarsCheckpointLivesAtRepositoryRoot(t *testing.T) {
	repositoryRoot := t.TempDir()
	databaseRoot := filepath.Join(repositoryRoot, "database")
	if err := os.MkdirAll(databaseRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	checkpoint, err := LoadCheckpoint(Config{Root: databaseRoot}, "clan_wars")
	if err != nil {
		t.Fatal(err)
	}
	if err := checkpoint.Set("clan_war_id", "64b000000000000000000001"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(repositoryRoot, "migration_state.json")); err != nil {
		t.Fatalf("repository-root migration_state.json was not written: %v", err)
	}
	if _, err := os.Stat(filepath.Join(databaseRoot, "migration_state.json")); !os.IsNotExist(err) {
		t.Fatalf("database/migration_state.json should not be used, stat err=%v", err)
	}
}

func TestClanWarsCheckpointSupportsIndependentWorkerFiles(t *testing.T) {
	repositoryRoot := t.TempDir()
	databaseRoot := filepath.Join(repositoryRoot, "database")
	if err := os.MkdirAll(databaseRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	checkpoint, err := LoadCheckpoint(Config{
		Root: databaseRoot,
		Env:  map[string]string{"MIGRATION_STATE_FILE": "worker-a.json"},
	}, "clan_wars")
	if err != nil {
		t.Fatal(err)
	}
	if err := checkpoint.Set("range-a", "64b000000000000000000001"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(repositoryRoot, "worker-a.json")); err != nil {
		t.Fatalf("worker checkpoint was not written: %v", err)
	}
	if _, err := os.Stat(filepath.Join(repositoryRoot, "migration_state.json")); !os.IsNotExist(err) {
		t.Fatalf("default checkpoint should not be used, stat err=%v", err)
	}
}
