package pure_off_test_service_consumer

import "github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_test_service"

func Value() int {
	return pure_off_test_service.Value() + 1
}
