"""Optional online check of the installer's official WP-CLI download endpoints."""
import pathlib
import subprocess
import tempfile
import urllib.request

base = "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/"
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="zywp-download-") as directory:
    temp = pathlib.Path(directory)
    keyring = temp / "gnupg"
    keyring.mkdir(mode=0o700)
    for remote, filename in [("phar/wp-cli.phar", "wp-cli.phar"),
                             ("phar/wp-cli.phar.asc", "wp-cli.phar.asc"),
                             ("wp-cli.pgp", "wp-cli.pgp")]:
        with urllib.request.urlopen(base + remote, timeout=60) as response:
            (temp / filename).write_bytes(response.read())
    subprocess.run(["gpg", "--homedir", str(keyring), "--batch", "--import", str(temp / "wp-cli.pgp")], check=True)
    subprocess.run(["bash", "-c", 'ZYWP_HOME=$PWD; source ./lib/common.sh; verify_wpcli "$1"',
                    "verify-download", str(temp)], cwd=root, check=True)
    subprocess.run(["php", str(temp / "wp-cli.phar"), "--info"], check=True)
