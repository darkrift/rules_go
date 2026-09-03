package pure_off_wrapper

import (
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off"
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_auto_conditional"
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_sibling"
)

func Value() int {
	return pure_off.Value() + pure_off_auto_conditional.Value() + pure_off_sibling.Value()
}
