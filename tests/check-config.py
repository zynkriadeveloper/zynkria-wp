"""Render the shipped templates and validate them with installed server binaries."""
import glob
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="zywp-config-") as directory:
    temp = pathlib.Path(directory)
    (temp / "public").mkdir()
    site = (root / "nginx/templates/wordpress.conf").read_text()
    site = site.replace("@DOMAIN@", "example.org").replace("@WEBROOT@", str(temp / "public"))
    rules = temp / "rules.conf"
    rules.write_text((root / "nginx/templates/wordpress-rules.conf").read_text())
    site = site.replace("/etc/nginx/zywp/wordpress-rules.conf", str(rules))
    site = site.replace("/var/log/nginx/zywp-access.log", str(temp / "access.log"))
    site = site.replace("/var/log/nginx/zywp-error.log", str(temp / "error.log"))
    site = site.replace("include fastcgi_params", "include /etc/nginx/fastcgi_params")
    (temp / "site.conf").write_text(site)
    config = temp / "nginx.conf"
    config.write_text(f"pid {temp}/nginx.pid;\nerror_log {temp}/main-error.log;\nevents {{}}\nhttp {{ include {temp}/site.conf; }}\n")
    subprocess.run(["/usr/sbin/nginx", "-t", "-c", str(config)], check=True)
    pools = sorted(glob.glob("/usr/sbin/php-fpm8.*"))
    if not pools:
        raise SystemExit("PHP-FPM 8.x is required for configuration checks")
    pool = (root / "php/pool.conf").read_text().replace("@CHILDREN@", "2")
    # Use an existing account for syntax validation; the installer creates zywp.
    pool = pool.replace("user = zywp", "user = www-data").replace("group = zywp", "group = www-data")
    (temp / "pool.conf").write_text(pool)
    (temp / "fpm.conf").write_text(f"[global]\nerror_log = {temp}/fpm.log\ninclude={temp}/pool.conf\n")
    subprocess.run([pools[-1], "-t", "-y", str(temp / "fpm.conf"), "-c", str(root / "php/zywp.ini")], check=True)
print("Nginx and PHP-FPM templates passed native configuration validation.")
