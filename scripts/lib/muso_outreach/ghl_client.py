"""Minimal GHL adapter — only the one operation the worker needs:
advance an opportunity stage."""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

from .config import GHL_LOCATION_ID


def advance_opportunity_stage(opp_id: str, stage_id: str) -> None:
    api_key = os.environ.get("GHL_API_KEY")
    if not api_key:
        raise RuntimeError("GHL_API_KEY is not set in the environment")
    body = json.dumps({"pipelineStageId": stage_id,
                       "locationId": GHL_LOCATION_ID}).encode()
    req = urllib.request.Request(
        f"https://services.leadconnectorhq.com/opportunities/{opp_id}",
        data=body, method="PUT",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Version": "2021-07-28",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        if resp.status >= 300:
            raise RuntimeError(f"GHL PUT opp {opp_id} → {resp.status}")
