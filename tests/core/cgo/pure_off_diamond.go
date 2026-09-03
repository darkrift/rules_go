package pure_off_diamond

import (
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_pure_branch"
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_wrapper"
)

func Value() int {
	return pure_off_wrapper.Value() + pure_off_pure_branch.Value()
}
