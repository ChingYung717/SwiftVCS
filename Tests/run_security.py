"""Exercise credential and certificate boundaries against temporary loopback services."""
import base64
import contextlib
import http.server
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading

binary = str(Path(sys.argv[1]).resolve())
user = "loopback-audit"
password = "fixture-only"
basic = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


@contextlib.contextmanager
def endpoint(cert=None, key=None):
    hits = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def __getattr__(self, name):
            if name.startswith("do_"):
                return self.reply
            raise AttributeError(name)

        def reply(self):
            authorized = self.headers.get("Authorization") == basic
            hits.append((self.command, authorized))
            self.send_response(403 if authorized else 401)
            if not authorized:
                self.send_header("WWW-Authenticate", 'Basic realm="fixture"')
            self.send_header("Content-Length", "0")
            self.end_headers()

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        if cert:
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(cert, key)
            server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        scheme = "https" if cert else "http"
        try:
            yield f"{scheme}://localhost:{server.server_port}/repo", hits
        finally:
            server.shutdown()
            thread.join()


def run(env, *args):
    return subprocess.run([binary, "info", *args], env=env, capture_output=True, text=True, timeout=25)


with tempfile.TemporaryDirectory(prefix="swiftvcs-security-") as temp:
    root = Path(temp)
    home = root / "home"
    config = home / ".config" / "vcs-explorer"
    config.mkdir(parents=True)
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
    cert, key = root / "server.crt", root / "server.key"
    conf = root / "openssl.cnf"
    conf.write_text(
        "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
        "[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\n"
    )
    subprocess.run(
        ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-config", str(conf), "-days", "1", "-keyout", str(key), "-out", str(cert)],
        check=True, capture_output=True,
    )

    # Existing unscoped plaintext entries must never be automatically reused.
    legacy = config / "credentials.json"
    legacy.write_text(f'{{"localhost|{user}":"{password}"}}')
    with endpoint() as (url, hits):
        result = run(env, url, "--user", user)
        assert result.returncode != 0 and hits == [("OPTIONS", False)], (result.stderr, hits)

    pins = config / "pinned-certs"
    with endpoint(cert, key) as (url, hits):
        result = run(env, url, "--fetch-cert", "localhost")
        assert result.returncode == 0 and not list(pins.glob("*.crt")), result.stderr
        fingerprint = re.search(r"SHA-256: ([0-9A-F:]+)", result.stdout).group(1)

        result = run(env, url, "--fetch-cert", "localhost", "--fingerprint", "00" * 32)
        assert result.returncode != 0 and not list(pins.glob("*.crt")), result.stderr

        result = run(env, url, "--fetch-cert", "localhost", "--fingerprint", fingerprint,
                     "--user", user, "--password", password, "--remember")
        assert result.returncode != 0 and any(authorized for _, authorized in hits), (result.stderr, hits)
        assert "已存入" not in result.stdout
        assert len(list(pins.glob("*.crt"))) == 1

        with endpoint(cert, key) as (other_url, other_hits):
            result = run(env, other_url, "--user", user, "--password", password)
            assert result.returncode != 0 and not other_hits, (result.stderr, other_hits)

    # A merge into a file:// working copy must reject an HTTP source before issuing requests.
    admin = shutil.which("svnadmin")
    svn = shutil.which("svn")
    assert admin and svn, "svnadmin and svn are required for the isolated merge test"
    repository = root / "repository"
    working = root / "working"
    subprocess.run([admin, "create", str(repository)], env=env, check=True, capture_output=True)
    subprocess.run([svn, "checkout", repository.as_uri(), str(working)],
                   env=env, check=True, capture_output=True)
    with endpoint() as (url, hits):
        result = subprocess.run(
            [binary, "merge", str(working), "--source", url, "--revision", "1", "--dry-run"],
            env=env, capture_output=True, text=True, timeout=25,
        )
        assert result.returncode == 1 and not hits, (result.stderr, hits)
        assert "同一 SVN 端点" in result.stderr

print("Loopback security checks passed")
