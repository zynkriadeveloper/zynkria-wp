# Zynkria WordPress — ZYWP

**Version 0.1.0 · English preview release**

An interactive installer and management command for a single WordPress website on a dedicated Linux VPS. Zynkria installs Nginx, PHP-FPM, MariaDB, WordPress and their required packages, then creates the website from your answers.

[Support development with PayPal](https://paypal.me/zynkria)

## Requirements

- Ubuntu 24.04 LTS (PHP 8.3) or Debian 13 (PHP 8.4), using their official repositories.
- A dedicated server with systemd, root/sudo access, Python 3 and util-linux (`flock`, `runuser`).
- At least 1 GB RAM and 2 GB free disk space. Allow additional space for WordPress, uploads and backups; 2 GB RAM or more is preferable.
- A public domain pointing to the server. For HTTPS, both any A and AAAA records must reach this server and ports 80/443 must be reachable from the Internet.
- Outbound access to distribution repositories, WordPress.org, GitHub and Let's Encrypt.

This release manages **one site per server**. It refuses unsupported operating systems, active Apache, occupied web ports and existing unmanaged Nginx sites. It is not a hosting control panel or a Windows stack installer. Review it on a disposable VPS before production use. Automated checks validate scripts, input handling and templates; full fresh-server installation and recovery still need end-to-end validation on both supported distributions.

## Download and install

Connect to your Linux server, then run:

```bash
sudo apt-get update
sudo apt-get install -y git python3 util-linux
git clone https://github.com/zynkriadeveloper/zynkria-wp.git
cd zynkria-wp
sudo bash install.sh
```

Download the complete repository; the installer needs its templates and library. Review the script before running it. Do not pipe a remote download directly into Bash.

The welcome screen shows the Zynkria brand, version, description, notice and donation link. It checks packages, managed services and available configuration. Missing packages are normal on a fresh server. When errors are detected, it asks whether you want a new managed installation; errors outside Zynkria's configuration must be repaired first.

```text
1: INSTALL WORDPRESS
2: REINSTALL WORDPRESS
0: EXIT
```

Option 1 installs the stack, then asks for:

```text
URL (https://example.com):
Website name:
Administrator username:
Administrator email:
Password (minimum 12 characters):
Confirm password:
```

Use a domain URL without a path, port, credentials or query. HTTPS registers a Let's Encrypt certificate using your administrator email after confirmation. WordPress email delivery itself needs a mail service or SMTP plugin; supplying an administrator email does not configure outgoing mail.

The installer does not change your firewall or DNS. Enable HTTP/HTTPS in your VPS firewall and retain SSH access. MariaDB binds to localhost. It retains distribution administrator authentication instead of replacing the database root password.

## Management commands

The installed command is `zywp`. System management requires sudo.

| Command | Purpose |
| --- | --- |
| `sudo zywp admin pass` | Prompt for a new password for the configured administrator |
| `sudo zywp admin pass 'new-password'` | Set that password directly |
| `sudo zywp admin new username` | Prompt for email and password and create an administrator |
| `sudo zywp admin new username 'new-password'` | Prompt for email and create an administrator with the supplied password |
| `sudo zywp restart server` | Validate configuration and restart Nginx, PHP-FPM and MariaDB |
| `sudo zywp changer php.ini` | Edit the effective Zynkria PHP-FPM overrides in nano; offer to reload PHP |
| `sudo zywp logs` | Last 100 lines of the managed Nginx error log |
| `sudo zywp logs php` | PHP errors |
| `sudo zywp logs server` | Service journal for Nginx, PHP-FPM and MariaDB |
| `sudo zywp logs cron` | WordPress scheduled task output |
| `sudo zywp doctor` | Check services, configuration and WordPress/database connectivity |
| `sudo zywp backup` | Create a private backup |
| `sudo zywp reinstall` | Open the install/reinstall menu |
| `zywp version` / `zywp help` | Show version or help |

`restart server` restarts the web stack services; it does **not** reboot Linux. Prefer interactive password entry: command arguments can appear in shell history and process listings. ZYWP passes prompted WordPress/database passwords to WP-CLI via stdin and does not store the administrator password in its state file.

`changer php.ini` opens `/etc/php/<version>/fpm/conf.d/99-zywp.ini`, which overrides the base `php.ini`. PHP-FPM configuration is checked after editing and invalid overrides are restored. Not every semantically incorrect PHP value is detected by the PHP parser; inspect the effective values and test your application after editing.

## Configuration and optimizations

```text
nginx/templates/wordpress.conf       Single-site virtual host template
nginx/templates/wordpress-rules.conf Gzip rules
php/pool.conf                       Dedicated PHP-FPM pool template
php/zywp.ini                        PHP-FPM overrides and OPcache
lib/common.sh                       Shared Zynkria management logic
bin/zywp                            Zynkria CLI
install.sh                          Interactive installer
```

- WordPress permalink routing and a Unix socket for PHP-FPM.
- A dedicated unprivileged `zywp` account; Nginx reads static files through `www-data` group permissions. WP-CLI runs as the site account, not root.
- Checks that a PHP file exists before execution; blocks PHP execution inside uploads, dotfiles, backup files and direct access to `wp-config.php`.
- XML-RPC blocked by default. Remove that location deliberately if Jetpack, mobile apps or another integration needs it.
- Gzip level 5 for static text assets, seven-day static asset caching, OPcache, conservative PHP limits and a memory-scaled ondemand FPM pool (2–16 children). These are starting values, not a workload benchmark; monitor real memory per worker before increasing concurrency.
- Gzip disabled in PHP responses to reduce compression side channels on authenticated pages. No full-page FastCGI cache is enabled, so carts, checkout and authenticated content are not accidentally cached.
- HTTP security headers, hidden PHP/Nginx version banners, WordPress file editor disabled, and no public PHP error output.
- WordPress cron runs every five minutes using system cron. Log rotation keeps eight weekly archives.
- HTTPS with automatic certificate renewal through `certbot.timer`. Confirm renewal with `sudo certbot renew --dry-run` once DNS and ports are ready.
- Official WordPress downloads with core checksum verification. WP-CLI downloads and its signature are verified using the key fetched from the official WP-CLI build repository over HTTPS. This does not provide an independently pinned signing-key trust anchor.

Installed files:

```text
/opt/zywp/                           Root-owned runtime and templates
/usr/local/bin/zywp                  CLI symlink
/etc/zywp/site.conf                  Root-only managed site metadata (0600)
/var/www/zywp/public/                WordPress files
/etc/nginx/sites-available/zywp.conf  Managed Nginx site
/etc/nginx/zywp/                     Shared managed Nginx rules
/etc/php/<version>/fpm/pool.d/zywp.conf
/etc/php/<version>/fpm/conf.d/99-zywp.ini
/etc/mysql/mariadb.conf.d/60-zywp.cnf
/var/log/zywp/                       PHP and WordPress cron logs
/var/backups/zywp/                   Private backups
```

FPM runs as the owner of WordPress so dashboard updates/uploads work. This also means compromised PHP can modify the site's files. Keep WordPress, plugins, themes and OS packages updated, use trusted plugins and keep off-server backups. The script does not silently upgrade or remove unrelated databases, replace all system configuration, or install a collection of WordPress plugins.

## Reinstallation and recovery

Option 2 asks for explicit confirmation. It backs up managed WordPress files, database, site metadata, Nginx virtual host, PHP-FPM settings, managed database/cron/logrotate settings and Let's Encrypt configuration before replacing the site. Backup failure stops the operation. It preserves the previous files under `/var/www/zywp/previous-*` and the old database/user; the fresh installation gets a new random database and database password. Existing content is not imported into the new site.

Backups contain credentials and TLS private keys: directory permissions are 0700. Copy them securely off-server. They are manual backups, not a disaster recovery service. File and SQL snapshots are taken separately; for a busy shop or site, stop writes before backup to ensure application-level consistency. A corrupt or unavailable database can prevent safe automatic backup/reinstallation; recover it manually rather than skipping backup.

There is no automatic rollback command in version 0.1.0. To recover on the same server, an administrator should:

1. Preserve the current site with `sudo zywp backup` if it is healthy. Select the desired dated backup under `/var/backups/zywp/`.
2. Stop Nginx, the managed PHP-FPM service and temporarily pause `/etc/cron.d/zywp` so nothing writes during restoration.
3. Move the current `public` directory aside; extract `wordpress.tar.gz` into `/var/www/zywp/`. The archive includes the `public` directory and its original permissions. Keep `wp-config.php` private.
4. Read the backed-up metadata and restore `database.sql.gz` into its original database, which the reinstall retains. On a different server, create the original database/user with the credentials in the restored `wp-config.php` before importing.
5. Restore the backed-up `site.conf` to `/etc/zywp/site.conf` with root ownership and mode 0600, and the virtual host to `/etc/nginx/sites-available/zywp.conf`. Ensure its enabled symlink exists. Restore `tls.tar.gz` under `/etc` if needed and keep private-key permissions intact.
6. Inspect and selectively restore the settings in `configuration.tar.gz` under `/etc` so PHP version/pool/overrides, Nginx rules and cron match the restored site. Run `nginx -t` and the corresponding `php-fpm<version> -t`, start the services and re-enable the cron entry. Run `sudo zywp doctor`, check the site and test certificate renewal.

If installation stops midway, metadata records the `installing` phase. Fix the reported cause, then use the reinstall option to back up and retry. Package/configuration changes are not an atomic transaction. Don't remove old files/databases until recovery has been checked.

## Development checks

On Linux with Bash, Python 3 and ShellCheck:

```bash
bash tests/run.sh
# With Nginx and PHP-FPM installed:
sudo bash tests/run.sh --config
```

GitHub Actions runs syntax/lint checks, real terminal prompt validation and native Nginx/PHP-FPM template validation on Ubuntu 24.04. These checks do not perform a complete WordPress installation or obtain a real certificate.

## References

Configuration decisions are based on these official sources:

- [WordPress requirements](https://wordpress.org/about/requirements/)
- [WordPress on Nginx](https://developer.wordpress.org/advanced-administration/server/web-server/nginx/)
- [Hardening WordPress](https://developer.wordpress.org/advanced-administration/security/hardening/)
- [WP-CLI installation and download verification](https://make.wordpress.org/cli/handbook/guides/installing/)
- [Nginx FastCGI module](https://nginx.org/en/docs/http/ngx_http_fastcgi_module.html)
- [Nginx gzip module and compression side-channel notice](https://nginx.org/en/docs/http/ngx_http_gzip_module.html)
- [PHP supported versions](https://www.php.net/supported-versions.php)
- [MariaDB secure installation and Unix socket authentication](https://mariadb.com/docs/server/clients-and-utilities/deployment-tools/mariadb-secure-installation)
- [Certbot](https://certbot.eff.org/)

## Support development

ZYWP is a Zynkria project. Donations help support its development:

**[Donate via PayPal — paypal.me/zynkria](https://paypal.me/zynkria)**

Licensed under the MIT license. Provided without warranty; review and test it for your server.
