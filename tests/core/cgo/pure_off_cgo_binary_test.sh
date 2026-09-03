#!/usr/bin/env bash

set -euo pipefail

for name in pure_off_cgo_binary pure_off_cgo_deps_binary; do
  got="$(${TEST_SRCDIR}/_main/tests/core/cgo/${name}_/${name})"
  if [[ "$got" != "83" ]]; then
    echo "${name} output $got; want 83" >&2
    exit 1
  fi
done
