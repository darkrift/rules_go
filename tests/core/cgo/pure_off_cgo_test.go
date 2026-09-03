package pure_off_test

import (
	"testing"

	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off"
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_auto_conditional"
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_embed"
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_matrix"
)

func TestDirectCgoDependencyInMixedConsumer(t *testing.T) {
	if got, want := pure_off.Value(), 40; got != want {
		t.Fatalf("Value() = %d; want %d", got, want)
	}
}

func TestAutoDependencySelectsCgoSources(t *testing.T) {
	if got, want := pure_off_auto_conditional.Value(), 8; got != want {
		t.Fatalf("Value() = %d; want %d", got, want)
	}
}

func TestEmbeddedCgoDependency(t *testing.T) {
	if got, want := pure_off_embed.Value(), 7; got != want {
		t.Fatalf("Value() = %d; want %d", got, want)
	}
}

func TestTransitiveMixedDiamond(t *testing.T) {
	if got, want := pure_off_matrix.Value(), 76; got != want {
		t.Fatalf("Value() = %d; want %d", got, want)
	}
}
