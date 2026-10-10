"""Exercise real terminal prompts without touching packages or services."""
import errno
import os
import pathlib
import pty
import select
import signal
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def collect(url, username="owner", email="owner@example.com", title="My Website"):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvp("bash", ["bash", "-c", '''
source ./install.sh
read_password() { PASSWORD=not-a-real-password; }
confirm() { return 0; }
collect_site
printf '\\nRESULT:%s|%s|%s\\n' "$URL" "$DOMAIN" "$TITLE"
'''])
    values = [url, title, username, email]
    prompts = [b"URL (", b"Website name:", b"Administrator username:", b"Administrator email:"]
    output = b""
    pending = b""
    deadline = time.monotonic() + 10
    index = 0
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.2)[0]:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output += chunk
                pending += chunk
                if index < len(prompts) and prompts[index] in pending:
                    os.write(fd, (values[index] + "\n").encode())
                    index += 1
                    pending = b""
        else:
            os.kill(pid, signal.SIGKILL)
            raise AssertionError("Prompt timed out")
        _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status), output.decode(errors="replace")
    finally:
        os.close(fd)


class InputTests(unittest.TestCase):
    def test_valid_https_normalizes_domain_and_slash(self):
        status, output = collect("https://BLOG.Example.com/")
        self.assertEqual(status, 0, output)
        self.assertIn("RESULT:https://blog.example.com|blog.example.com|My Website", output)

    def test_valid_http(self):
        status, output = collect("http://example.org")
        self.assertEqual(status, 0, output)

    def test_rejects_injection_and_unsupported_urls(self):
        for url in ["https://example.com;id", "https://example.com/abc", "https://example.com:443",
                    "https://127.0.0.1", "https://-bad.example.com", "https://a..com",
                    "ftp://example.com", "https://user@example.com", "https://" + "a" * 64 + ".com"]:
            with self.subTest(url=url):
                status, output = collect(url)
                self.assertNotEqual(status, 0, output)
                self.assertIn("Error:", output)

    def test_rejects_invalid_user_and_email(self):
        self.assertNotEqual(collect("https://example.com", username="--admin")[0], 0)
        self.assertNotEqual(collect("https://example.com", email="bad email")[0], 0)

    def test_title_is_treated_as_data(self):
        status, output = collect("https://example.com", title="Site ' $(touch /tmp/zywp-injection-test)")
        self.assertEqual(status, 0, output)
        self.assertFalse(pathlib.Path("/tmp/zywp-injection-test").exists())


if __name__ == "__main__":
    unittest.main()
