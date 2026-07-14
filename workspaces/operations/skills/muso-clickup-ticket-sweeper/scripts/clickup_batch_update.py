#!/usr/bin/env python3
"""Batch ClickUp comments, fields, and status updates with audit logging."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


FIELD_IDS = {
    "comments": "4adb0a1e-995d-4bc3-b535-fd44834d4243",
    "intercom": "c32dbf6e-f680-4ff1-a532-192bb96245c3",
    "muso": "fb08a61a-2870-4b2f-b6cd-c404dccfb97e",
    "profile": "347d23bf-ed7b-40c2-bd10-5bd6ac7210b1",
    "email": "e8618c74-d065-4b75-9a5a-86d658392409",
}

WORKSPACE_ROOT = Path(__file__).resolve().parents[3]
KNOWN_STATUSES = {"to do", "waiting", "impossible", "resolved"}


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z")


def audit_path() -> Path:
    day = dt.datetime.now(dt.UTC).strftime("%Y-%m-%d")
    path = WORKSPACE_ROOT / "api-logs" / "clickup" / f"{day}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def log_audit(record: dict) -> None:
    with audit_path().open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def load_payload(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    if not isinstance(payload, dict):
        raise SystemExit("input must be a JSON object")
    tickets = payload.get("tickets")
    if not isinstance(tickets, list) or not tickets:
        raise SystemExit("input.tickets must be a non-empty array")
    seen_ids = set()
    for i, ticket in enumerate(tickets):
        if not ticket.get("id"):
            raise SystemExit(f"tickets[{i}].id is required")
        if ticket["id"] in seen_ids:
            raise SystemExit(f"duplicate ticket id: {ticket['id']}")
        seen_ids.add(ticket["id"])
        if not ticket.get("comment") and not ticket.get("fields") and not ticket.get("status"):
            raise SystemExit(f"tickets[{i}] has no comment, fields, or status")
        status = ticket.get("status")
        if status is not None and status not in KNOWN_STATUSES:
            raise SystemExit(f"tickets[{i}].status is not recognized: {status}")
        fields = ticket.get("fields") or {}
        if not isinstance(fields, dict):
            raise SystemExit(f"tickets[{i}].fields must be an object")
        for name in fields:
            field_id(name)
        customer_message = ticket.get("customer_message")
        if customer_message is not None:
            validate_customer_message(customer_message, i)
    return payload


def clickup_token() -> str:
    token = os.environ.get("CLICKUP_API_KEY") or os.environ.get("MUSOAI_CLICKUP_API_KEY")
    if not token:
        raise SystemExit("CLICKUP_API_KEY or MUSOAI_CLICKUP_API_KEY is required")
    return token


def request(token: str, method: str, path: str, body: dict | None = None) -> dict:
    url = f"https://api.clickup.com/api/v2{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": token,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            text = resp.read().decode("utf-8")
            try:
                parsed = json.loads(text) if text else None
            except json.JSONDecodeError:
                parsed = text[:1000]
            return {"ok": 200 <= resp.status < 300, "status": resp.status, "body": parsed}
    except urllib.error.HTTPError as exc:
        return {
            "ok": False,
            "status": exc.code,
            "body": exc.read().decode("utf-8", errors="replace")[:2000],
        }
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "status": None, "body": repr(exc)}


def field_id(name: str) -> str:
    if name in FIELD_IDS:
        return FIELD_IDS[name]
    if len(name) >= 20 and "-" in name:
        return name
    raise SystemExit(f"unknown ClickUp field alias: {name}")


def validate_customer_message(customer_message: dict, index: int) -> None:
    if not isinstance(customer_message, dict):
        raise SystemExit(f"tickets[{index}].customer_message must be an object")
    mode = customer_message.get("mode")
    if mode not in {"none", "draft", "send", "sent"}:
        raise SystemExit(f"tickets[{index}].customer_message.mode is not recognized: {mode}")
    text = customer_message.get("text")
    if mode in {"draft", "send", "sent"} and not text:
        raise SystemExit(f"tickets[{index}].customer_message.text is required for mode={mode}")
    if text is not None and not isinstance(text, str):
        raise SystemExit(f"tickets[{index}].customer_message.text must be a string")
    reason = customer_message.get("reason")
    if reason is not None and not isinstance(reason, str):
        raise SystemExit(f"tickets[{index}].customer_message.reason must be a string")


def normalize_ticket(ticket: dict) -> dict:
    return {
        "ticket_id": ticket["id"],
        "planned_status": ticket.get("status"),
        "comment": ticket.get("comment"),
        "fields": ticket.get("fields") or {},
        "customer_message": ticket.get("customer_message"),
    }


def apply_ticket(token: str, ticket: dict, delay: float) -> dict:
    task_id = ticket["id"]
    result = {"ticket_id": task_id, "status_update": None, "comment": None, "fields": []}

    if ticket.get("comment"):
        result["comment"] = request(
            token,
            "POST",
            f"/task/{task_id}/comment",
            {"comment_text": ticket["comment"], "notify_all": False},
        )
        time.sleep(delay)

    for name, value in (ticket.get("fields") or {}).items():
        res = request(token, "POST", f"/task/{task_id}/field/{field_id(name)}", {"value": value})
        result["fields"].append({"field": name, "ok": res["ok"], "status": res["status"], "body": res["body"]})
        time.sleep(delay)

    if ticket.get("status"):
        if has_failure(result):
            result["status_update"] = {
                "ok": False,
                "status": "skipped",
                "body": "status update skipped because comment or field update failed",
            }
        else:
            result["status_update"] = request(token, "PUT", f"/task/{task_id}", {"status": ticket["status"]})
            time.sleep(delay)

    return result


def has_failure(result: dict) -> bool:
    if result.get("status_update") and not result["status_update"]["ok"]:
        return True
    if result.get("comment") and not result["comment"]["ok"]:
        return True
    return any(not field["ok"] for field in result.get("fields", []))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="JSON batch update file")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--delay", type=float, default=0.12)
    args = parser.parse_args()

    payload = load_payload(args.input)
    requester = payload.get("requester") or "unknown"
    action = payload.get("action") or "clickup_ticket_sweep"
    targets = [normalize_ticket(ticket) for ticket in payload["tickets"]]

    pre = {
        "agent": "operations",
        "action": f"{action}_pre",
        "requester": requester,
        "timestamp": utc_now(),
        "count": len(targets),
        "targets": targets,
        "dry_run": args.dry_run,
    }
    log_audit(pre)

    if args.dry_run:
        print(json.dumps(pre, indent=2, ensure_ascii=False))
        return 0

    token = clickup_token()
    results = [apply_ticket(token, ticket, args.delay) for ticket in payload["tickets"]]
    post = {
        "agent": "operations",
        "action": f"{action}_result",
        "requester": requester,
        "timestamp": utc_now(),
        "count": len(results),
        "results": results,
    }
    log_audit(post)
    print(json.dumps(post, indent=2, ensure_ascii=False))

    return 1 if any(has_failure(result) for result in results) else 0


if __name__ == "__main__":
    sys.exit(main())
