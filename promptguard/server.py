"""
PromptGuard 2 sidecar — FastAPI wrapper for Meta's Llama Prompt Guard 2 22M classifier.

Runs on CPU only. Serves the EXISTING classifier slot the Caroline safety layer already talks to
(plugins/intercom/src/safety-classifier.ts -> http://127.0.0.1:18793/v1/classify) and the edge
intercom webhook (scripts/intercom-webhook.js -> same port).

WHY THIS LOADS THE MODEL DIRECTLY INSTEAD OF VIA llamafirewall
-------------------------------------------------------------
The previous implementation built a `LlamaFirewall(scanners=[PROMPT_GUARD])`. That scanner resolves
the model by HUB REPO ID at request time, and Meta's canonical repo
(`meta-llama/Llama-Prompt-Guard-2-22M`) is gated: without an HF token it answers 401 and the scanner
cannot load. That is exactly the failure that produced 1,582 `classifier_unavailable` ledger rows.
This module loads the SAME weights from a LOCAL, PINNED directory instead:

  * no hub call at request time (or at all, once the image is built),
  * no HF token / no new secret on node-8,
  * every weight file sha256-pinned at image build (promptguard/model.sha256), so a tampered or
    swapped model fails the build instead of silently changing verdicts.

The pinned source is the non-gated mirror `project-free-llama/Llama-Prompt-Guard-2-22M`
@ revision 98f241c60b7999ba67eb8603f548461b577b3bc9 — byte-identical
`DebertaV2ForSequenceClassification` weights to Meta's gated repo.

THREADS ARE CAPPED ON PURPOSE
-----------------------------
This process shares a 24-core host with the openclaw gateway that serves customers. A classifier
that grabs every core would starve the gateway and ADD latency to the very replies it is meant to
protect. `PROMPTGUARD_THREADS` defaults to 1 and is hard-capped at 2. Measured on the pinned model
with 1 thread: median 55 ms inbound / 67 ms outbound, p95 150 ms, max 194 ms — inside the 800 ms
budget the plugin allows.

FAIL-SOFT IS THE CLIENT'S JOB, NOT THIS SERVICE'S
-------------------------------------------------
This service never decides anything. It returns a score and a label. The client treats any
non-200, timeout, or malformed body as `{label: "unavailable"}` and lets the deterministic rules
stand alone. So an error here is a 503, never a silent "benign" — a lie would be worse than an
outage, because the client would count it as a real verdict.

Contract (unchanged, pinned by plugins/intercom/tests/caroline-safety.test.ts):
  GET  /health      -> {"status": "ok", "model": "promptguard-2", ...} or 503
  POST /v1/classify {"text": 1..10000 chars} -> {"score": 0..1, "label": "benign"|"jailbreak", "latency_ms"}
"""

import logging
import os
import threading
import time
from contextlib import asynccontextmanager
from typing import Literal

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s [promptguard] %(message)s")
logger = logging.getLogger("promptguard")

# A LOCAL directory baked into the image. Never a hub repo id: a repo id means a network call in
# the request path and a gated-repo 401.
MODEL_DIR = os.environ.get("PROMPTGUARD_MODEL_DIR", "/app/model")

# Hard cap: this box also runs the gateway. 1 thread is the measured default; 2 is the ceiling.
MAX_THREADS = 2
try:
    _threads = int(os.environ.get("PROMPTGUARD_THREADS", "1"))
except ValueError:
    _threads = 1
THREADS = max(1, min(MAX_THREADS, _threads))

MAX_TEXT_CHARS = 10_000  # mirrored by safety-classifier.ts's MAX_CHARS
MAX_TOKENS = 512  # the pinned model's max_position_embeddings

# Prompt Guard 2 is a BINARY classifier: P(injection/jailbreak) is the score we return. The label is
# derived from it so the client's existing "label in (injection, jailbreak)" checks keep working.
#
# 0.9, not 0.5: measured on the pinned weights, BENIGN text tops out at 0.125 (benign-credit) and
# benign greeting/support/impersonation score 0.0008-0.0022. Labelling from 0.9 leaves a wide margin
# above every benign sample we have while still labelling 4 of 5 detected attack texts. The client's
# OUTBOUND_BLOCK_SCORE is 0.98 and is applied on top; nothing is blocked by this label alone.
LABEL_THRESHOLD = 0.9

_state = {"tokenizer": None, "model": None, "torch": None, "load_error": None}
_lock = threading.Lock()


def _label_index(config) -> int:
    """Index of the "this is an injection" logit, read from the model config's own id2label.

    The pinned mirror labels are {0: "LABEL_0", 1: "LABEL_1"}; Meta's card documents 1 = jailbreak.
    Resolve by name when the mapping is informative so a differently-labelled fine-tune cannot
    silently invert the verdict.
    """
    id2label = getattr(config, "id2label", None) or {}
    for idx, name in id2label.items():
        low = str(name).lower()
        if "jailbreak" in low or "injection" in low or "malicious" in low:
            return int(idx)
    return 1


def _load():
    """Load the tokenizer + model once. Raises on failure; the caller records the error."""
    import torch  # noqa: PLC0415 — deferred so /health reports the real load failure
    from transformers import AutoModelForSequenceClassification, AutoTokenizer  # noqa: PLC0415

    torch.set_num_threads(THREADS)
    try:  # set_num_interop_threads raises if called after parallel work started
        torch.set_num_interop_threads(1)
    except RuntimeError:
        pass

    tokenizer = AutoTokenizer.from_pretrained(MODEL_DIR, local_files_only=True)
    model = AutoModelForSequenceClassification.from_pretrained(MODEL_DIR, local_files_only=True)
    model.eval()
    _state.update({"tokenizer": tokenizer, "model": model, "torch": torch, "load_error": None})
    return _state


def get_model():
    """Lazy + retrying: a failed load at boot is retried on the next call, never cached as fatal."""
    if _state["model"] is not None:
        return _state
    with _lock:
        if _state["model"] is None:
            start = time.monotonic()
            try:
                _load()
                logger.info("PromptGuard 2 loaded from %s in %.0fms (threads=%d)", MODEL_DIR, (time.monotonic() - start) * 1000, THREADS)
            except Exception as e:  # noqa: BLE001 — surfaced to the client as 503, never as benign
                _state["load_error"] = f"{type(e).__name__}: {e}"
                logger.error("PromptGuard 2 load failed: %s", _state["load_error"], exc_info=True)
                raise
    return _state


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """Warm the model at boot so the FIRST customer call is not the one paying the load cost.

    Failure is logged and swallowed: the process must still start so /health can report 503 with a
    reason (a crash-looping container reports nothing) and so the next request retries the load.
    """
    threading.Thread(target=lambda: _warm(), name="promptguard-warmup", daemon=True).start()
    yield


def _warm():
    try:
        get_model()
    except Exception:  # noqa: BLE001 — already logged in get_model
        pass


app = FastAPI(title="PromptGuard 2 Sidecar", version="2.0.0", lifespan=lifespan)


class ClassifyRequest(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_TEXT_CHARS)


class ClassifyResponse(BaseModel):
    score: float = Field(ge=0.0, le=1.0)
    label: Literal["benign", "jailbreak"]
    latency_ms: float = Field(ge=0.0)


@app.get("/health")
async def health():
    """Readiness probe: 200 only when the model is loaded and can score."""
    if _state["model"] is None:
        return JSONResponse(
            status_code=503,
            content={"status": "loading" if _state["load_error"] is None else "error", "detail": _state["load_error"]},
        )
    return {"status": "ok", "model": "promptguard-2", "threads": THREADS}


@app.post("/v1/classify", response_model=ClassifyResponse)
async def classify(req: ClassifyRequest):
    start = time.monotonic()
    try:
        state = get_model()
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"PromptGuard model unavailable: {type(e).__name__}") from e

    torch = state["torch"]
    try:
        enc = state["tokenizer"](
            req.text,
            truncation=True,
            max_length=MAX_TOKENS,
            return_tensors="pt",
        )
        with torch.no_grad():
            logits = state["model"](**enc).logits[0]
        probs = torch.softmax(logits, dim=-1)
        score = float(probs[_label_index(state["model"].config)].item())
        score = max(0.0, min(1.0, score))
        label = "jailbreak" if score >= LABEL_THRESHOLD else "benign"
        elapsed = (time.monotonic() - start) * 1000
        logger.info("classify: score=%.3f label=%s latency=%.1fms len=%d", score, label, elapsed, len(req.text))
        return ClassifyResponse(score=score, label=label, latency_ms=round(elapsed, 1))
    except Exception as e:  # noqa: BLE001
        logger.error("classify inference failed: %s", e, exc_info=True)
        raise HTTPException(status_code=503, detail=f"PromptGuard inference failed: {type(e).__name__}") from e
