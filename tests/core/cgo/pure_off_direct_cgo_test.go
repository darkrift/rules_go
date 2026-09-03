package pure_off_direct_test

import (
	"testing"

	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off"
)

func TestDirectCgoDependency(t *testing.T) {
	if got, want := pure_off.Value(), 40; got != want {
		t.Fatalf("Value() = %d; want %d", got, want)
	}
}
