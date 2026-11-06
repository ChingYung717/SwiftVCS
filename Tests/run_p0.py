"""Offline acceptance checks for P0 against a disposable Subversion repository."""
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile

vcsctl = Path(sys.argv[1]).resolve()
svn_bin = Path(sys.argv[2]).resolve()


def call(executable, *args, code=0):
    argv = [str(executable), *map(str, args)]
    run = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    assert run.returncode == code, (argv, run.returncode, run.stdout, run.stderr)
    return run.stdout + run.stderr


def svn(*args, code=0):
    return call(svn_bin / "svn", *args, code=code)


def vcs(*args, code=0):
    return call(vcsctl, *args, code=code)


with tempfile.TemporaryDirectory(prefix="swiftvcs-p0-") as temp:
    root = Path(temp).resolve()
    home = root / "home"
    home.mkdir()
    os.environ.update(HOME=str(home), CFFIXED_USER_HOME=str(home))
    repository = root / "repo"
    call(svn_bin / "svnadmin", "create", repository)
    url = repository.as_uri()
    trunk = url + "/trunk"
    branch = url + "/branches/feature"
    svn("mkdir", trunk, url + "/branches", "-m", "layout")
    wc = root / "wc"
    svn("checkout", trunk, wc)
    (wc / "dir").mkdir()
    for name in ("delete.txt", "move.txt", "copy.txt", "冲突.txt", "prop.txt", "tree.txt", "merge.txt"):
        (wc / name).write_text("base\nsecond\n")
    for name in ("selected.txt", "other.txt"):
        (wc / "dir" / name).write_text("base\n")
    svn("add", *sorted(path for path in wc.iterdir() if path.name != ".svn"))
    svn("propset", "fixture:value", "base", wc / "prop.txt")
    svn("commit", wc, "-m", "base fixtures")
    svn("update", wc)

    # GUI 启动时可能没有 locale 环境变量，C locale 也必须保留中文错误。
    locale_env = {key: value for key, value in os.environ.items()
                  if key not in ("LANG", "LC_ALL", "LC_CTYPE")}
    for env in (locale_env, dict(locale_env, LC_ALL="C")):
        failure = subprocess.run(
            [str(vcsctl), "delete", str(wc), "."], env=env,
            capture_output=True, encoding="utf-8", timeout=30,
        )
        assert failure.returncode == 1, failure
        assert "路径包含不允许的目录" in failure.stderr and "{U+" not in failure.stderr, failure.stderr

    def head():
        return int(call(svn_bin / "svnlook", "youngest", repository).strip())

    def checkout(source, name):
        path = root / name
        svn("checkout", source, path)
        return path

    # 路径预检必须在整批写操作之前完成。
    sibling = checkout(trunk, "sibling")
    nested = checkout(trunk, "wc/nested")
    (wc / "escape").symlink_to(sibling, target_is_directory=True)
    target = sibling / "prop.txt"
    target.write_text("do not revert\n")
    for path in ("../sibling/prop.txt", str(target), "escape/prop.txt", "nested/prop.txt", ".svn/wc.db"):
        vcs("revert", wc, path, code=1)
    assert target.read_text() == "do not revert\n"
    vcs("commit", wc, str(target), "-m", "wrong copy", code=1)
    (wc / "pending.txt").write_text("unversioned\n")
    outside = sibling / "outside.txt"
    outside.write_text("unversioned elsewhere\n")
    vcs("add", wc, "pending.txt", str(outside), code=1)
    assert svn("status", wc / "pending.txt").startswith("?")
    assert svn("status", outside).startswith("?")
    (wc / "pending.txt").unlink()
    (wc / "escape").unlink()
    # 嵌套工作副本独立清理，后续夹具要验证干净副本合并。
    shutil.rmtree(nested)

    # SVN 叶节点符号链接按版本化节点操作，不跟随其目标。
    link = wc / "leaf"
    link.symlink_to(target)
    vcs("add", wc, "leaf")
    vcs("revert", wc, "leaf")
    assert target.read_text() == "do not revert\n"
    link.unlink()

    external_wc = checkout(trunk, "externals-fixture")
    svn("propset", "svn:externals", "^/trunk/prop.txt external.txt", external_wc)
    svn("update", external_wc)
    external = external_wc / "external.txt"
    external.write_text("external edit\n")
    vcs("revert", external_wc, "external.txt", code=1)
    assert external.read_text() == "external edit\n"

    initial = head()
    vcs("delete", wc, "delete.txt")
    vcs("rename", wc, "move.txt", "改名.txt")
    vcs("move", wc, "改名.txt", "dir/改名.txt")
    vcs("copy", wc, "copy.txt", "dir/副本.txt")
    statuses = vcs("status", wc)
    assert "删除" in statuses and "move.txt → dir/改名.txt" in statuses, statuses
    assert "dir/改名.txt ← move.txt" in statuses and "dir/副本.txt" in statuses, statuses
    assert head() == initial
    assert not (wc / "delete.txt").exists() and not (wc / "move.txt").exists()
    assert (wc / "dir/改名.txt").read_text() == "base\nsecond\n"
    vcs("commit", wc, "delete.txt", "dir/改名.txt", "dir/副本.txt", "--exact", "-m", "file operations")
    changes = call(svn_bin / "svnlook", "changed", "--copy-info", "-r", head(), repository)
    assert "D   trunk/delete.txt" in changes and "D   trunk/move.txt" in changes, changes
    assert "from trunk/move.txt:" in changes and "from trunk/copy.txt:" in changes, changes

    svn("update", wc)
    vcs("move", wc, "dir/改名.txt", "moved.txt")
    (wc / "moved.txt").write_text("keep local edits\n")
    vcs("revert", wc, "moved.txt", code=1)
    vcs("revert", wc, code=1)
    assert (wc / "moved.txt").read_text() == "keep local edits\n"
    assert " → " in vcs("status", wc)
    (wc / "moved.txt").write_text("base\nsecond\n")
    vcs("revert", wc, "moved.txt")
    statuses = vcs("status", wc)
    assert " → " not in statuses and (wc / "dir/改名.txt").exists(), statuses
    if (wc / "moved.txt").exists():
        (wc / "moved.txt").unlink()

    (wc / "copy.txt").write_text("dirty\n")
    unchanged = head()
    vcs("delete", wc, "copy.txt", code=1)
    vcs("delete", wc, "冲突.txt", "copy.txt", code=1)
    assert (wc / "copy.txt").read_text() == "dirty\n" and (wc / "冲突.txt").is_file()
    vcs("copy", wc, "copy.txt", "merge.txt", code=1)
    vcs("copy", wc, "copy.txt", "../escape.txt", code=1)
    vcs("copy", wc, "copy.txt", str(root / "escape.txt"), code=1)
    vcs("delete", wc, ".", code=1)
    vcs("delete", wc, ".svn/wc.db", code=1)
    if (wc / "COPY.txt").exists():
        vcs("move", wc, "copy.txt", "COPY.txt", code=1)
    (wc / "link").symlink_to(root, target_is_directory=True)
    vcs("copy", wc, "copy.txt", "link/escape.txt", code=1)
    assert not (root / "escape.txt").exists() and head() == unchanged
    (wc / "link").unlink()
    svn("revert", wc / "copy.txt")

    # Explicitly committing a directory's properties must not collect unchecked children.
    svn("propset", "fixture:value", "changed", wc / "dir")
    (wc / "dir/other.txt").write_text("unchecked\n")
    vcs("commit", wc, "dir", "--exact", "-m", "directory properties only")
    assert "other.txt" in svn("status", wc)
    assert "other.txt" not in call(svn_bin / "svnlook", "changed", "-r", head(), repository)
    svn("revert", wc / "dir/other.txt")

    conflicts = {strategy: checkout(trunk, strategy) for strategy in ("current", "base", "incoming", "local")}
    extra = checkout(trunk, "unsupported")
    upstream = checkout(trunk, "upstream")
    for target in conflicts.values():
        (target / "冲突.txt").write_text("local\nsecond\n")
    (upstream / "冲突.txt").write_text("incoming\nsecond\n")
    svn("propset", "fixture:value", "incoming", upstream / "prop.txt")
    svn("delete", upstream / "tree.txt")
    svn("commit", upstream, "-m", "incoming edits")
    svn("propset", "fixture:value", "local", extra / "prop.txt")
    (extra / "tree.txt").write_text("local tree edit\n")
    vcs("update", extra)
    result = vcs("status", extra)
    assert "属性冲突" in result and "树冲突" in result, result
    for path in ("prop.txt", "tree.txt"):
        vcs("resolve", extra, path, "--strategy", "incoming", code=1)
    assert "属性冲突" in vcs("status", extra) and "树冲突" in vcs("status", extra)

    expected = {"current": "edited", "base": "base", "incoming": "incoming", "local": "local"}
    for strategy, target in conflicts.items():
        update = vcs("update", target)
        assert "冲突：" in update and "冲突.txt" in update, update
        status = vcs("status", target)
        assert "文本冲突" in status, status
        if strategy == "current":
            (target / "冲突.txt").write_text("edited\nsecond\n")
        vcs("resolve", target, "冲突.txt", "--strategy", strategy)
        assert (target / "冲突.txt").read_text() == expected[strategy] + "\nsecond\n"
        assert "文本冲突" not in vcs("status", target)

    svn("copy", trunk, branch, "-m", "create branch")
    source = checkout(branch, "source")
    (source / "merge.txt").write_text("base\nbranch\n")
    svn("commit", source, "-m", "merge one")
    one = head()
    target = checkout(trunk, "merge-target")
    request = ("merge", target, "--source", branch, "--revision", one)
    preview = vcs(*request, "--dry-run")
    assert "变更：merge.txt" in preview and svn("status", target) == "", preview
    assert (target / "merge.txt").read_text() == "base\nsecond\n" and head() == one
    assert svn("propget", "svn:mergeinfo", target, code=1)
    vcs(*request)
    assert "merge.txt" in vcs("status", target) and "svn:mergeinfo" in vcs("status", target)
    assert str(one) in svn("propget", "svn:mergeinfo", target) and head() == one
    vcs("commit", target, "merge.txt", "--exact", "-m", "incomplete", code=1)
    vcs("merge", target, "--source", branch, "--revision", one, "--dry-run", code=1)
    vcs("commit", target, ".", "merge.txt", "--exact", "-m", "merge content and metadata")
    assert head() == one + 1
    svn("update", target)
    no_change = vcs(*request, "--dry-run")
    assert "变更：" not in no_change and "冲突：" not in no_change, no_change

    (target / "merge.txt").write_text("target\nbranch\n")
    svn("commit", target, "-m", "target conflict")
    svn("update", target)
    (source / "merge.txt").write_text("source\nbranch\n")
    svn("commit", source, "-m", "source conflict")
    two = head()
    conflict_request = ("merge", target, "--source", branch, "--from", two - 1, "--to", two)
    preview = vcs(*conflict_request, "--dry-run", code=2)
    assert "冲突：merge.txt" in preview and svn("status", target) == "", preview
    assert (target / "merge.txt").read_text() == "target\nbranch\n" and head() == two
    applied = vcs(*conflict_request, code=2)
    assert "冲突：merge.txt" in applied and "文本冲突" in vcs("status", target), applied
    assert head() == two

    mixed = checkout(trunk, "mixed")
    svn("update", "-r", two - 1, mixed / "merge.txt")
    vcs("merge", mixed, "--source", branch, "--revision", two, "--dry-run", code=1)
    vcs("merge", mixed, "--source", branch, "--revision", two, "--revision", two, code=1)
    vcs("merge", mixed, "--source", branch, "--revision", 2**31, code=1)

print("P0 file operations, conflict resolution and merge acceptance passed")
