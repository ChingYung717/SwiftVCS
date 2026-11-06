"""Offline node property and working-copy mkdir acceptance using native SVN as oracle."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

vcsctl = Path(sys.argv[1]).resolve()
bin_dir = Path(sys.argv[2]).resolve()


def check(argv, *, ok=True):
    proc = subprocess.run(list(map(str, argv)), capture_output=True, env=env, timeout=30)
    assert (proc.returncode == 0) == ok, (argv, proc.returncode, proc.stdout, proc.stderr)
    if not ok:
        assert proc.stderr, argv
    return proc


def native(tool, *args, ok=True):
    return check([bin_dir / tool, *args], ok=ok).stdout


def vcs(*args, ok=True):
    return check([vcsctl, *args], ok=ok)


with tempfile.TemporaryDirectory(prefix="swiftvcs-properties-") as temporary:
    base = Path(temporary).resolve()
    config = base / "config"
    config.mkdir()
    isolated_home = base / "home"
    isolated_home.mkdir()
    env = dict(os.environ, CFFIXED_USER_HOME=str(isolated_home))

    def svn(*args, ok=True):
        return native("svn", "--config-dir", config, *args, ok=ok)

    repo, wc = base / "repo", base / "wc"
    native("svnadmin", "create", repo)
    url = repo.as_uri()
    svn("checkout", url, wc)
    parent, child = wc / "parent", wc / "parent" / "child"
    child.mkdir(parents=True)
    file = child / "tracked.svnglobalfixture"
    file.write_text("tracked\n")
    svn("add", parent)
    svn("propset", "project:scope", "root", wc)
    svn("propset", "project:scope", "parent", parent)
    svn("propset", "project:history", "old", file)
    svn("propset", "svn:ignore", "*.local", parent)
    svn("propset", "svn:global-ignores", "*.svnglobalfixture", wc)
    svn("commit", wc, "-m", "fixture")
    svn("update", wc)

    path = "parent/child/tracked.svnglobalfixture"
    file_url = url + "/" + path
    at_file = ("--path", path)
    youngest = lambda: int(native("svnlook", "youngest", repo))
    assert youngest() == 1
    assert vcs("propget", file_url, "project:history", "--raw").stdout == b"old"
    assert vcs("propget", wc, "project:history", *at_file, "--raw").stdout == b"old"
    assert vcs("propget", wc, "project:missing", *at_file, "--raw", ok=False).stdout == b""
    assert vcs("proplist", wc, *at_file).stdout.count(b"project:scope") == 0
    inherited = vcs("proplist", wc, *at_file, "--inherited").stdout.decode().splitlines()
    url_inherited = vcs("proplist", file_url, "--inherited").stdout.decode().splitlines()
    for lines in (inherited, url_inherited):
        origins = [line.split("\t", 1)[1] for line in lines if line.startswith("project:scope\t")]
        assert len(origins) == len(set(origins)) == 2, lines
    oracle = svn("proplist", "--show-inherited-props", file)
    assert oracle.count(b"project:scope") == 2, oracle

    data = b"UTF-8\x00\xff\r\n"
    payload = base / "value.bin"
    payload.write_bytes(data)
    vcs("propset", wc, "project:blob", "--file", payload, *at_file)
    raw = vcs("propget", wc, "project:blob", *at_file, "--raw")
    assert raw.stdout == data and raw.stderr == b""
    assert svn("propget", "--strict", "project:blob", file) == data
    assert "二进制".encode() in vcs("propget", wc, "project:blob", *at_file).stdout
    vcs("propset", wc, "project:empty", "", *at_file)
    assert vcs("propget", wc, "project:empty", *at_file, "--raw").stdout == b""
    vcs("propdel", wc, "project:empty", *at_file)
    vcs("propget", wc, "project:empty", *at_file, "--raw", ok=False)

    vcs("propset", wc, "project:history", "new", *at_file)
    assert vcs("propget", wc, "project:history", *at_file, "--revision", 1, "--raw").stdout == b"old"
    vcs("propset", wc, "svn:mergeinfo", "/trunk:1", *at_file, ok=False)
    vcs("propdel", wc, "svn:global-ignores", ok=False)
    vcs("propset", wc, "svn:ignore", "invalid-on-file", *at_file, ok=False)
    vcs("propset", wc, "svn:eol-style", "nonsense", *at_file, ok=False)
    vcs("propset", wc, "svn:eol-style", "LF", *at_file)
    vcs("propset", wc, "svn:keywords", "Id", *at_file)
    vcs("propset", wc, "svn:mime-type", "text/plain", *at_file)
    vcs("propset", file_url, "project:history", "bad", ok=False)
    vcs("propget", file_url, "project:history", "--path", ".", ok=False)
    vcs("propget", wc, "project:history", "--revision", "-1", ok=False)
    assert youngest() == 1
    assert vcs("propget", file_url, "project:history", "--raw").stdout == b"old"

    direct = parent / "a.local"
    deeper = child / "b.local"
    global_match = child / "untracked.svnglobalfixture"
    for f in (direct, deeper, global_match):
        f.touch()
    file.write_text("changed\n")
    def classify(directory):
        result = svn("status", "--no-ignore", directory).decode().splitlines()
        return {line[8:]: line[0] for line in result}
    status = classify(parent)
    assert (status[str(direct)], status[str(deeper)], status[str(global_match)], status[str(file)]) == ("I", "?", "I", "M")
    visible = vcs("status", wc).stdout
    assert all(name in visible for name in (b"b.local", path.encode()))
    assert all(name not in visible for name in (b"a.local", b"untracked.svnglobalfixture"))
    all_items = vcs("status", wc, "--all").stdout
    assert all(name in all_items for name in (b"a.local", b"untracked.svnglobalfixture"))
    listed = vcs("ignore", wc, "--path", "parent/child").stdout
    assert b"*.svnglobalfixture" in listed and b"*.local" not in listed
    vcs("propset", wc, "svn:ignore", "*.local", "--path", "parent/child")
    assert classify(parent)[str(deeper)] == "I"
    vcs("propdel", wc, "svn:ignore", "--path", "parent/child")
    assert classify(parent)[str(deeper)] == "?"
    vcs("ignore", wc, *at_file, ok=False)

    outside = base / "outside"
    outside.mkdir()
    (wc / "linked").symlink_to(outside, target_is_directory=True)
    nested = wc / "nested"
    svn("checkout", url, nested)
    for bad in ("../outside", "/absolute", "linked/x", "nested/x", "parent/../x",
                "parent//x", "parent/.svn/x", "parent/child/tracked.svnglobalfixture/x", "parent/"):
        vcs("mkdir", wc, bad, "--parents", ok=False)
    for bad in ("../outside", "linked", "nested/parent"):
        vcs("propset", wc, "project:bad", "x", "--path", bad, ok=False)
    (wc / "untracked").mkdir()
    vcs("mkdir", wc, "untracked/sub", "--parents", ok=False)
    assert not (wc / "untracked" / "sub").exists()
    assert not list(outside.iterdir())
    assert not (nested / "x").exists()
    vcs("mkdir", wc, "missing/sub", ok=False)
    assert not (wc / "missing").exists()
    assert b"parent/plain" in vcs("mkdir", wc, "parent/plain").stdout
    assert b"pending, pending/mid, pending/mid/end" in vcs("mkdir", wc, "pending/mid/end", "--parents").stdout
    vcs("mkdir", wc, "pending/mid/end", "--parents", ok=False)
    assert classify(wc)[str(wc / "pending" / "mid" / "end")] == "A"
    vcs("revert", wc, "parent/plain", "pending")
    reverted = classify(wc)
    assert reverted.get(str(wc / "parent" / "plain")) in (None, "?")
    assert reverted.get(str(wc / "pending")) in (None, "?")
    assert youngest() == 1
    vcs("mkdir", url, "remote", ok=False)

    file.write_text("tracked\n")
    pending = vcs("status", wc).stdout
    assert path.encode() in pending
    vcs("commit", wc, path, "--exact", "-m", "verified property change")
    assert youngest() == 2
    fresh = base / "fresh"
    svn("checkout", url, fresh)
    assert vcs("propget", fresh, "project:blob", *at_file, "--raw").stdout == data
    assert vcs("propget", file_url, "project:history", "--raw").stdout == b"new"
    svn("move", file_url, url + "/parent/child/moved.svnglobalfixture", "-m", "rename")
    assert vcs("propget", file_url, "project:history", "--revision", 1, "--peg", 1, "--raw").stdout == b"old"
    vcs("propget", file_url, "project:history", "--raw", ok=False)

print("✅ 属性、继承、忽略规则及工作副本建目录验收通过")
