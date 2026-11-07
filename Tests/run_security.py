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
loopback = "127.0.0.1"
user = "loopback-audit"
password = "fixture-only"
basic = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


class ReusableThreadingHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True


@contextlib.contextmanager
def endpoint(cert=None, key=None, port=0):
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

    with ReusableThreadingHTTPServer((loopback, port), Handler) as server:
        if cert:
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(cert, key)
            server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        scheme = "https" if cert else "http"
        try:
            yield f"{scheme}://{loopback}:{server.server_port}/repo", hits
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
        f"[dn]\nCN={loopback}\n[ext]\nsubjectAltName=IP:{loopback}\n"
    )
    subprocess.run(
        ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-config", str(conf), "-days", "1", "-keyout", str(key), "-out", str(cert)],
        check=True, capture_output=True,
    )

    # Existing unscoped plaintext entries must never be automatically reused.
    legacy = config / "credentials.json"
    legacy.write_text(f'{{"{loopback}|{user}":"{password}"}}')
    with endpoint() as (url, hits):
        result = run(env, url, "--user", user)
        assert result.returncode != 0 and hits == [("OPTIONS", False)], (result.stderr, hits)

    pins = config / "pinned-certs"
    with endpoint(cert, key) as (url, hits):
        saved_port = int(re.search(r":(\d+)/repo$", url).group(1))
        result = run(env, url, "--fetch-cert", loopback)
        assert result.returncode == 0 and not list(pins.glob("*.crt")), result.stderr
        fingerprint = re.search(r"SHA-256: ([0-9A-F:]+)", result.stdout).group(1)

        result = run(env, url, "--fetch-cert", loopback, "--fingerprint", "00" * 32)
        assert result.returncode != 0 and not list(pins.glob("*.crt")), result.stderr

        result = run(env, url, "--fetch-cert", loopback, "--fingerprint", fingerprint,
                     "--user", user, "--password", password, "--remember")
        assert result.returncode != 0 and any(authorized for _, authorized in hits), (result.stderr, hits)
        assert "已存入" not in result.stdout
        assert len(list(pins.glob("*.crt"))) == 1

        with endpoint(cert, key) as (other_url, other_hits):
            result = run(env, other_url, "--user", user, "--password", password)
            assert result.returncode != 0 and not other_hits, (result.stderr, other_hits)

    # SV-02 same host:port replaced self-signed certificate must be rejected without sending credentials.
    other_self_cert, other_self_key = root / "other_self.crt", root / "other_self.key"
    subprocess.run(
        ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-config", str(conf), "-days", "1", "-keyout", str(other_self_key), "-out", str(other_self_cert)],
        check=True, capture_output=True,
    )
    with endpoint(other_self_cert, other_self_key, port=saved_port) as (same_url, hits):
        result = run(env, same_url, "--user", user, "--password", password)
        assert result.returncode != 0 and not hits, (result.stderr, hits)

    # SV-02a: Hostname mismatch must STILL be rejected even after importing leaf certificate fingerprint.
    mismatch_cert, mismatch_key = root / "mismatch.crt", root / "mismatch.key"
    mismatch_conf = root / "mismatch.cnf"
    mismatch_conf.write_text(
        "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
        "[dn]\nCN=wrong.example.test\n[ext]\nsubjectAltName=DNS:wrong.example.test\n"
    )
    subprocess.run(
        ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-config", str(mismatch_conf), "-days", "1",
         "-keyout", str(mismatch_key), "-out", str(mismatch_cert)],
        check=True, capture_output=True,
    )
    with endpoint(mismatch_cert, mismatch_key) as (url, hits):
        probe = run(env, url, "--fetch-cert", loopback)
        assert probe.returncode == 0, probe.stderr
        mismatch_fp = re.search(r"SHA-256: ([0-9A-F:]+)", probe.stdout).group(1)
        result = run(env, url, "--fetch-cert", loopback, "--fingerprint", mismatch_fp,
                     "--user", user, "--password", password)
        assert result.returncode != 0 and not hits, (result.stderr, hits)

    # SV-02b: Expired and not-yet-valid certificates must be rejected even after importing fingerprint.
    ca_dir = root / "demoCA"
    (ca_dir / "newcerts").mkdir(parents=True)
    (ca_dir / "index.txt").write_text("")
    (ca_dir / "serial").write_text("01\n")
    ca_ops_conf = root / "ca_ops.cnf"
    ca_ops_conf.write_text(
        f"[ca]\ndefault_ca = CA_default\n[CA_default]\ndir = {ca_dir}\n"
        "database = $dir/index.txt\nnew_certs_dir = $dir/newcerts\nserial = $dir/serial\n"
        "default_md = sha256\npolicy = policy_anything\nx509_extensions = v3_leaf\n"
        "unique_subject = no\n[policy_anything]\ncommonName = supplied\n"
        "[req]\ndistinguished_name = dn\nprompt = no\n"
        f"[dn]\nCN = {loopback}\n[v3_leaf]\nsubjectAltName = IP:{loopback}\nbasicConstraints = CA:FALSE\n"
    )
    exp_cert, exp_key, exp_csr = root / "expired.crt", root / "expired.key", root / "expired.csr"
    subprocess.run(
        ["/usr/bin/openssl", "req", "-newkey", "rsa:2048", "-nodes",
         "-config", str(ca_ops_conf), "-keyout", str(exp_key), "-out", str(exp_csr)],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["/usr/bin/openssl", "ca", "-batch", "-notext", "-config", str(ca_ops_conf),
         "-keyfile", str(exp_key), "-in", str(exp_csr), "-out", str(exp_cert),
         "-startdate", "200101000000Z", "-enddate", "200102000000Z", "-selfsign"],
        check=True, capture_output=True,
    )
    with endpoint(exp_cert, exp_key) as (url, hits):
        probe = run(env, url, "--fetch-cert", loopback)
        assert probe.returncode == 0, probe.stderr
        exp_fp = re.search(r"SHA-256: ([0-9A-F:]+)", probe.stdout).group(1)
        result = run(env, url, "--fetch-cert", loopback, "--fingerprint", exp_fp,
                     "--user", user, "--password", password)
        assert result.returncode != 0 and not hits, (result.stderr, hits)

    future_cert, future_key, future_csr = root / "future.crt", root / "future.key", root / "future.csr"
    subprocess.run(
        ["/usr/bin/openssl", "req", "-newkey", "rsa:2048", "-nodes",
         "-config", str(ca_ops_conf), "-keyout", str(future_key), "-out", str(future_csr)],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["/usr/bin/openssl", "ca", "-batch", "-notext", "-config", str(ca_ops_conf),
         "-keyfile", str(future_key), "-in", str(future_csr), "-out", str(future_cert),
         "-startdate", "350101000000Z", "-enddate", "350102000000Z", "-selfsign"],
        check=True, capture_output=True,
    )
    with endpoint(future_cert, future_key) as (url, hits):
        probe = run(env, url, "--fetch-cert", loopback)
        assert probe.returncode == 0, probe.stderr
        future_fp = re.search(r"SHA-256: ([0-9A-F:]+)", probe.stdout).group(1)
        result = run(env, url, "--fetch-cert", loopback, "--fingerprint", future_fp,
                     "--user", user, "--password", password)
        assert result.returncode != 0 and not hits, (result.stderr, hits)

    # SV-02c & SV-12: --ca, --trust-bundle, and --password-stdin verification
    # (including on the same host:port where a different self-signed exception cert is saved:
    #  CA-valid certificate different from the exception certificate is allowed under the trust-exception model).
    ca_cert, ca_key = root / "ca.crt", root / "ca.key"
    wrong_ca_cert, wrong_ca_key = root / "wrong_ca.crt", root / "wrong_ca.key"
    ca_root_conf = root / "ca_root.cnf"
    ca_root_conf.write_text(
        "[req]\ndistinguished_name=dn\nx509_extensions=v3_ca\nprompt=no\n"
        "[dn]\nCN=SwiftVCS Test CA\n[v3_ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
    )
    subprocess.run(
        ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-config", str(ca_root_conf), "-days", "2", "-keyout", str(ca_key), "-out", str(ca_cert)],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-config", str(ca_root_conf), "-days", "2", "-keyout", str(wrong_ca_key), "-out", str(wrong_ca_cert)],
        check=True, capture_output=True,
    )
    leaf_cert, leaf_key, leaf_csr = root / "leaf.crt", root / "leaf.key", root / "leaf.csr"
    subprocess.run(
        ["/usr/bin/openssl", "req", "-newkey", "rsa:2048", "-nodes",
         "-config", str(ca_ops_conf), "-keyout", str(leaf_key), "-out", str(leaf_csr)],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["/usr/bin/openssl", "ca", "-batch", "-notext", "-config", str(ca_ops_conf),
         "-cert", str(ca_cert), "-keyfile", str(ca_key),
         "-in", str(leaf_csr), "-out", str(leaf_cert), "-days", "1"],
        check=True, capture_output=True,
    )
    with endpoint(leaf_cert, leaf_key, port=saved_port) as (url, hits):
        # Untrusted without --ca / --trust-bundle (differs from saved self-signed exception cert on saved_port)
        result = run(env, url, "--user", user, "--password", password)
        assert result.returncode != 0 and not hits, (result.stderr, hits)

        # Wrong CA rejected
        result = run(env, url, "--ca", str(wrong_ca_cert), "--user", user, "--password", password)
        assert result.returncode != 0 and not hits, (result.stderr, hits)

        # --ca accepted on saved_port even though leaf_cert != saved self-signed exception cert
        result = run(env, url, "--ca", str(ca_cert), "--user", user, "--password", password)
        assert any(authorized for _, authorized in hits), (result.stderr, hits)
        hits.clear()

        # --trust-bundle accepted + --password-stdin works on saved_port
        stdin_res = subprocess.run(
            [binary, "info", url, "--trust-bundle", str(ca_cert), "--user", user, "--password-stdin"],
            env=env, input=password + "\n", capture_output=True, text=True, timeout=25,
        )
        assert any(authorized for _, authorized in hits), (stdin_res.stderr, hits)

        # Combining --password and --password-stdin must be rejected before connecting
        hits.clear()
        both_res = subprocess.run(
            [binary, "info", url, "--ca", str(ca_cert), "--user", user,
             "--password", password, "--password-stdin"],
            env=env, input=password + "\n", capture_output=True, text=True, timeout=25,
        )
        assert both_res.returncode != 0 and not hits, (both_res.stderr, hits)

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
