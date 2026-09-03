// Copyright 2026 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package pure_off_library_config_test

import (
	"bytes"
	"testing"

	"github.com/bazelbuild/rules_go/go/tools/bazel_testing"
)

const pureFlag = "--@io_bazel_rules_go//go/config:pure=on"

func TestMain(m *testing.M) {
	bazel_testing.TestMain(m, bazel_testing.Args{
		Main: `
-- BUILD.bazel --
load("@io_bazel_rules_go//go:def.bzl", "go_binary", "go_library", "go_test")

go_library(
    name = "left_cgo",
    srcs = ["left_cgo.go"],
    cgo = True,
    importpath = "example.com/left_cgo",
    pure = "off",
)

go_library(
    name = "right_cgo",
    srcs = ["right_cgo.go"],
    cgo = True,
    importpath = "example.com/right_cgo",
    pure = "off",
)

go_library(
    name = "shared_pure",
    srcs = ["shared_pure.go"],
    importpath = "example.com/shared_pure",
    pure = "on",
)

go_library(
    name = "shared_auto",
    srcs = [
        "shared_auto_cgo.go",
        "shared_auto_pure.go",
    ],
    importpath = "example.com/shared_auto",
)

go_library(
    name = "left_branch",
    srcs = ["left_branch.go"],
    importpath = "example.com/left_branch",
    deps = [
        ":left_cgo",
        ":shared_auto",
        ":shared_pure",
    ],
)

go_library(
    name = "right_branch",
    srcs = ["right_branch.go"],
    importpath = "example.com/right_branch",
    deps = [
        ":right_cgo",
        ":shared_auto",
        ":shared_pure",
    ],
)

go_library(
    name = "pure_branch",
    srcs = ["pure_branch.go"],
    importpath = "example.com/pure_branch",
    pure = "on",
    deps = [
        ":shared_auto",
        ":shared_pure",
    ],
)

go_library(
    name = "diamond",
    srcs = ["diamond.go"],
    importpath = "example.com/diamond",
    deps = [
        ":left_branch",
        ":pure_branch",
        ":right_branch",
    ],
)

go_library(
    name = "embed_base",
    srcs = ["embed_base.go"],
    cgo = True,
    importpath = "example.com/embedded",
    pure = "off",
)

go_library(
    name = "embed_wrapper",
    srcs = ["embed_wrapper.go"],
    embed = [":embed_base"],
    importpath = "example.com/embedded",
)

go_library(
    name = "main_lib",
    srcs = ["main.go"],
    importpath = "example.com/main",
    deps = [
        ":diamond",
        ":embed_wrapper",
    ],
)

go_binary(
    name = "embedded_binary",
    embed = [":main_lib"],
)

go_binary(
    name = "deps_binary",
    srcs = ["main.go"],
    deps = [
        ":diamond",
        ":embed_wrapper",
    ],
)

go_test(
    name = "external_test",
    srcs = ["matrix_test.go"],
    deps = [
        ":diamond",
        ":embed_wrapper",
    ],
)

go_test(
    name = "internal_test",
    srcs = ["internal_test.go"],
    embed = [":embed_wrapper"],
)

-- left_cgo.go --
package left_cgo

/*
int left_value(void) { return 20; }
*/
import "C"

func Value() int { return int(C.left_value()) }

-- right_cgo.go --
package right_cgo

/*
int right_value(void) { return 10; }
*/
import "C"

func Value() int { return int(C.right_value()) }

-- shared_pure.go --
package shared_pure

func Value() int { return 1 }

-- shared_auto_cgo.go --
//go:build cgo

package shared_auto

func Value() int { return 3 }

-- shared_auto_pure.go --
//go:build !cgo

package shared_auto

func Value() int { return 30 }

-- left_branch.go --
package left_branch

import (
    "example.com/left_cgo"
    "example.com/shared_auto"
    "example.com/shared_pure"
)

func Value() int {
    return left_cgo.Value() + shared_auto.Value() + shared_pure.Value()
}

-- right_branch.go --
package right_branch

import (
    "example.com/right_cgo"
    "example.com/shared_auto"
    "example.com/shared_pure"
)

func Value() int {
    return right_cgo.Value() + shared_auto.Value() + shared_pure.Value()
}

-- pure_branch.go --
package pure_branch

import (
    "example.com/shared_auto"
    "example.com/shared_pure"
)

func Value() int { return shared_auto.Value() + shared_pure.Value() + 1 }

-- diamond.go --
package diamond

import (
    "example.com/left_branch"
    "example.com/pure_branch"
    "example.com/right_branch"
)

func Value() int {
    return left_branch.Value() + pure_branch.Value() + right_branch.Value()
}

-- embed_base.go --
package embedded

/*
int embedded_value(void) { return 7; }
*/
import "C"

func cgoValue() int { return int(C.embedded_value()) }

-- embed_wrapper.go --
package embedded

func Value() int { return cgoValue() + 1 }

-- main.go --
package main

import (
    "fmt"

    "example.com/diamond"
    "example.com/embedded"
)

func main() { fmt.Println(diamond.Value() + embedded.Value()) }

-- matrix_test.go --
package matrix_test

import (
    "testing"

    "example.com/diamond"
    "example.com/embedded"
)

func TestMatrix(t *testing.T) {
    if got, want := diamond.Value()+embedded.Value(), 51; got != want {
        t.Fatalf("got %d; want %d", got, want)
    }
}

-- internal_test.go --
package embedded

import "testing"

func TestEmbedded(t *testing.T) {
    if got, want := Value(), 8; got != want {
        t.Fatalf("got %d; want %d", got, want)
    }
}
`,
	})
}

func TestPureOffLibraryOverridesGlobalPure(t *testing.T) {
	if err := bazel_testing.RunBazel(
		"test",
		pureFlag,
		"--test_output=errors",
		"//:external_test",
		"//:internal_test",
	); err != nil {
		t.Fatal(err)
	}

	for _, target := range []string{"//:deps_binary", "//:embedded_binary"} {
		out, err := bazel_testing.BazelOutput("run", pureFlag, target)
		if err != nil {
			t.Fatalf("running %s: %v", target, err)
		}
		if got, want := string(bytes.TrimSpace(out)), "51"; got != want {
			t.Fatalf("%s output %q; want %q", target, got, want)
		}
	}
}
