package pure_off_pure_branch

import (
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_auto_conditional"
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_sibling"
)

func Value() int {
	return pure_off_auto_conditional.Value() + pure_off_sibling.Value() + 1
}
