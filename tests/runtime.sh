#!/usr/bin/env bash
# Metadata fields are consumed indirectly by the runtime's printf %q loop.
# Literal shell syntax below is deliberate adversarial test data.
# shellcheck disable=SC2034,SC2016
set -Eeuo pipefail
ZYWP_HOME=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$ZYWP_HOME/lib/common.sh"
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT

# Verify metadata round-trips literally and cannot execute injected shell syntax.
STATE="$temp/state"
DOMAIN=example.org URL=https://example.org ADMIN_USER=owner ADMIN_EMAIL=owner@example.org
PHP_VERSION=8.3 DB_NAME=zywp_aabbcc DB_USER=zywp_aabbcc PHASE=ready
TITLE='My site $(touch SHOULD_NOT_EXIST)'
save_state
TITLE=changed
# shellcheck disable=SC1090
source "$STATE"
[[ $TITLE == 'My site $(touch SHOULD_NOT_EXIST)' && ! -e SHOULD_NOT_EXIST ]]

# Verify WP-CLI receives secrets through stdin, never in argv.
runuser() {
    printf '%s\n' "$@" >"$temp/argv"
    cat >"$temp/stdin"
}
printf '%s\n' 'example-secret-password' | wp_cmd user update owner --prompt=user_pass
[[ $(cat "$temp/stdin") == example-secret-password ]]
if grep -q example-secret-password "$temp/argv"; then exit 1; fi
grep -q -- '--prompt=user_pass' "$temp/argv"

PASSWORD=long-valid-password
validate_password
PASSWORD=$'long-password\nline'
if (validate_password) 2>/dev/null; then exit 1; fi
printf 'Runtime quoting and secret handling passed.\n'
