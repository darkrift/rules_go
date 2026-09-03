package main

import (
	"fmt"

	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_embed"
	"github.com/bazelbuild/rules_go/tests/core/cgo/pure_off_matrix"
)

func main() {
	fmt.Println(pure_off_matrix.Value() + pure_off_embed.Value())
}
