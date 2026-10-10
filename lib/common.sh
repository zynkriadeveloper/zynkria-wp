#!/usr/bin/env bash
# Shared Zynkria runtime, installed root-owned under /opt/zywp.
VERSION=$(cat "${ZYWP_HOME}/VERSION")
export VERSION
STATE=/etc/zywp/site.conf
WEBROOT=/var/www/zywp/public
SITE_USER=zywp

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
say() { printf '\n[ZYWP] %s\n' "$*"; }
confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer </dev/tty
    [[ $answer == y || $answer == Y ]]
}
root_required() { [[ $EUID == 0 ]] || die 'Run this command with sudo.'; }
lock_runtime() {
    mkdir -p /run/lock
    exec 9>/run/lock/zywp.lock
    flock -n 9 || die 'Another zywp operation is running.'
}
load_state() {
    [[ -f $STATE && ! -L $STATE ]] || die 'No managed installation found. Run install.sh first.'
    [[ $(stat -c %u "$STATE") == 0 && $(stat -c %a "$STATE") == 600 ]] || die 'Unsafe site state permissions.'
    # This file is generated with printf %q, is root-owned and private.
    # shellcheck disable=SC1090
    source "$STATE"
    [[ $WEBROOT == /var/www/zywp/public && $SITE_USER == zywp ]] || die 'Invalid managed paths.'
    [[ $PHP_VERSION =~ ^8\.[0-9]+$ && $DB_NAME =~ ^zywp_[a-f0-9]+$ ]] || die 'Invalid managed state.'
}
save_state() {
    local key temp directory
    directory=$(dirname -- "$STATE")
    install -d -m 700 "$directory"
    temp=$(mktemp "$directory/.state.XXXXXX")
    for key in DOMAIN URL TITLE ADMIN_USER ADMIN_EMAIL PHP_VERSION DB_NAME DB_USER WEBROOT SITE_USER PHASE; do
        printf '%s=%q\n' "$key" "${!key}" >>"$temp"
    done
    chmod 600 "$temp"
    mv "$temp" "$STATE"
}
wp_cmd() {
    runuser -u "$SITE_USER" -- env -i HOME=/var/lib/zywp PATH=/usr/local/bin:/usr/bin:/bin \
        WP_CLI_CONFIG_PATH=/dev/null "/usr/bin/php${PHP_VERSION}" \
        /opt/zywp/wp-cli.phar --path="$WEBROOT" --skip-plugins --skip-themes "$@"
}
diagnose() {
    local issues=0 service
    say 'Checking installed packages, services and configuration'
    for service in nginx mariadb php-fpm; do
        if dpkg-query -W -f='${Status}\n' "$service" 2>/dev/null | grep -q 'install ok installed'; then
            printf '  %-12s installed\n' "$service"
        else
            printf '  %-12s missing (will be installed)\n' "$service"
        fi
    done
    if command -v nginx >/dev/null && ! nginx -t; then issues=$((issues+1)); fi
    if [[ -f $STATE ]]; then
        load_state
        for service in nginx mariadb "php${PHP_VERSION}-fpm"; do
            if ! systemctl is-active --quiet "$service"; then
                printf '  Service is not active: %s\n' "$service"; issues=$((issues+1))
            fi
        done
        if ! "/usr/sbin/php-fpm${PHP_VERSION}" -t; then issues=$((issues+1)); fi
        if ! wp_cmd core is-installed; then issues=$((issues+1)); fi
        if [[ $PHASE != ready ]]; then
            printf '  Previous installation is incomplete (%s).\n' "$PHASE"; issues=$((issues+1))
        fi
    fi
    (( issues == 0 ))
}
backup_site() {
    local target path
    local -a configs=()
    target="/var/backups/zywp/$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 3)"
    install -d -m 700 "$target"
    cp "$STATE" "$target/site.conf"
    if [[ -d $WEBROOT ]]; then
        tar -czf "$target/wordpress.tar.gz" -C /var/www/zywp public
        tar -tzf "$target/wordpress.tar.gz" >/dev/null
    fi
    if [[ $(mariadb -NBe "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME'") == 1 ]]; then
        mariadb-dump --single-transaction --routines --events "$DB_NAME" | gzip >"$target/database.sql.gz"
        gzip -t "$target/database.sql.gz"
    fi
    cp -a /etc/nginx/sites-available/zywp.conf "$target/" 2>/dev/null || true
    for path in "php/$PHP_VERSION/fpm" nginx/zywp mysql/mariadb.conf.d/60-zywp.cnf cron.d/zywp logrotate.d/zywp; do
        if [[ -e /etc/$path ]]; then configs+=("$path"); fi
    done
    if (( ${#configs[@]} > 0 )); then
        tar -czf "$target/configuration.tar.gz" -C /etc "${configs[@]}"
        tar -tzf "$target/configuration.tar.gz" >/dev/null
    fi
    if [[ -d /etc/letsencrypt ]]; then
        tar -czf "$target/tls.tar.gz" -C /etc letsencrypt
    fi
    say "Backup saved to $target. Keep a copy off this server."
}
render() {
    python3 - "$1" "$2" "$DOMAIN" "$WEBROOT" "$CHILDREN" <<'PY'
import pathlib, sys
source, destination, domain, root, children = sys.argv[1:]
text = pathlib.Path(source).read_text()
for key, value in {'DOMAIN': domain, 'WEBROOT': root, 'CHILDREN': children}.items():
    text = text.replace('@' + key + '@', value)
pathlib.Path(destination).write_text(text)
PY
}
read_password() {
    local repeat
    read -r -s -p 'Password (minimum 12 characters): ' PASSWORD </dev/tty; printf '\n'
    [[ ${#PASSWORD} -ge 12 ]] || die 'Use at least 12 characters.'
    read -r -s -p 'Confirm password: ' repeat </dev/tty; printf '\n'
    [[ $PASSWORD == "$repeat" ]] || die 'Passwords do not match.'
}
validate_password() {
    [[ ${#PASSWORD} -ge 12 && $PASSWORD != *$'\n'* && $PASSWORD != *$'\r'* ]] || die 'Use at least 12 characters without line breaks.'
}
