#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ZYWP_HOME=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$ZYWP_HOME/lib/common.sh"
trap 'printf "\nInstallation stopped at line %s. No automatic deletion was performed. Check journalctl and run zywp doctor when available.\n" "$LINENO" >&2' ERR

banner() {
    cat <<EOF
============================================================
                 ZYNKRIA | ZYWP v${VERSION}
       WordPress + Nginx + PHP-FPM + MariaDB installer
============================================================
English preview release. One managed WordPress site per server.
Notice: use a dedicated Ubuntu 24.04 or Debian 13 VPS.
Installation changes system packages and service configuration.
Reinstallation replaces the managed site after a backup.
Donate: https://paypal.me/zynkria
EOF
}
preflight() {
    [[ $(uname -s) == Linux ]] || die 'This installer runs on Linux, not Windows.'
    root_required
    [[ -t 0 ]] || die 'Run from an interactive terminal, not curl | bash.'
    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID:$VERSION_ID" in
        ubuntu:24.04) PHP_VERSION=8.3 ;;
        debian:13) PHP_VERSION=8.4 ;;
        *) die 'Supported systems: Ubuntu 24.04 LTS and Debian 13.' ;;
    esac
    [[ -d /run/systemd/system ]] || die 'A booted systemd server is required.'
    for tool in flock runuser python3; do command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"; done
    lock_runtime
    (( $(awk '/MemTotal/ {print $2}' /proc/meminfo) >= 950000 )) || die 'At least 1 GB RAM is required.'
    (( $(df -Pk /var | awk 'NR==2 {print $4}') >= 2097152 )) || die 'At least 2 GB free space is required (more for backups).'
    if systemctl is-active --quiet apache2; then die 'Apache occupies the web ports. Resolve this before installation.'; fi
    if [[ ! -f $STATE ]]; then
        [[ ! -e /var/www/zywp && ! -e /etc/nginx/sites-available/zywp.conf ]] || die 'Unmanaged zywp paths exist; inspect them first.'
        ! getent passwd zywp >/dev/null || die 'An unmanaged zywp account already exists.'
        if command -v ss >/dev/null && ss -ltnH '( sport = :80 or sport = :443 )' | grep -q .; then
            die 'Ports 80/443 are occupied. Use a dedicated server.'
        fi
        if [[ -d /etc/nginx/sites-enabled ]] && find /etc/nginx/sites-enabled -mindepth 1 ! -name default -print -quit | grep -q .; then
            die 'Existing Nginx sites detected. Use a dedicated server.'
        fi
    fi
}
install_packages() {
    say 'Installing packages from the official distribution repositories'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx mariadb-server mariadb-client \
        "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-mysql" \
        "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-mbstring" \
        "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-intl" \
        "php${PHP_VERSION}-opcache" curl ca-certificates openssl gnupg nano \
        python3 cron certbot python3-certbot-nginx
    systemctl enable --now mariadb cron
    mariadb-admin ping >/dev/null
}
collect_site() {
    local authority label
    read -r -p 'URL (https://example.com): ' URL </dev/tty
    [[ $URL =~ ^https?://([a-zA-Z0-9.-]+)/?$ ]] || die 'Use a domain URL without a port, path, or query.'
    DOMAIN=${BASH_REMATCH[1],,}
    [[ ${#DOMAIN} -le 253 && $DOMAIN == *.* && $DOMAIN != *..* && ! $DOMAIN =~ ^[0-9.]+$ ]] || die 'Use a valid public DNS domain.'
    authority=$DOMAIN
    while [[ -n $authority ]]; do
        label=${authority%%.*}
        [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die 'Invalid domain label.'
        if [[ $authority == *.* ]]; then authority=${authority#*.}; else authority=; fi
    done
    URL="${URL%%://*}://$DOMAIN"
    read -r -p 'Website name: ' TITLE </dev/tty
    [[ -n $TITLE ]] || die 'Website name is required.'
    read -r -p 'Administrator username: ' ADMIN_USER </dev/tty
    [[ $ADMIN_USER =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{2,59}$ ]] || die 'Use a username of 3-60 letters, digits, dots, underscores or hyphens.'
    read -r -p 'Administrator email: ' ADMIN_EMAIL </dev/tty
    [[ $ADMIN_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die 'Invalid email address.'
    read_password
    if [[ $URL == https://* ]]; then
        printf 'HTTPS needs DNS pointing here, public ports 80/443, and acceptance of the Let\x27s Encrypt terms.\n'
        confirm 'Accept certificate registration using your administrator email?' || die 'HTTPS setup cancelled.'
    else
        confirm 'HTTP sends passwords without encryption. Continue with HTTP?' || die 'Choose an HTTPS URL.'
    fi
}
install_runtime() {
    if [[ $ZYWP_HOME != /opt/zywp ]]; then
        install -d -m 755 /opt/zywp/lib /opt/zywp/bin /opt/zywp/nginx/templates /opt/zywp/php
        install -m 644 "$ZYWP_HOME/VERSION" /opt/zywp/VERSION
        install -m 644 "$ZYWP_HOME/lib/common.sh" /opt/zywp/lib/common.sh
        install -m 755 "$ZYWP_HOME/install.sh" /opt/zywp/install.sh
        install -m 755 "$ZYWP_HOME/bin/zywp" /opt/zywp/bin/zywp
        install -m 644 "$ZYWP_HOME"/nginx/templates/*.conf /opt/zywp/nginx/templates/
        install -m 644 "$ZYWP_HOME"/php/* /opt/zywp/php/
    fi
    ln -sfn /opt/zywp/bin/zywp /usr/local/bin/zywp
    local temp base
    temp=$(mktemp -d)
    base=https://raw.githubusercontent.com/wp-cli/builds/gh-pages
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$base/phar/wp-cli.phar" -o "$temp/wp-cli.phar"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$base/phar/wp-cli.phar.asc" -o "$temp/wp-cli.phar.asc"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$base/wp-cli.pgp" -o "$temp/wp-cli.pgp"
    mkdir -m 700 "$temp/gnupg"
    gpg --homedir "$temp/gnupg" --batch --import "$temp/wp-cli.pgp"
    verify_wpcli "$temp"
    install -m 644 "$temp/wp-cli.phar" /opt/zywp/wp-cli.phar
    rm -rf -- "$temp"
}
configure_stack() {
    local memory
    getent passwd zywp >/dev/null || useradd --system --user-group --home-dir /var/lib/zywp --create-home --shell /usr/sbin/nologin zywp
    install -d -m 750 -o zywp -g zywp /var/lib/zywp
    install -d -m 750 -o zywp -g www-data /var/www/zywp "$WEBROOT"
    install -d -m 750 -o zywp -g zywp /var/log/zywp
    touch /var/log/zywp/php-error.log
    chown zywp:zywp /var/log/zywp/php-error.log
    chmod 640 /var/log/zywp/php-error.log
    memory=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    CHILDREN=$(( memory / 512 )); (( CHILDREN >= 2 )) || CHILDREN=2
    (( CHILDREN <= 16 )) || CHILDREN=16
    install -d -m 755 /etc/nginx/zywp
    install -m 644 "$ZYWP_HOME/nginx/templates/wordpress-rules.conf" /etc/nginx/zywp/wordpress-rules.conf
    install -m 644 "$ZYWP_HOME/php/zywp.ini" "/etc/php/$PHP_VERSION/fpm/conf.d/99-zywp.ini"
    render "$ZYWP_HOME/php/pool.conf" "/etc/php/$PHP_VERSION/fpm/pool.d/zywp.conf"
    render "$ZYWP_HOME/nginx/templates/wordpress.conf" /etc/nginx/sites-available/zywp.conf
    chmod 644 "/etc/php/$PHP_VERSION/fpm/pool.d/zywp.conf" /etc/nginx/sites-available/zywp.conf
    ln -sfn /etc/nginx/sites-available/zywp.conf /etc/nginx/sites-enabled/zywp.conf
    rm -f /etc/nginx/sites-enabled/default
    # Database listens locally; administrative Unix socket authentication is retained.
    cat >/etc/mysql/mariadb.conf.d/60-zywp.cnf <<'EOF'
[mysqld]
bind-address = 127.0.0.1
local-infile = 0
EOF
    nginx -t
    "/usr/sbin/php-fpm${PHP_VERSION}" -t
    systemctl enable "php${PHP_VERSION}-fpm" nginx
    systemctl restart mariadb "php${PHP_VERSION}-fpm"
    systemctl restart nginx
}
create_wordpress() {
    local dbpass
    dbpass=$(openssl rand -hex 32)
    mariadb <<SQL
CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$dbpass';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
SQL
    wp_cmd core download --locale=en_US
    wp_cmd core verify-checksums
    printf '%s\n' "$dbpass" | wp_cmd config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbhost=localhost --prompt=dbpass
    unset dbpass
    wp_cmd config set DISALLOW_FILE_EDIT true --raw
    wp_cmd config set WP_DEBUG false --raw
    wp_cmd config set DISABLE_WP_CRON true --raw
    printf '%s\n' "$PASSWORD" | wp_cmd core install --url="$URL" --title="$TITLE" \
        --admin_user="$ADMIN_USER" --admin_email="$ADMIN_EMAIL" --skip-email --prompt=admin_password
    unset PASSWORD
    wp_cmd rewrite structure '/%postname%/'
    find "$WEBROOT" -type d -exec chmod 2750 {} +
    find "$WEBROOT" -type f -exec chmod 640 {} +
    chown -R zywp:www-data "$WEBROOT"
    chmod 600 "$WEBROOT/wp-config.php"
    cat >/etc/cron.d/zywp <<EOF
SHELL=/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * zywp /usr/bin/php${PHP_VERSION} /opt/zywp/wp-cli.phar --path=$WEBROOT cron event run --due-now --quiet >> /var/log/zywp/cron.log 2>&1
EOF
    chmod 644 /etc/cron.d/zywp
    cat >/etc/logrotate.d/zywp <<'EOF'
/var/log/zywp/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    su zywp zywp
    create 0640 zywp zywp
}
EOF
    chmod 644 /etc/logrotate.d/zywp
    if [[ $URL == https://* ]]; then
        certbot --nginx --non-interactive --agree-tos --email "$ADMIN_EMAIL" -d "$DOMAIN" --redirect
        systemctl enable --now certbot.timer
    fi
    nginx -t
    wp_cmd core is-installed
    if [[ $URL == https://* ]]; then
        curl --fail --silent --show-error --resolve "$DOMAIN:443:127.0.0.1" "$URL/wp-login.php" -o /dev/null
    else
        curl --fail --silent --show-error --resolve "$DOMAIN:80:127.0.0.1" "$URL/wp-login.php" -o /dev/null
    fi
    PHASE=ready
    save_state
    say "WordPress is ready: $URL/wp-admin/"
    printf 'Admin: %s\nCommands: sudo zywp help\nDonate: https://paypal.me/zynkria\n' "$ADMIN_USER"
}
main() {
    banner
    preflight
    local choice recovery=no
    if ! diagnose; then
        say 'Possible errors detected. Inspect the output before continuing.'
        confirm 'Do you want to perform a new managed installation?' || exit 1
        recovery=yes
    fi
    printf '\n1: INSTALL WORDPRESS\n2: REINSTALL WORDPRESS\n0: EXIT\n'
    read -r -p 'Choose an option: ' choice </dev/tty
    case $choice in
        0) exit 0 ;;
        1) [[ ! -f $STATE ]] || die 'A managed site exists. Choose reinstall.' ;;
        2) load_state
           confirm 'Back up and replace the managed WordPress site? Existing content will be replaced.' || exit 0
           backup_site
           ;;
        *) die 'Invalid option.' ;;
    esac
    if [[ $recovery == yes ]] && command -v nginx >/dev/null; then
        # Only the managed vhost may be temporarily disabled to repair it.
        if [[ -f $STATE ]]; then rm -f /etc/nginx/sites-enabled/zywp.conf; fi
        nginx -t || die 'Unmanaged Nginx errors remain. Repair them first.'
    fi
    install_packages
    collect_site
    if [[ $choice == 2 && -d $WEBROOT ]]; then
        mv "$WEBROOT" "/var/www/zywp/previous-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 3)"
        say 'Old files and database retained; restore instructions are in README.md.'
    fi
    install_runtime
    DB_NAME="zywp_$(openssl rand -hex 6)"
    DB_USER=$DB_NAME
    PHASE=installing
    save_state
    configure_stack
    create_wordpress
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
