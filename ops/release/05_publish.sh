#!/usr/bin/env bash
# 05_publish.sh

set -euo pipefail
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/commands/publish_release.sh" "$@"
