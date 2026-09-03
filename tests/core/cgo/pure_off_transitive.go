package pure_off_transitive

import "github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_diamond"

func Value() int {
	return pure_off_diamond.Value() + 1
}
