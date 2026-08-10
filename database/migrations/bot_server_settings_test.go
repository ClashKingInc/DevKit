//go:build ignore

package main

import (
	"reflect"
	"strings"
	"testing"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestDedupeRowsByIndexesKeepsLastCanonicalRow(t *testing.T) {
	firstUser := []any{"123", "old"}
	secondUser := []any{"456", "only"}
	latestUser := []any{"123", "latest"}

	got := dedupeRowsByIndexes([][]any{firstUser, secondUser, latestUser}, []int{0})
	want := [][]any{secondUser, latestUser}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("dedupeRowsByIndexes() = %#v, want %#v", got, want)
	}
}

func TestDedupeRowsByIndexesUsesWholeCompositeKey(t *testing.T) {
	first := []any{"server", "embed-a", "old"}
	other := []any{"server", "embed-b", "only"}
	latest := []any{"server", "embed-a", "latest"}

	got := dedupeRowsByIndexes([][]any{first, other, latest}, []int{0, 1})
	want := [][]any{other, latest}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("dedupeRowsByIndexes() = %#v, want %#v", got, want)
	}
}

func TestStringSliceReturnsNonNilEmptyArray(t *testing.T) {
	got := stringSlice(nil)
	if got == nil {
		t.Fatal("stringSlice(nil) returned nil; required SQL arrays must receive an empty array")
	}
	if len(got) != 0 {
		t.Fatalf("stringSlice(nil) length = %d, want 0", len(got))
	}
}

func TestReminderThreadIDUsesTypedSourceAliases(t *testing.T) {
	if got := reminderThreadID(bson.M{"thread_id": "typed", "thread": "legacy"}); got != "typed" {
		t.Fatalf("reminderThreadID(typed) = %q, want typed", got)
	}
	if got := reminderThreadID(bson.M{"thread": "legacy"}); got != "legacy" {
		t.Fatalf("reminderThreadID(legacy) = %q, want legacy", got)
	}
	if got := reminderThreadID(bson.M{}); got != "" {
		t.Fatalf("reminderThreadID(empty) = %q, want empty", got)
	}
}

func TestTicketIntegerFieldsRejectSnowflakesAndOutOfRangeValues(t *testing.T) {
	if got := nullableIntInRange("18", 1, 100); got != 18 {
		t.Fatalf("nullableIntInRange(18) = %#v, want 18", got)
	}
	if got := nullableIntInRange("948121999526461440", 1, 100); got != nil {
		t.Fatalf("nullableIntInRange(snowflake) = %#v, want nil", got)
	}
	if got := nullableIntInRange(6, 1, 5); got != nil {
		t.Fatalf("nullableIntInRange(style=6) = %#v, want nil", got)
	}
}

func TestTicketApplyModeUsesLegacyDefaultForMissingOrInvalidCount(t *testing.T) {
	if got := ticketApplyMode(bson.M{"account_apply": true}); got != 25 {
		t.Fatalf("ticketApplyMode(missing count) = %d, want 25", got)
	}
	if got := ticketApplyMode(bson.M{
		"account_apply": true,
		"num_apply":     "948121999526461440",
	}); got != 25 {
		t.Fatalf("ticketApplyMode(snowflake count) = %d, want 25", got)
	}
}

func TestTicketQuestionsEnforcesDatabaseLimits(t *testing.T) {
	longUnicodeQuestion := strings.Repeat("é", 201)
	got := ticketQuestions([]any{
		longUnicodeQuestion,
		"second",
		"third",
		"fourth",
		"fifth",
		"sixth",
	})
	if len(got) != 5 {
		t.Fatalf("ticketQuestions() returned %d questions, want 5", len(got))
	}
	if length := len([]rune(got[0])); length != 200 {
		t.Fatalf("ticketQuestions() first question length = %d, want 200 characters", length)
	}
}

func TestGiveawayImageNameKeepsOnlyTrustedCDNFilenameSuffix(t *testing.T) {
	tests := map[string]string{
		"https://cdn.clashking.xyz/giveaway_123e4567-e89b-12d3-a456-426614174000.png": "123e4567-e89b-12d3-a456-426614174000.png",
		"https://cdn.clashking.xyz/legacy/folder/giveaway_abc.png?version=2":          "abc.png",
		"https://CDN.CLASHKING.XYZ/giveaway_upper-host.png":                           "upper-host.png",
		"https://example.com/giveaway_untrusted.png":                                  "",
		"https://images.cdn.clashking.xyz/giveaway_subdomain.png":                     "",
		"https://cdn.clashking.xyz/legacy-without-required-prefix.png":                "",
		"": "",
	}
	for input, want := range tests {
		if got := giveawayImageName(input); got != want {
			t.Errorf("giveawayImageName(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestGiveawaysOneShotPlanOnlyTouchesGiveaways(t *testing.T) {
	plan := giveawaysOneShotPlan()
	allStatements := strings.Join(append(append(plan.ResetSQL, plan.DropIndexes...), plan.CreateIndexes...), "\n")
	if !strings.Contains(allStatements, "public.giveaways") {
		t.Fatal("giveaway-only plan does not target public.giveaways")
	}
	for _, unrelated := range []string{"tickets", "reminders", "short_links", "user_settings", "server_custom_embeds"} {
		if strings.Contains(allStatements, unrelated) {
			t.Fatalf("giveaway-only plan unexpectedly touches %s", unrelated)
		}
	}
}
