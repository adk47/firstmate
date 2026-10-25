"""Read-only client for Jan's credit-trust board: ``GET /api/notices`` (H-DevOps #4344).

A notice carries a named reviewer's one-click answers, append-only:
``notices[].answers[<ask_id>] = [{choice, note, by, at}, ...]`` (the latest entry wins).

Resolved and authenticated the way scripts/credit-digest-dm.sh reaches the board:

  - host ``credit-trust-board.monitoring.svc.cluster.local`` port 3000; node-8's host resolver
    does not know *.svc names, so the name falls back to one A query against kube-dns
    (10.43.0.10). ``CREDIT_RETRO_BOARD_IP`` pins the address.
  - the board's agent token ``CREDIT_TRUST_BOARD_AGENT_TOKEN`` from
    ``/etc/hydra/credit-trust-board.env`` (``CREDIT_RETRO_BOARD_ENV``), sent ONLY in the
    ``X-Credit-Trust-Token`` header, never in the URL, never logged.

Any failure (no token, unresolvable host, transport error, a non-200 answer, a body without
``notices[]``) raises BoardError: the caller holds the row.
"""

from __future__ import annotations

import http.client
import json
import os
import random
import socket
import struct
from typing import Any

DEFAULT_ENV = "/etc/hydra/credit-trust-board.env"
DEFAULT_HOST = "credit-trust-board.monitoring.svc.cluster.local"
DEFAULT_PORT = 3000
DEFAULT_KUBE_DNS = "10.43.0.10"
TOKEN_KEY = "CREDIT_TRUST_BOARD_AGENT_TOKEN"
TIMEOUT_S = 30


class BoardError(RuntimeError):
    """The board's notices could not be read."""


def agent_token(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith(f"{TOKEN_KEY}="):
                    token = line[len(TOKEN_KEY) + 1:].strip()
                    if token:
                        return token
                    break
    except OSError as exc:
        raise BoardError(f"board agent token file {path} is not readable") from exc
    raise BoardError(f"{TOKEN_KEY} is empty or missing in {path}")


def _kube_dns_a(name: str, server: str) -> str:
    qid = random.randint(0, 65535)
    query = (struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
             + b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack(">HH", 1, 1))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(3)
        s.sendto(query, (server, 53))
        r, _ = s.recvfrom(2048)
    if struct.unpack(">H", r[:2])[0] != qid:
        raise BoardError(f"kube-dns {server} answered another query")
    answers = struct.unpack(">H", r[6:8])[0]
    i = 12
    while r[i]:
        i += r[i] + 1
    i += 5
    for _ in range(answers):
        i += 2 if r[i] & 0xC0 == 0xC0 else (r.index(b"\0", i) + 1 - i)
        rtype, _, _, length = struct.unpack(">HHIH", r[i:i + 10])
        i += 10
        if rtype == 1 and length == 4:
            return socket.inet_ntoa(r[i:i + 4])
        i += length
    raise BoardError(f"kube-dns {server} has no A record for {name}")


def resolve(host: str, kube_dns: str) -> str:
    try:
        return socket.gethostbyname(host)
    except OSError:
        pass
    try:
        return _kube_dns_a(host, kube_dns)
    except (OSError, IndexError, struct.error) as exc:
        raise BoardError(f"cannot resolve {host}: {exc}") from exc


def notices() -> list[dict[str, Any]]:
    """Every notice on the board, as ``GET /api/notices`` returns it."""
    env = os.environ
    token = agent_token(env.get("CREDIT_RETRO_BOARD_ENV", DEFAULT_ENV))
    host = env.get("CREDIT_RETRO_BOARD_HOST", DEFAULT_HOST)
    port = int(env.get("CREDIT_RETRO_BOARD_PORT", DEFAULT_PORT))
    ip = env.get("CREDIT_RETRO_BOARD_IP") or resolve(host, env.get("CREDIT_RETRO_KUBE_DNS", DEFAULT_KUBE_DNS))
    conn = http.client.HTTPConnection(ip, port, timeout=TIMEOUT_S)
    try:
        conn.request("GET", "/api/notices", headers={"Host": f"{host}:{port}", "Accept": "application/json",
                                                     "X-Credit-Trust-Token": token})
        resp = conn.getresponse()
        body = resp.read()
    except (OSError, http.client.HTTPException) as exc:
        raise BoardError(f"board unreachable: {exc}") from exc
    finally:
        conn.close()
    if resp.status != 200:
        raise BoardError(f"board answered HTTP {resp.status}")
    try:
        doc = json.loads(body)
    except ValueError as exc:
        raise BoardError("board notices are not JSON") from exc
    items = doc.get("notices") if isinstance(doc, dict) else None
    if not isinstance(items, list):
        raise BoardError("board answer has no notices[]")
    return items
