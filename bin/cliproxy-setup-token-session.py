#!/usr/bin/env python3
"""One `claude setup-token` sign-in session, held open for a remote approval.

Why this exists
---------------
`claude setup-token` refuses to run when its stdout is not a terminal: the
command returns immediately and prints nothing. A helper that pipes its output
therefore cannot print an approval URL at all. This supervisor gives the command
a real pseudo-terminal, publishes the URL it prints, and keeps that exact
process alive so the authorization code an owner obtains on their own phone can
be handed back hours later, to the same process that issued the URL. The OAuth
state and PKCE verifier live in that process, so the code is useless anywhere
else - which is why the session, not the code, is the durable thing.

Contract (files, all under --dir, which the caller creates at mode 0700)
-----------------------------------------------------------------------
  url       written once the command prints an approval URL (mode 0600)
  code      written by the caller with the pasted code or redirect URL; the
            supervisor picks it up within a second and removes it
  token     written when the command prints the long-lived token (mode 0600)
  status    one word: waiting | submitted | rejected | token-ready | failed | expired
  log       the command's output with every token-shaped string redacted

The token is never written to standard output, standard error, or the log.
The supervisor exits as soon as it writes a token, the command fails, or
--timeout-secs elapses.

Usage:
  cliproxy-setup-token-session.py --dir DIR [--claude-bin PATH] [--timeout-secs N]
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import os
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

URL_RE = re.compile(rb"https://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+")
TOKEN_RE = re.compile(rb"sk-ant-oat01-[A-Za-z0-9_-]+")
# The command's own words for "that code is not usable". It keeps the sign-in
# open after a rejection, so the caller must be told promptly rather than
# waiting out the whole approval window.
REJECTED_RE = re.compile(
    rb"not from this sign-in|invalid authorization code|callback url not accepted|invalid_grant",
    re.IGNORECASE,
)
# Terminal escape sequences and box drawing belong in the log, not in a URL.
ANSI_RE = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][A-Za-z0-9]")
REDACT = b"<redacted>"


def write_atomic(path: str, data: bytes, mode: int = 0o600) -> None:
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def set_status(directory: str, status: str) -> None:
    write_atomic(os.path.join(directory, "status"), status.encode() + b"\n")


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--claude-bin", default="claude")
    parser.add_argument("--timeout-secs", type=int, default=72 * 3600)
    args = parser.parse_args()

    directory = args.dir
    url_path = os.path.join(directory, "url")
    code_path = os.path.join(directory, "code")
    token_path = os.path.join(directory, "token")
    log_path = os.path.join(directory, "log")
    if not os.path.isdir(directory):
        sys.exit("cliproxy-setup-token-session: --dir does not exist")
    set_status(directory, "waiting")

    master, slave = os.openpty()
    # A wide window keeps a long approval URL on one line, so it can be
    # extracted and relayed verbatim instead of reassembled from wrapping.
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 240, 0, 0))
    try:
        child = subprocess.Popen(
            [args.claude_bin, "setup-token"],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            start_new_session=True,
            close_fds=True,
        )
    except OSError as exc:
        os.close(master)
        os.close(slave)
        set_status(directory, "failed")
        write_atomic(log_path, ("cannot start %s: %s\n" % (args.claude_bin, exc)).encode())
        return 1
    os.close(slave)

    raw = bytearray()
    clean = bytearray()
    token: bytes | None = None
    # Where in the accumulated output the current code attempt began, so a
    # rejection split across several reads is still recognised.
    submitted_at: int | None = None
    submitted_codes: list[bytes] = []
    deadline = time.time() + args.timeout_secs

    def stop(reason: str, status: str) -> int:
        try:
            os.close(master)
        except OSError:
            pass
        if child.poll() is None:
            try:
                child.terminate()
                child.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                child.kill()
        set_status(directory, status)
        # The log is the only durable copy of the command's output, so every
        # token-shaped string is redacted before it lands there.
        tail = TOKEN_RE.sub(REDACT, bytes(clean[-20000:]))
        # The terminal echoes each pasted code, so the codes the caller handed
        # us are redacted too: a one-time code does not belong in a durable log.
        for pasted in submitted_codes:
            tail = tail.replace(pasted, b"<redacted-code>")
        write_atomic(log_path, tail + ("\n[%s]\n" % reason).encode())
        return 0 if status == "token-ready" else 1

    while True:
        if time.time() > deadline:
            return stop("approval did not arrive before the session timeout", "expired")
        # A pasted code or redirect URL is the only input this session takes.
        if os.path.exists(code_path):
            try:
                with open(code_path, "rb") as handle:
                    code = handle.read().strip()
            except OSError:
                code = b""
            if code:
                # A rejected code must be re-submittable, so nothing is latched
                # here: each write of the code file is one attempt.
                os.write(master, code + b"\r")
                set_status(directory, "submitted")
                submitted_codes.append(code)
                submitted_at = len(clean)
            try:
                os.unlink(code_path)
            except OSError:
                pass
        try:
            ready, _, _ = select.select([master], [], [], 1.0)
        except (OSError, ValueError):
            ready = []
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:  # the child closed its side
                    chunk = b""
                else:
                    chunk = b""
            if not chunk:
                if child.poll() is not None:
                    break
                continue
            raw.extend(chunk)
            stripped = ANSI_RE.sub(b"", chunk)
            clean.extend(stripped)
            if not os.path.exists(url_path):
                match = URL_RE.search(stripped)
                if match:
                    write_atomic(url_path, match.group(0) + b"\n")
            if submitted_at is not None and REJECTED_RE.search(bytes(clean[submitted_at:])):
                set_status(directory, "rejected")
                submitted_at = None
            match = TOKEN_RE.search(raw)
            if match:
                token = match.group(0)
                break
        elif child.poll() is not None:
            break

    if token is None:
        return stop("the sign-in ended without printing a token", "failed")

    write_atomic(token_path, token + b"\n")
    return stop("token written", "token-ready")


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    sys.exit(main())
