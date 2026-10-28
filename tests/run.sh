#!/bin/sh
set -eu

RAFT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export RAFT_ROOT
rex_bin=${REX_BIN:-rex}

for suite in behavior remote; do
    "$rex_bin" config check "$RAFT_ROOT/tests/$suite.lua"
done
for scenario in search cancel close unicode escape; do
    RAFT_TEST_CASE=$scenario "$rex_bin" config check "$RAFT_ROOT/tests/ui.lua"
done
"$rex_bin" config check "$RAFT_ROOT/examples/init.lua"
printf '\nAll RAFT checks passed.\n'
