package servers

import (
	"encoding/json"
	"testing"
)

func TestParseAnthropicSystem(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "string", raw: `"plain system"`, want: "plain system"},
		{name: "content blocks", raw: `[{"type":"text","text":"first "},{"type":"text","text":"second"}]`, want: "first second"},
	}

	for _, tt := range tests {
		got, err := parseAnthropicSystem(json.RawMessage(tt.raw))
		if err != nil {
			t.Fatalf("%s: unexpected error: %v", tt.name, err)
		}
		if got != tt.want {
			t.Fatalf("%s: got %q, want %q", tt.name, got, tt.want)
		}
	}
}
