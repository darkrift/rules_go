package pure_off_embed

import "testing"

func TestEmbeddedCgoDependency(t *testing.T) {
	if got, want := Value(), 7; got != want {
		t.Fatalf("Value() = %d; want %d", got, want)
	}
}
