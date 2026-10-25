#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$BASE_DIR/$(basename -- "${BASH_SOURCE[0]}")"
BUNDLED=0
# BEGIN MODULES
# shellcheck source=lib/common.sh
source "$BASE_DIR/lib/common.sh"
# shellcheck source=lib/system.sh
source "$BASE_DIR/lib/system.sh"
# shellcheck source=lib/access.sh
source "$BASE_DIR/lib/access.sh"
# shellcheck source=lib/wizard.sh
source "$BASE_DIR/lib/wizard.sh"
# END MODULES

main() {
    defaults
    parse_args "$@"
    if [[ $COMMAND == wizard ]]; then
        wizard
        [[ $COMMAND != cancelled ]] || return 0
    fi
    validate_options
    if [[ $COMMAND == plan ]]; then print_plan; return; fi
    require_host
    mkdir -p "$STATE_DIR/runs"
    chmod 700 "$STATE_DIR" "$STATE_DIR/runs"
    exec 9>"$STATE_DIR/operation.lock"
    flock -w 120 9 || die 'Another operation is running.'
    case "$COMMAND" in
        apply) apply_all ;;
        status) report ;;
        confirm) confirm_access ;;
        rollback) load_run; rollback_access ;;
    esac
    flock -u 9
    if [[ $COMMAND == apply && $INTERACTIVE == 1 ]]; then wizard_wait; fi
}

main "$@"
