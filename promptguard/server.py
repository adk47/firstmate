"""
PromptGuard 2 sidecar — FastAPI wrapper for Meta's 22M-param BERT prompt injection classifier.

Runs on CPU, <10ms inference, multilingual. Zero API cost.
Port: 18793 (localhost only — no external exposure).
"""

import time
import logging
import threading
from typing import Literal

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s [promptguard] %(message)s")
logger = logging.getLogger("promptguard")

app = FastAPI(title="PromptGuard 2 Sidecar", version="1.0.0")

# --- Lazy model loading (load on first request, not import time) ---
_scanner = None
_scanner_lock = threading.Lock()


def get_scanner():
    global _scanner
    if _scanner is None:
      with _scanner_lock:
        if _scanner is not None:
            return _scanner
        logger.info("Loading PromptGuard 2 model (first request)...")
        start = time.monotonic()
        from llamafirewall import LlamaFirewall, ScannerType, UserMessage

        _scanner = {
            "firewall": LlamaFirewall(
                scanners=[{"scanner_type": ScannerType.PROMPT_GUARD}]
            ),
            "UserMessage": UserMessage,
        }
        elapsed = (time.monotonic() - start) * 1000
        logger.info(f"PromptGuard 2 model loaded in {elapsed:.0f}ms")
    return _scanner


# --- Request / Response models ---


class ClassifyRequest(BaseModel):
    text: str = Field(min_length=1, max_length=10000)


class ClassifyResponse(BaseModel):
    score: float = Field(ge=0.0, le=1.0)
    label: Literal["benign", "injection", "jailbreak"]
    latency_ms: float = Field(ge=0.0)


# --- Endpoints ---


@app.get("/health")
async def health():
    """Readiness probe. Returns ok if model can be loaded."""
    try:
        get_scanner()
        return {"status": "ok", "model": "promptguard-2"}
    except Exception as e:
        logger.error(f"Health check failed: {e}", exc_info=True)
        return JSONResponse(status_code=503, content={"status": "error", "detail": str(e)})


@app.post("/v1/classify", response_model=ClassifyResponse)
async def classify(req: ClassifyRequest):
    """
    Classify text for prompt injection / jailbreak attempts.

    Returns:
        score: 0.0-1.0 (higher = more likely injection)
        label: "benign", "injection", or "jailbreak"
        latency_ms: inference time in milliseconds
    """
    start = time.monotonic()

    try:
        scanner = get_scanner()
    except Exception as e:
        logger.error(f"classify: model load failed: {e}", exc_info=True)
        raise HTTPException(status_code=503, detail=f"PromptGuard model unavailable: {type(e).__name__}")

    firewall = scanner["firewall"]
    UserMessage = scanner["UserMessage"]

    try:
        result = firewall.scan(UserMessage(content=req.text))
        elapsed = (time.monotonic() - start) * 1000

        # Extract score and label from LlamaFirewall result
        score = 0.0
        label = "benign"

        if hasattr(result, "score"):
            score = float(result.score)
        elif hasattr(result, "risk_score"):
            score = float(result.risk_score)
        else:
            logger.warning(f"classify: result has no score/risk_score attribute. type={type(result).__name__}")

        if hasattr(result, "result"):
            # LlamaFirewall returns ScanResult with .result field
            result_str = str(result.result).lower()
            if "unsafe" in result_str or "block" in result_str:
                label = "injection"
                if score == 0.0:
                    score = 0.9
            elif "warn" in result_str:
                label = "jailbreak"
                if score == 0.0:
                    score = 0.5

        # Map score to label if not already set by result field
        if label == "benign" and score > 0.7:
            label = "injection"
        elif label == "benign" and score > 0.3:
            label = "jailbreak"

        score = max(0.0, min(1.0, score))
        logger.info(f"classify: score={score:.3f} label={label} latency={elapsed:.1f}ms len={len(req.text)}")
        return ClassifyResponse(score=score, label=label, latency_ms=round(elapsed, 1))

    except Exception as e:
        logger.error(f"classify error: {e}", exc_info=True)
        raise HTTPException(status_code=503, detail=f"PromptGuard inference failed: {type(e).__name__}")
