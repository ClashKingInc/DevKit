package warhistory

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestWriterSealsFullAndFinalPartialWindows(t *testing.T) {
	root := t.TempDir()
	writer, err := NewWriter(root, "worker-a", 4, 4, 10)
	if err != nil {
		t.Fatal(err)
	}
	wars := []WarMappings{
		{WarID: 1, PlayerTags: []string{"#A", "#B"}},
		{WarID: 2, PlayerTags: []string{"#A", "#C"}},
		{WarID: 3, PlayerTags: []string{"#D"}},
		{WarID: 4, PlayerTags: []string{"#E"}},
		{WarID: 5, PlayerTags: []string{"#A"}},
		{WarID: 6, PlayerTags: []string{"#F"}},
	}
	if err := writer.Append(context.Background(), wars[:3]); err != nil {
		t.Fatal(err)
	}
	if err := writer.Append(context.Background(), wars[3:]); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	paths, err := DiscoverReady(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) != 2 {
		t.Fatalf("ready windows = %d, want 2", len(paths))
	}
	first, err := ReadManifest(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	second, err := ReadManifest(paths[1])
	if err != nil {
		t.Fatal(err)
	}
	if first.WarCount != 4 || second.WarCount != 2 {
		t.Fatalf("window war counts = %d, %d; want 4, 2", first.WarCount, second.WarCount)
	}
	warIDs := make(map[int32]struct{})
	for _, path := range paths {
		for shard := range 4 {
			rows, err := ReadShard(ShardPath(path, shard))
			if err != nil {
				t.Fatal(err)
			}
			for _, ids := range rows {
				for _, warID := range ids {
					warIDs[warID] = struct{}{}
				}
			}
		}
	}
	if len(warIDs) != 6 {
		t.Fatalf("unique mapped wars = %d, want 6", len(warIDs))
	}
}

func TestWriterCloseRemovesEmptyWindowAfterExactBoundary(t *testing.T) {
	root := t.TempDir()
	writer, err := NewWriter(root, "exact", 2, 2, 2)
	if err != nil {
		t.Fatal(err)
	}
	if err := writer.Append(context.Background(), []WarMappings{
		{WarID: 1, PlayerTags: []string{"#A"}},
		{WarID: 2, PlayerTags: []string{"#B"}},
	}); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	entries, err := os.ReadDir(filepath.Join(root, "exact"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "window-000001.ready" {
		t.Fatalf("run entries = %v; want only window-000001.ready", entries)
	}
}
