package pure_off_test_service

import "testing"

func TestInternalValue(t *testing.T) {
	if got, want := Value(), 40; got != want {
		t.Fatalf("Value() = %d; want %d", got, want)
	}
}
