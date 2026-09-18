#!/usr/bin/env bash
# Run the whole deployment: provision -> configure -> verify.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

./01-provision-aws.sh
./02-configure-instance.sh
./03-verify.sh
