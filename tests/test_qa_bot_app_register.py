"""Regression tests for scripts/qa-bot-app-register.py's key-store write.

The App private key must be 0600 *before any bytes are written*. Two traps this
guards, both found in review of PR #748:
  - write_text() + chmod leaves the key at the process umask during the write.
  - os.open(path, ..., 0o600) applies that mode ONLY when it creates the file.
    If the target already exists 0644, O_TRUNC rewrites it in place and the old
    mode survives — a chmod afterwards is too late.
"""
import os
import stat

import pytest


def _write_like_register(path, payload, writer=None):
    """Mirror the write in qa-bot-app-register.main() exactly."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        observed = stat.S_IMODE(os.fstat(fd).st_mode)
    except BaseException:
        os.close(fd)
        raise
    # fdopen takes ownership of fd; no handler here on purpose (see below).
    with os.fdopen(fd, "w") as fh:
        (writer or fh.write)(payload)
    return observed


def test_new_file_is_0600(tmp_path):
    out = tmp_path / "qa-bot-app.json"
    mode_at_write = _write_like_register(out, "secret")
    assert mode_at_write == 0o600
    assert stat.S_IMODE(out.stat().st_mode) == 0o600


def test_preexisting_0644_file_is_tightened_before_the_write(tmp_path):
    """The regression: an existing loose file must not receive the key at 0644."""
    out = tmp_path / "qa-bot-app.json"
    out.write_text("stale")
    os.chmod(out, 0o644)
    assert stat.S_IMODE(out.stat().st_mode) == 0o644

    mode_at_write = _write_like_register(out, "secret")

    # tightened BEFORE the secret was written, not after
    assert mode_at_write == 0o600, "key would have been written while still 0644"
    assert stat.S_IMODE(out.stat().st_mode) == 0o600
    assert out.read_text() == "secret"


def test_register_script_uses_fchmod_not_post_hoc_chmod():
    """Guard the source itself: os.open's mode arg alone is not sufficient."""
    src = os.path.join(os.path.dirname(__file__), "..", "scripts", "qa-bot-app-register.py")
    with open(src, encoding="utf-8") as fh:
        text = fh.read()
    assert "os.fchmod(fd, 0o600)" in text, "the descriptor must be tightened before writing"
    assert "out.write_text(" not in text, "write_text leaves the key at the process umask"


def test_write_failure_surfaces_the_real_error_not_ebadf(tmp_path):
    """A failing write must raise ITS OWN error, not EBADF from a double close.

    `with os.fdopen(fd)` closes fd on the exception path too, so an outer
    `except: os.close(fd)` would raise EBADF and mask the original failure.
    """
    out = tmp_path / "qa-bot-app.json"

    def boom(_payload):
        raise RuntimeError("disk full")

    with pytest.raises(RuntimeError, match="disk full"):
        _write_like_register(out, "secret", writer=boom)


def test_register_script_does_not_double_close_the_descriptor():
    """Guard the source: the close must not wrap the fdopen block."""
    src = os.path.join(os.path.dirname(__file__), "..", "scripts", "qa-bot-app-register.py")
    with open(src, encoding="utf-8") as fh:
        text = fh.read()
    # the only os.close must be in the fchmod guard, before fdopen takes over
    fchmod_at = text.index("os.fchmod(fd, 0o600)")
    fdopen_at = text.index("os.fdopen(fd,")
    close_at = text.index("os.close(fd)")
    assert fchmod_at < close_at < fdopen_at, "os.close must precede fdopen taking ownership"
