package servers

import (
	"encoding/json"
	"testing"
)

func TestNormalizeAnthropicSystem(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "string", raw: `"plain system"`, want: "plain system"},
		{name: "content blocks", raw: `[{"type":"text","text":"first"},{"type":"text","text":"second"}]`, want: "first\n\nsecond"},
	}

	for _, tt := range tests {
		got, err := normalizeAnthropicSystem(json.RawMessage(tt.raw))
		if err != nil {
			t.Fatalf("%s: unexpected error: %v", tt.name, err)
		}
		if got != tt.want {
			t.Fatalf("%s: got %q, want %q", tt.name, got, tt.want)
		}
	}
}

func TestResponsesInputHasCompactionTrigger(t *testing.T) {
	input := []any{
		map[string]any{"type": "message", "role": "user", "content": "hello"},
		map[string]any{"type": "compaction_trigger"},
	}
	if !responsesInputHasCompactionTrigger(input) {
		t.Fatal("expected compaction trigger to be detected")
	}
}
