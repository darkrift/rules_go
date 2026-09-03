package pure_off_test_service_test

import (
	"testing"

	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_test_service"
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_test_service_consumer"
)

func TestExternalAndTransitiveValues(t *testing.T) {
	if got, want := pure_off_test_service.Value(), 40; got != want {
		t.Fatalf("pure_off_test_service.Value() = %d; want %d", got, want)
	}
	if got, want := pure_off_test_service_consumer.Value(), 41; got != want {
		t.Fatalf("pure_off_test_service_consumer.Value() = %d; want %d", got, want)
	}
}
