package warhistory

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const manifestName = "manifest.json"

type WarMappings struct {
	WarID      int32
	PlayerTags []string
}

type Manifest struct {
	RunID      string `json:"run_id"`
	Sequence   int    `json:"sequence"`
	WarCount   int    `json:"war_count"`
	ShardCount int    `json:"shard_count"`
}

type Writer struct {
	mu         sync.Mutex
	root       string
	runID      string
	shardCount int
	maxWars    int
	maxReady   int
	sequence   int
	windowDir  string
	windowWars int
	files      map[int]*os.File
	scratch    [][]byte
	closed     bool
}

func NewWriter(root, runID string, shardCount, maxWars, maxReady int) (*Writer, error) {
	if strings.TrimSpace(root) == "" {
		return nil, errors.New("player-history shard root is required")
	}
	if shardCount <= 0 || maxWars <= 0 || maxReady <= 0 {
		return nil, errors.New("player-history shard, window, and ready-window limits must be positive")
	}
	runID = SafeRunID(runID)
	runRoot := filepath.Join(root, runID)
	if err := os.MkdirAll(runRoot, 0o700); err != nil {
		return nil, err
	}
	writer := &Writer{
		root: root, runID: runID, shardCount: shardCount, maxWars: maxWars, maxReady: maxReady,
		files: make(map[int]*os.File), scratch: make([][]byte, shardCount),
	}
	if err := writer.resume(runRoot); err != nil {
		return nil, err
	}
	return writer, nil
}

func (w *Writer) Append(ctx context.Context, wars []WarMappings) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return errors.New("player-history writer is closed")
	}
	for len(wars) > 0 {
		if w.windowWars == 0 {
			if err := w.waitForCapacity(ctx); err != nil {
				return err
			}
		}
		count := min(len(wars), w.maxWars-w.windowWars)
		if err := w.appendMappings(wars[:count]); err != nil {
			return err
		}
		wars = wars[count:]
		w.windowWars += count
		if err := w.writeManifest(); err != nil {
			return err
		}
		if w.windowWars == w.maxWars {
			if err := w.seal(true); err != nil {
				return err
			}
		}
	}
	return nil
}

func (w *Writer) waitForCapacity(ctx context.Context) error {
	for {
		paths, err := DiscoverReady(w.root)
		if err != nil {
			return err
		}
		if len(paths) < w.maxReady {
			return nil
		}
		select {
		case <-time.After(time.Second):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (w *Writer) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return nil
	}
	w.closed = true
	if w.windowWars == 0 {
		if err := w.closeFiles(); err != nil {
			return err
		}
		if w.windowDir == "" {
			return nil
		}
		if err := os.Remove(filepath.Join(w.windowDir, manifestName)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		runRoot := filepath.Dir(w.windowDir)
		if err := os.Remove(w.windowDir); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		_ = os.Remove(runRoot)
		w.windowDir = ""
		return nil
	}
	if err := w.writeManifest(); err != nil {
		return err
	}
	return w.seal(false)
}

func (w *Writer) appendMappings(wars []WarMappings) error {
	for shard := range w.scratch {
		w.scratch[shard] = w.scratch[shard][:0]
	}
	for _, war := range wars {
		for _, playerTag := range war.PlayerTags {
			if playerTag == "" {
				continue
			}
			if len(playerTag) > 255 {
				return fmt.Errorf("invalid player tag length: %d", len(playerTag))
			}
			shard := int(HashPlayerTag(playerTag) % uint64(w.shardCount))
			buffer := w.scratch[shard]
			buffer = append(buffer, byte(len(playerTag)))
			buffer = append(buffer, playerTag...)
			buffer = binary.LittleEndian.AppendUint32(buffer, uint32(war.WarID))
			w.scratch[shard] = buffer
		}
	}
	for shard, payload := range w.scratch {
		if len(payload) == 0 {
			continue
		}
		file := w.files[shard]
		if file == nil {
			var err error
			file, err = os.OpenFile(ShardPath(w.windowDir, shard), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
			if err != nil {
				return err
			}
			w.files[shard] = file
		}
		if _, err := file.Write(payload); err != nil {
			return err
		}
	}
	return nil
}

func (w *Writer) closeFiles() error {
	var firstErr error
	for shard, file := range w.files {
		if err := file.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
		delete(w.files, shard)
	}
	return firstErr
}

func (w *Writer) resume(runRoot string) error {
	entries, err := os.ReadDir(runRoot)
	if err != nil {
		return err
	}
	maxSequence := 0
	var openPath string
	for _, entry := range entries {
		sequence, state, ok := parseWindowName(entry.Name())
		if !ok {
			continue
		}
		maxSequence = max(maxSequence, sequence)
		if state == "open" {
			if openPath != "" {
				return fmt.Errorf("multiple open player-history windows for run %s", w.runID)
			}
			openPath = filepath.Join(runRoot, entry.Name())
		}
	}
	if openPath == "" {
		w.sequence = maxSequence + 1
		return w.openWindow(runRoot)
	}
	manifest, err := ReadManifest(openPath)
	if err != nil {
		return err
	}
	if manifest.RunID != w.runID || manifest.ShardCount != w.shardCount {
		return errors.New("open player-history window configuration does not match current run")
	}
	w.sequence = manifest.Sequence
	w.windowDir = openPath
	w.windowWars = manifest.WarCount
	if w.windowWars >= w.maxWars {
		return w.seal(true)
	}
	return nil
}

func (w *Writer) openWindow(runRoot string) error {
	w.windowDir = filepath.Join(runRoot, windowName(w.sequence, "open"))
	if err := os.Mkdir(w.windowDir, 0o700); err != nil {
		return err
	}
	w.windowWars = 0
	return w.writeManifest()
}

func (w *Writer) writeManifest() error {
	manifest := Manifest{RunID: w.runID, Sequence: w.sequence, WarCount: w.windowWars, ShardCount: w.shardCount}
	payload, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	temporary := filepath.Join(w.windowDir, manifestName+".tmp")
	if err := os.WriteFile(temporary, append(payload, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, filepath.Join(w.windowDir, manifestName))
}

func (w *Writer) seal(openNext bool) error {
	if w.windowWars == 0 {
		return nil
	}
	if err := w.closeFiles(); err != nil {
		return err
	}
	if err := syncWindow(w.windowDir); err != nil {
		return err
	}
	runRoot := filepath.Dir(w.windowDir)
	ready := filepath.Join(runRoot, windowName(w.sequence, "ready"))
	if err := os.Rename(w.windowDir, ready); err != nil {
		return err
	}
	w.sequence++
	w.windowWars = 0
	if !openNext {
		w.windowDir = ""
		return nil
	}
	return w.openWindow(runRoot)
}

func syncWindow(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || (!strings.HasSuffix(entry.Name(), ".bin") && entry.Name() != manifestName) {
			continue
		}
		file, err := os.Open(filepath.Join(dir, entry.Name()))
		if err != nil {
			return err
		}
		syncErr := file.Sync()
		closeErr := file.Close()
		if syncErr != nil {
			return syncErr
		}
		if closeErr != nil {
			return closeErr
		}
	}
	directory, err := os.Open(dir)
	if err != nil {
		return err
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	if syncErr != nil {
		return syncErr
	}
	return closeErr
}

func DiscoverReady(root string) ([]string, error) {
	var paths []string
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() {
			return nil
		}
		_, state, ok := parseWindowName(entry.Name())
		if ok && (state == "ready" || state == "processing") {
			paths = append(paths, path)
			return filepath.SkipDir
		}
		return nil
	})
	sort.Strings(paths)
	return paths, err
}

func Claim(path string) (string, error) {
	sequence, state, ok := parseWindowName(filepath.Base(path))
	if !ok {
		return "", fmt.Errorf("invalid player-history window path %s", path)
	}
	if state == "processing" {
		return path, nil
	}
	claimed := filepath.Join(filepath.Dir(path), windowName(sequence, "processing"))
	if err := os.Rename(path, claimed); err != nil {
		return "", err
	}
	return claimed, nil
}

func ReadManifest(dir string) (Manifest, error) {
	var manifest Manifest
	payload, err := os.ReadFile(filepath.Join(dir, manifestName))
	if err != nil {
		return manifest, err
	}
	err = json.Unmarshal(payload, &manifest)
	return manifest, err
}

func ReadShard(path string) (map[string][]int32, error) {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string][]int32{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	reader := bufio.NewReaderSize(file, 1<<20)
	grouped := make(map[string][]int32)
	for {
		tag, warID, err := DecodeRecord(reader)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("decode %s: %w", path, err)
		}
		grouped[tag] = append(grouped[tag], warID)
	}
	for tag, warIDs := range grouped {
		sort.Slice(warIDs, func(i, j int) bool { return warIDs[i] < warIDs[j] })
		grouped[tag] = CompactWarIDs(warIDs)
	}
	return grouped, nil
}

func EncodeRecord(tag string, warID int32) ([]byte, error) {
	if len(tag) == 0 || len(tag) > 255 {
		return nil, fmt.Errorf("invalid player tag length: %d", len(tag))
	}
	record := make([]byte, 1+len(tag)+4)
	record[0] = byte(len(tag))
	copy(record[1:], tag)
	binary.LittleEndian.PutUint32(record[1+len(tag):], uint32(warID))
	return record, nil
}

func DecodeRecord(reader io.Reader) (string, int32, error) {
	var length [1]byte
	if _, err := io.ReadFull(reader, length[:]); err != nil {
		return "", 0, err
	}
	if length[0] == 0 {
		return "", 0, errors.New("zero-length player tag")
	}
	payload := make([]byte, int(length[0])+4)
	if _, err := io.ReadFull(reader, payload); err != nil {
		return "", 0, err
	}
	tagEnd := int(length[0])
	return string(payload[:tagEnd]), int32(binary.LittleEndian.Uint32(payload[tagEnd:])), nil
}

func CompactWarIDs(values []int32) []int32 {
	if len(values) < 2 {
		return values
	}
	write := 1
	for read := 1; read < len(values); read++ {
		if values[read] == values[write-1] {
			continue
		}
		values[write] = values[read]
		write++
	}
	return values[:write]
}

func HashPlayerTag(tag string) uint64 {
	const offset64 = 14695981039346656037
	const prime64 = 1099511628211
	hash := uint64(offset64)
	for index := 0; index < len(tag); index++ {
		hash ^= uint64(tag[index])
		hash *= prime64
	}
	return hash
}

func ShardPath(dir string, index int) string {
	return filepath.Join(dir, "shard-"+strconv.Itoa(index)+".bin")
}

func DonePath(dir string, index int) string {
	return filepath.Join(dir, "shard-"+strconv.Itoa(index)+".done")
}

func SafeRunID(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		value = "default"
	}
	var builder strings.Builder
	for _, character := range value {
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || character == '-' || character == '_' {
			builder.WriteRune(character)
		} else {
			builder.WriteByte('_')
		}
	}
	return builder.String()
}

func windowName(sequence int, state string) string {
	return fmt.Sprintf("window-%06d.%s", sequence, state)
}

func parseWindowName(value string) (int, string, bool) {
	if !strings.HasPrefix(value, "window-") {
		return 0, "", false
	}
	parts := strings.Split(strings.TrimPrefix(value, "window-"), ".")
	if len(parts) != 2 || (parts[1] != "open" && parts[1] != "ready" && parts[1] != "processing") {
		return 0, "", false
	}
	sequence, err := strconv.Atoi(parts[0])
	return sequence, parts[1], err == nil && sequence > 0
}
