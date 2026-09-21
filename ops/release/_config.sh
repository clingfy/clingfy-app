#!/usr/bin/env bash
# _config.sh

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=ops/release/lib/common.sh
source "$SCRIPT_ROOT/lib/common.sh"
# shellcheck source=ops/release/lib/context.sh
source "$SCRIPT_ROOT/lib/context.sh"
# shellcheck source=ops/release/lib/env.sh
source "$SCRIPT_ROOT/lib/env.sh"
# shellcheck source=ops/release/lib/apple.sh
source "$SCRIPT_ROOT/lib/apple.sh"
# shellcheck source=ops/release/lib/aws.sh
source "$SCRIPT_ROOT/lib/aws.sh"
# shellcheck source=ops/release/lib/sparkle.sh
source "$SCRIPT_ROOT/lib/sparkle.sh"

load_release_context "${APP_ENV:-local}" "$SCRIPT_ROOT"
