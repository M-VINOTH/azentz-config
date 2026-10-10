#!/usr/bin/env bash
# Forward to the canonical script so this copy cannot resolve paths from the working directory.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/scripts/update-cognito-verification-email.sh" "$@"
