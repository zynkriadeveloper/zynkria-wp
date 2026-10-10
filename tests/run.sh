#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
bash -n install.sh lib/common.sh bin/zywp tests/run.sh tests/runtime.sh
shellcheck -x install.sh lib/common.sh bin/zywp tests/run.sh tests/runtime.sh
python3 tests/test_inputs.py
bash tests/runtime.sh
# Native config validation needs nginx and PHP-FPM installed and root privileges.
if [[ ${1:-} == --config ]]; then python3 tests/check-config.py; fi
