#!/usr/bin/env bash
# Independent review of a change by another AI, through OpenRouter.
#   test/review/review.sh 297abe5..c135034 specs/260_file_transport.md
# See test/review/README.md.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec mix run --no-start test/review/review.exs "$@"
