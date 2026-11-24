"""Exercise credential and certificate boundaries against temporary loopback services."""
import base64
import contextlib
import http.server
import os
from pathlib import Path
import pty
import re
import select
import shutil
import sqlite3
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

    # S-01: --ca MUST be scoped strictly to the target host (never [global]);
    # an HTTP 301 redirect from 127.0.0.1 to localhost must NOT trust the same private CA on localhost.
    localhost_conf = root / "localhost-ops.cnf"
    localhost_conf.write_text(
        "[ca]\ndefault_ca=myca\n"
        "[myca]\n"
        f"new_certs_dir={ca_dir}\ndatabase={ca_dir / 'index.txt'}\nserial={ca_dir / 'serial'}\n"
        "default_md=sha256\npolicy=pol\nx509_extensions=v3_leaf\n"
        "[pol]\ncommonName=supplied\n"
        "[req]\ndistinguished_name=dn\nprompt=no\n"
        "[dn]\nCN=localhost\n"
        "[v3_leaf]\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n"
    )
    lh_cert, lh_key, lh_csr = root / "localhost.crt", root / "localhost.key", root / "localhost.csr"
    subprocess.run(
        ["/usr/bin/openssl", "req", "-newkey", "rsa:2048", "-nodes",
         "-config", str(localhost_conf), "-keyout", str(lh_key), "-out", str(lh_csr)],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["/usr/bin/openssl", "ca", "-batch", "-notext", "-config", str(localhost_conf),
         "-cert", str(ca_cert), "-keyfile", str(ca_key),
         "-in", str(lh_csr), "-out", str(lh_cert), "-days", "1"],
        check=True, capture_output=True,
    )
    with endpoint(lh_cert, lh_key) as (lh_url, lh_hits):
        target_loc = lh_url.replace("127.0.0.1", "localhost")
        redir_hits = []

        class RedirectHandler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def __getattr__(self, name):
                if name.startswith("do_"):
                    return self.reply
                raise AttributeError(name)

            def reply(self):
                redir_hits.append(self.command)
                self.send_response(301)
                self.send_header("Location", target_loc)
                self.send_header("Content-Length", "0")
                self.end_headers()

        with ReusableThreadingHTTPServer((loopback, 0), RedirectHandler) as redir_srv:
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(leaf_cert, leaf_key)
            redir_srv.socket = tls.wrap_socket(redir_srv.socket, server_side=True)
            t = threading.Thread(target=redir_srv.serve_forever, daemon=True)
            t.start()
            try:
                redir_url = f"https://{loopback}:{redir_srv.server_port}/repo"
                for subcmd in (["log", redir_url], ["proplist", redir_url]):
                    redir_hits.clear()
                    lh_hits.clear()
                    res = subprocess.run(
                        [binary, *subcmd, "--ca", str(ca_cert), "--user", user, "--password-stdin"],
                        env=env, input=password + "\n", capture_output=True, text=True, timeout=25,
                    )
                    assert res.returncode != 0, (subcmd, res.stdout, res.stderr)
                    assert redir_hits, (subcmd, "expected initial request to 127.0.0.1")
                    assert not lh_hits, (subcmd, "private --ca leaked across 301 redirect to localhost!", lh_hits)
            finally:
                redir_srv.shutdown()
                t.join()

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

    # SV-V01: Pre-existing wildcard [groups] and poisoned [__swiftvcs_scoped_ca__] in ~/.subversion/servers
    # must NEVER break --ca host scoping or allow %(...)s config interpolation.
    svn_cfg_dir = home / ".subversion"
    svn_cfg_dir.mkdir(parents=True, exist_ok=True)
    (svn_cfg_dir / "servers").write_text(
        "[groups]\n"
        "all = *\n"
        "wild_loopback = 127.*, localhost\n"
        "__swiftvcs_scoped_ca__ = 127.0.0.1\n\n"
        "[__swiftvcs_scoped_ca__]\n"
        "ssl-authority-files = /nonexistent/poison.pem\n\n"
        "[all]\n"
        "http-timeout = 30\n"
    )
    with endpoint(leaf_cert, leaf_key) as (url, hits):
        # Reject %(...)s interpolation in --ca path before connecting, with non-empty descriptive error
        pct_ca = root / "%(http-proxy-password)s.pem"
        pct_ca.write_bytes(ca_cert.read_bytes())
        pct_res = run(env, url, "--ca", str(pct_ca), "--user", user, "--password", password)
        assert pct_res.returncode != 0 and not hits, (pct_res.stderr, hits)
        assert "CA" in pct_res.stderr or "非法" in pct_res.stderr, pct_res.stderr

        # Repeated runs verify deterministic scoping regardless of apr_hash_t seed
        for _ in range(5):
            hits.clear()
            ok_res = run(env, url, "--ca", str(ca_cert), "--user", user, "--password", password)
            assert any(authorized for _, authorized in hits), (ok_res.stderr, hits)

        # SV-V01 Round-2: Uppercase __SWIFTVCS_SCOPED_CA__ in ~/.subversion/servers must NOT break --ca scoping
        (svn_cfg_dir / "servers").write_text(
            "[groups]\n"
            "all = *\n"
            "__SWIFTVCS_SCOPED_CA__ = 127.0.0.1\n\n"
            "[__SWIFTVCS_SCOPED_CA__]\n"
            "ssl-authority-files = /nonexistent/poison-upper.pem\n"
        )
        hits.clear()
        upper_res = run(env, url, "--ca", str(ca_cert), "--user", user, "--password", password)
        assert any(authorized for _, authorized in hits), (upper_res.stderr, hits)

    # SV-V04: Poisoned replaced node in .svn/wc.db pointing to rogue loopback URL must NEVER trigger outbound HTTP
    ssrf_doc = working / "ssrf_doc.txt"
    ssrf_doc.write_text("v1\n")
    subprocess.run([svn, "add", str(ssrf_doc)], env=env, check=True, capture_output=True)
    subprocess.run([svn, "propset", "k", "v", str(ssrf_doc)], env=env, check=True, capture_output=True)
    subprocess.run([svn, "commit", str(working), "-m", "add doc"], env=env, check=True, capture_output=True)
    subprocess.run([svn, "update", str(working)], env=env, check=True, capture_output=True)
    subprocess.run([svn, "delete", str(ssrf_doc)], env=env, check=True, capture_output=True)
    ssrf_doc.write_text("replaced\n")
    subprocess.run([svn, "add", str(ssrf_doc)], env=env, check=True, capture_output=True)
    with endpoint() as (rogue_url, rogue_hits):
        wc_db = working / ".svn" / "wc.db"
        conn = sqlite3.connect(str(wc_db))
        try:
            conn.execute(
                "INSERT INTO REPOSITORY (id, root, uuid) VALUES (2, ?, '00000000-0000-0000-0000-000000000000')",
                (rogue_url,),
            )
            conn.execute(
                "UPDATE NODES SET repos_id = 2 WHERE local_relpath = 'ssrf_doc.txt' AND op_depth = 0"
            )
            conn.commit()
        finally:
            conn.close()
        diff_res = subprocess.run(
            [binary, "diff", str(working), "ssrf_doc.txt"],
            env=env, capture_output=True, text=True, timeout=25,
        )
        assert diff_res.returncode == 0, (diff_res.stdout, diff_res.stderr)
        assert not rogue_hits, f"SV-V04 regression: passive SSRF hit {rogue_hits}"

    # SV-V04 Round-2 (P0): Poisoning REPOSITORY id=1 ITSELF to an HTTP URL on a replaced WC must NEVER
    # trigger outbound HTTP during default offline `vcsctl diff <wc>`.
    ssrf_wc1 = root / "ssrf-id1-wc"
    subprocess.run([svn, "checkout", repository.as_uri(), str(ssrf_wc1)],
                   env=env, check=True, capture_output=True)
    ssrf_doc1 = ssrf_wc1 / "ssrf_doc.txt"
    subprocess.run([svn, "delete", str(ssrf_doc1)], env=env, check=True, capture_output=True)
    ssrf_doc1.write_text("replaced id1\n")
    subprocess.run([svn, "add", str(ssrf_doc1)], env=env, check=True, capture_output=True)
    with endpoint() as (rogue_id1_url, rogue_id1_hits):
        wc_db1 = ssrf_wc1 / ".svn" / "wc.db"
        conn = sqlite3.connect(str(wc_db1))
        try:
            conn.execute("UPDATE REPOSITORY SET root = ? WHERE id = 1", (rogue_id1_url,))
            conn.commit()
        finally:
            conn.close()
        diff_id1 = subprocess.run(
            [binary, "diff", str(ssrf_wc1), "ssrf_doc.txt"],
            env=env, capture_output=True, text=True, timeout=25,
        )
        assert diff_id1.returncode == 0, (diff_id1.stdout, diff_id1.stderr)
        assert not rogue_id1_hits, f"SV-V04 P0 regression: vcsctl diff hit REPOSITORY id=1 {rogue_id1_hits}"

    # SV-V09 Round-2: Poisoned invalid WC URL (svn+ssh option injection or file://host) must fail closed on update/log
    for bad_wc_url in (
        "svn+ssh://-oProxyCommand=id@127.0.0.1/repo",
        "file://evil.host/tmp/repo",
        "file://:1234/tmp/repo",
    ):
        bad_wc = root / f"bad-wc-{abs(hash(bad_wc_url))}"
        subprocess.run([svn, "checkout", repository.as_uri(), str(bad_wc)],
                       env=env, check=True, capture_output=True)
        conn = sqlite3.connect(str(bad_wc / ".svn" / "wc.db"))
        try:
            conn.execute("UPDATE REPOSITORY SET root = ? WHERE id = 1", (bad_wc_url,))
            conn.commit()
        finally:
            conn.close()
        for subcmd in (["update", str(bad_wc)], ["log", str(bad_wc), "--limit", "1"]):
            res = subprocess.run([binary, *subcmd], env=env, capture_output=True, text=True, timeout=25)
            assert res.returncode != 0, (bad_wc_url, subcmd, res.stdout, res.stderr)
            assert "非法" in res.stderr, (bad_wc_url, subcmd, res.stderr)

    # SV-V02 Round-2: `vcsctl add <wc>` allows ignored symlinks & declared svn:externals subdirs, blocks unignored symlinks
    svv02_wc = root / "svv02-wc"
    subprocess.run([svn, "checkout", repository.as_uri(), str(svv02_wc)],
                   env=env, check=True, capture_output=True)
    subprocess.run([svn, "propset", "svn:ignore", "node_modules\n", str(svv02_wc)],
                   env=env, check=True, capture_output=True)
    subprocess.run([svn, "propset", "svn:externals", f"{repository.as_uri()} ext_sub\n", str(svv02_wc)],
                   env=env, check=True, capture_output=True)
    subprocess.run([svn, "update", str(svv02_wc)], env=env, check=True, capture_output=True)
    assert (svv02_wc / "ext_sub" / ".svn").is_dir()
    nm = svv02_wc / "node_modules"
    nm.mkdir()
    (nm / "binlink").symlink_to("/etc/hosts")
    legit_new = svv02_wc / "legit_new.txt"
    legit_new.write_text("ok\n")
    add_ok = subprocess.run([binary, "add", str(svv02_wc)], env=env, capture_output=True, text=True, timeout=25)
    assert add_ok.returncode == 0, (add_ok.stdout, add_ok.stderr)
    # Unignored symlink must still be rejected
    bad_link = svv02_wc / "unignored_bad_link"
    bad_link.symlink_to("/etc/hosts")
    add_bad = subprocess.run([binary, "add", str(svv02_wc)], env=env, capture_output=True, text=True, timeout=25)
    assert add_bad.returncode != 0, (add_bad.stdout, add_bad.stderr)
    bad_link.unlink()

    # SV-V02 Round-2b: Unpopulated or spoofed-empty-.svn svn:externals targets MUST NOT bypass validation
    subprocess.run(
        [svn, "propset", "svn:externals",
         f"{repository.as_uri()} ext_sub\n{repository.as_uri()} fake_ext\n{repository.as_uri()} fake_ext2\n",
         str(svv02_wc)],
        env=env, check=True, capture_output=True,
    )
    fake_ext = svv02_wc / "fake_ext"
    fake_ext.mkdir()
    (fake_ext / "evil_link").symlink_to("/etc/hosts")
    add_fake1 = subprocess.run([binary, "add", str(svv02_wc)], env=env, capture_output=True, text=True, timeout=25)
    assert add_fake1.returncode != 0, (add_fake1.stdout, add_fake1.stderr)
    st_fake1 = subprocess.run([svn, "status", str(fake_ext)], env=env, capture_output=True, text=True, check=True).stdout
    assert not st_fake1.startswith("A"), st_fake1
    shutil.rmtree(fake_ext)

    fake_ext2 = svv02_wc / "fake_ext2"
    (fake_ext2 / ".svn").mkdir(parents=True)
    (fake_ext2 / "sub").mkdir()
    (fake_ext2 / "sub" / "evil_link2").symlink_to("/etc/hosts")
    add_fake2 = subprocess.run([binary, "add", str(svv02_wc)], env=env, capture_output=True, text=True, timeout=25)
    assert add_fake2.returncode != 0, (add_fake2.stdout, add_fake2.stderr)
    st_fake2 = subprocess.run([svn, "status", str(fake_ext2)], env=env, capture_output=True, text=True, check=True).stdout
    assert not st_fake2.startswith("A"), st_fake2
    shutil.rmtree(fake_ext2)

    # SV-V03 Round-2: `vcsctl propset --file` rejects symlinks and FIFOs without hanging
    sym_prop_file = root / "sym-prop-val"
    sym_prop_file.symlink_to("/etc/hosts")
    sym_ps = subprocess.run(
        [binary, "propset", str(svv02_wc), "user:test", "--file", str(sym_prop_file)],
        env=env, capture_output=True, text=True, timeout=15,
    )
    assert sym_ps.returncode != 0, (sym_ps.stdout, sym_ps.stderr)
    fifo_prop_file = root / "fifo-prop-val"
    os.mkfifo(fifo_prop_file)
    fifo_ps = subprocess.run(
        [binary, "propset", str(svv02_wc), "user:test", "--file", str(fifo_prop_file)],
        env=env, capture_output=True, text=True, timeout=15,
    )
    assert fifo_ps.returncode != 0, (fifo_ps.stdout, fifo_ps.stderr)

    # SV-V08: When stdout/stderr is a TTY, vcsctl escapes ANSI/OSC, 8-bit C1, CR, and Unicode Bidi/LS/PS; vcsctl cat remains raw.
    ansi_wc = root / "ansi-wc"
    subprocess.run([svn, "checkout", repository.as_uri(), str(ansi_wc)],
                   env=env, check=True, capture_output=True)
    ansi_file = ansi_wc / "ansi.txt"
    ansi_payload = b"\x1b[32mRAW_CAT\x1b[0m\n"
    ansi_file.write_bytes(ansi_payload)
    subprocess.run([svn, "add", str(ansi_file)], env=env, check=True, capture_output=True)
    bidi_and_c1_msg = "msg \x1b[31mRED\x1b[0m \x1b]52;c;AAAA\x07 \u009b31mC1 \u202eRLO\u2066LRI\u200fRLM\u061cALM\u2028LS\u2029PS"
    subprocess.run(
        [svn, "commit", str(ansi_wc), "-m", bidi_and_c1_msg],
        env=env, check=True, capture_output=True,
    )
    master_fd, slave_fd = pty.openpty()
    try:
        proc = subprocess.Popen(
            [binary, "log", str(ansi_wc), "--limit", "1"],
            env=env, stdin=subprocess.DEVNULL, stdout=slave_fd, stderr=slave_fd, close_fds=True,
        )
        os.close(slave_fd)
        slave_fd = -1
        tty_chunks = []
        while True:
            rlist, _, _ = select.select([master_fd], [], [], 10.0)
            if not rlist:
                break
            try:
                chunk = os.read(master_fd, 4096)
                if not chunk:
                    break
                tty_chunks.append(chunk)
            except OSError:
                break
        rc = proc.wait(timeout=15)
        tty_out = b"".join(tty_chunks)
        assert rc == 0, tty_out
        assert b"\x1b[" not in tty_out and b"\x1b]" not in tty_out and b"\x07" not in tty_out, tty_out
        assert "\u009b".encode() not in tty_out, tty_out
        assert "\u202e".encode() not in tty_out and "\u2066".encode() not in tty_out, tty_out
        assert "\u200f".encode() not in tty_out and "\u061c".encode() not in tty_out, tty_out
        assert "\u2028".encode() not in tty_out and "\u2029".encode() not in tty_out, tty_out
        assert b"\\x1B[31mRED\\x1B[0m" in tty_out and b"\\x1B]52;c;AAAA\\x07" in tty_out, tty_out
        assert b"\\x9B31mC1" in tty_out, tty_out
        assert b"\\u{202E}RLO\\u{2066}LRI\\u{200F}RLM\\u{061C}ALM\\u{2028}LS\\u{2029}PS" in tty_out, tty_out
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)

    # SV-V08 Round-2: CR (\r) in stdout (`propget`) and stderr (`die()`) on TTY are escaped as \x0D
    cr_prop_file = root / "cr-prop-val"
    cr_prop_file.write_bytes(b"line1\rOVERWRITE")
    subprocess.run(
        [binary, "propset", str(ansi_wc), "user:crtest", "--file", str(cr_prop_file)],
        env=env, check=True, capture_output=True,
    )
    master_fd, slave_fd = pty.openpty()
    try:
        proc = subprocess.Popen(
            [binary, "propget", str(ansi_wc), "user:crtest"],
            env=env, stdin=subprocess.DEVNULL, stdout=slave_fd, stderr=slave_fd, close_fds=True,
        )
        os.close(slave_fd)
        slave_fd = -1
        prop_chunks = []
        while True:
            rlist, _, _ = select.select([master_fd], [], [], 10.0)
            if not rlist:
                break
            try:
                chunk = os.read(master_fd, 4096)
                if not chunk:
                    break
                prop_chunks.append(chunk)
            except OSError:
                break
        rc = proc.wait(timeout=15)
        prop_tty = b"".join(prop_chunks)
        assert rc == 0, prop_tty
        assert b"line1\\x0DOVERWRITE" in prop_tty, prop_tty
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)

    # SV-V08 Round-2: stderr `die()` on TTY escapes Bidi, CR, and ANSI sequences too
    master_fd, slave_fd = pty.openpty()
    try:
        proc = subprocess.Popen(
            [binary, "unknown-\x1b[31m\r\u202ebad"],
            env=env, stdin=subprocess.DEVNULL, stdout=slave_fd, stderr=slave_fd, close_fds=True,
        )
        os.close(slave_fd)
        slave_fd = -1
        err_chunks = []
        while True:
            rlist, _, _ = select.select([master_fd], [], [], 10.0)
            if not rlist:
                break
            try:
                chunk = os.read(master_fd, 4096)
                if not chunk:
                    break
                err_chunks.append(chunk)
            except OSError:
                break
        rc = proc.wait(timeout=15)
        err_tty = b"".join(err_chunks)
        assert rc != 0
        assert b"\x1b[" not in err_tty and "\u202e".encode() not in err_tty, err_tty
        assert b"\\x1B[31m\\x0D\\u{202E}bad" in err_tty, err_tty
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)

    cat_res = subprocess.run(
        [binary, "cat", repository.as_uri(), "ansi.txt"],
        env=env, capture_output=True, timeout=25,
    )
    assert cat_res.returncode == 0 and cat_res.stdout == ansi_payload, (cat_res.returncode, cat_res.stdout)

print("Loopback security checks passed")
