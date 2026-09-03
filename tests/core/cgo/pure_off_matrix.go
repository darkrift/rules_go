package pure_off_matrix

import (
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_second_wrapper"
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_transitive"
)

func Value() int {
	return pure_off_transitive.Value() + pure_off_second_wrapper.Value()
}
