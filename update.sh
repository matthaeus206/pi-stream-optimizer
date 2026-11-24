#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() { printf 'Usage: %s [config.conf]\n' "$0"; }
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
(( $# <= 1 )) || { usage >&2; exit 2; }
(( EUID != 0 )) || die 'Run update as the checkout owner. It uses sudo for installation.'
config=${1:-$PROJECT_DIR/config.conf}
[[ -f $config ]] || die "Missing configuration: $config"
sudo -v
git -C "$PROJECT_DIR" pull --ff-only
sudo -- "$PROJECT_DIR/install.sh" "$config"
