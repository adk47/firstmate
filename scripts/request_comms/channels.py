#!/usr/bin/env python3
"""The three channels, each with the confirmation its PROVIDER actually answers.

Every adapter returns a `SendResult` whose status is one of:

  sent         the provider confirmed delivery (Intercom: the message object's id; send-gateway:
               `status: sent`; notify-gateway: `visibility.<uid>.feed === true`)
  uncertain    the call happened and might have landed (transport timeout, unreadable answer).
               Treated exactly like `sent` for dedupe: a second copy of a status line is worse
               than none, so it is only ever re-offered by a human.
  rejected     the provider answered "nothing landed" (4xx/5xx, refused, suppressed).
  unconfirmed  the bell answered with every visibility flag false: the item reached nobody
               (that is what an all-false `visibility` MEANS — the user's clients do not read
               our bell yet). The driver then still climbs the Intercom rung.

The contracts here are the providers', not guesses (a confirmation written against the wrong
schema reads every real send as unconfirmed — that is the core-backend #11075 lesson):

  intercom       POST https://api.intercom.io/messages  -> an object with `id`
  send-gateway   POST http://127.0.0.1:PORT/v1/send inside the pod -> {id, status, gate, reason}
  notify-gateway POST http://127.0.0.1:PORT/v1/workflows/:key/trigger inside the pod, Knock-shaped
                 body {recipients:[user_id], data:{...}} + Idempotency-Key, Bearer
                 $NOTIFY_SERVICE_TOKEN -> {workflow_run_id, visibility?}   (muso-messaging
                 services/notify-gateway/src/server.ts; the same call its own drill makes in
                 scripts/ops/status-bell-check.sh --trigger)

Nothing leaves node-8 for the last two: the POST happens inside the pod through `kubectl exec`,
which is how every other hydra sender reaches them (scripts/paid-status/email_route.py).
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

INTERCOM = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
SEND_GATEWAY_POD = ("kubectl", "-n", "messaging", "get", "pod", "-l",
                    "app.kubernetes.io/name=send-gateway", "--field-selector=status.phase=Running", "-o", "name")
NOTIFY_GATEWAY_POD = ("kubectl", "-n", "messaging", "get", "pod", "-l",
                      "app.kubernetes.io/name=notify-gateway", "--field-selector=status.phase=Running", "-o", "name")


@dataclass
class SendResult:
    status: str                      # sent | uncertain | rejected | unconfirmed
    channel: str
    reason: str = ""
    ref: str = ""                    # the provider's message id / workflow run id
    body_sha: str = ""
    answer: dict[str, Any] = field(default_factory=dict)


def body_sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def copy_hold(typ: str, state: str, body: str, subject: str = "", frame: str = "") -> str:
    """'' when the outbound copy gate (captain 2026-11-12) approved these exact bytes, else why nothing is sent.

    Asked for every body WE write (the Intercom message, the status line an email template renders). A bell's
    words are notify-gateway's catalog, not ours, so there is nothing of ours to review there. A hold is a
    `rejected` send: nothing left, and the next tick asks again.

    `frame` names what the body is sent IN, and the verdict is bound to it: "intercom" for a message that is the
    whole of what the person reads, "email-template:<key>@<sha256>" for a status line send-gateway places into that
    template. The same line approved for one frame is not approved for another. The template's own fixed words
    (subject, greeting, sign-off) live in send-gateway, outside this repo, so the frame carries the sha256 of the
    template source that was reviewed (`channels.email.template_sha256` in the policy, computed by
    `template_source_sha256`), and SEND_JS re-computes it from the live template in the pod before every send: a
    template whose words changed posts nothing until it is reviewed and re-pinned, and a new pin is a new frame that
    no earlier verdict covers."""
    campaign = f"request-{typ}-{state}" if typ and state else "request-status"
    try:
        _copy_gate().require(campaign, body, subject=subject, copy=frame)
    except Exception as exc:  # noqa: BLE001 - CopyHeld, or a gate that could not even be loaded: both hold
        return str(exc)[:300] if str(exc).startswith("copy_review_hold") else f"copy_review_hold: {type(exc).__name__}"
    return ""


def email_template_pin(policy: dict, key: str) -> str:
    """The sha256 of the reviewed send-gateway template source for `key`, or '' when the policy records none."""
    pins = ((policy.get("channels") or {}).get("email") or {}).get("template_sha256") or {}
    pin = str(pins.get(key) or "").strip().lower() if isinstance(pins, dict) else ""
    return pin if len(pin) == 64 and all(c in "0123456789abcdef" for c in pin) else ""


def template_source_sha256(templates_dir: str | Path, key: str) -> str:
    """The pin for one send-gateway template: sha256 over its subject, preview text, html source and text source,
    each prefixed with its byte length. Run it on the reviewed checkout of the gateway's `templates/` directory and
    record the answer in `channels.email.template_sha256.<key>`; SEND_JS computes the same hash in the pod before
    every send and posts nothing when the two differ.

        python3 -c 'import sys; sys.path.insert(0, "scripts"); from request_comms.channels import \
            template_source_sha256 as f; print(f(sys.argv[1], sys.argv[2]))' <templates-dir> <key>
    """
    root = Path(templates_dir)
    found = [k[key] for k in (json.loads((root / f).read_text(encoding="utf-8")).get("keys") or {}
                              for f in ("registry.json", "native.json")) if key in k]
    if len(found) != 1:
        raise ValueError(f"{len(found)} entries for template {key!r}")
    e = found[0]
    if not all(isinstance(e.get(f), str) for f in ("subject", "html", "text")):
        raise ValueError(f"template {key!r}: entry shape")
    h = hashlib.sha256()
    for part in (e["subject"].encode("utf-8"), str(e.get("preview_text") or "").encode("utf-8"),
                 (root / e["html"]).read_bytes(), (root / e["text"]).read_bytes()):
        h.update(f"{len(part)}:".encode("ascii"))
        h.update(part)
    return h.hexdigest()


def _copy_gate():
    import importlib.util  # noqa: PLC0415
    import sys  # noqa: PLC0415
    name = "hydra_lib_copy_gate"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(
            name, Path(__file__).resolve().parents[1] / "lib" / "copy_gate.py")
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
    return sys.modules[name]


def to_html(text: str) -> str:
    """Paragraphs only: the approved copy is plain sentences, and nothing typed by a customer or
    an agent is ever interpolated into it."""
    return "".join(f"<p>{html.escape(p)}</p>" for p in text.split("\n\n") if p.strip())


def _pod_json(argv: tuple[str, ...], payload: dict[str, Any], js: str, ns: str = "messaging",
              timeout: int = 90) -> dict[str, Any]:
    """Run one JSON-in/JSON-out call inside a pod and return the last JSON line it printed."""
    try:
        g = subprocess.run(list(argv), capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"status": "rejected", "reason": f"kubectl get pod: {type(exc).__name__}"}
    pods = g.stdout.split() if g.returncode == 0 else []
    if not pods:
        return {"status": "rejected", "reason": f"no running pod (kubectl rc={g.returncode})"}
    try:
        p = subprocess.run(["kubectl", "-n", ns, "exec", "-i", pods[0], "--", "node", "-e", js],
                           input=json.dumps(payload), capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"status": "uncertain", "reason": f"kubectl exec: {type(exc).__name__}"}
    for line in reversed((p.stdout or "").strip().splitlines()):
        try:
            ans = json.loads(line)
        except ValueError:
            continue
        if isinstance(ans, dict):
            return ans
    if p.returncode:
        # The exec RAN, so its POST may have reached the provider before it died. "rejected" means
        # "definitely not delivered" and the driver climbs to the next rung and retries this one on
        # the next tick — which sends the user two updates. Ambiguity must stay `uncertain`.
        return {"status": "uncertain",
                "reason": f"kubectl exec rc={p.returncode} after the call: {(p.stderr or '').strip()[-120:]}"}
    return {"status": "uncertain", "reason": "no parseable answer from the pod"}


# THE TEMPLATE PIN IS CHECKED HERE, IN THE POD, IN THE SAME PROCESS THAT POSTS (QA review of hydra#1895).
# The reviewer's verdict covers the status line; the words around it (subject, preview, the html and text bodies) are
# the gateway's template, baked into its image under TEMPLATES_DIR. Before the POST this script hashes the live
# template source for the key and compares it with the pin the verdict's frame names. A mismatch, a missing pin or a
# template it cannot read is a definite non-delivery: nothing was posted. One exec, one pod, so the template that was
# hashed is the one that pod renders (a second exec could land on another pod mid-rollout).
# The hash is `template_source_sha256` below; keep the two byte-identical in meaning (a test runs both).
SEND_JS = r"""
let s='';process.stdin.on('data',d=>s+=d).on('end',async()=>{
 const fs=require('fs'),path=require('path'),crypto=require('crypto');
 const no=(reason,extra)=>console.log(JSON.stringify({status:'rejected',reason,...(extra||{})}));
 let p;try{p=JSON.parse(s);}catch(e){return no('unreadable payload');}
 const want=String(p._template_sha256||'');delete p._template_sha256;
 if(!/^[0-9a-f]{64}$/.test(want))return no('template_pin_missing');
 let live;
 try{const dir=process.env.TEMPLATES_DIR||path.resolve(process.cwd(),'..','..','templates');
  const rd=f=>JSON.parse(fs.readFileSync(path.join(dir,f),'utf8')).keys||{};
  const key=String(p.key||'');
  const found=[rd('registry.json'),rd('native.json')].filter(k=>Object.prototype.hasOwnProperty.call(k,key));
  if(found.length!==1)return no('template_unreadable: '+found.length+' entries for the key');
  const e=found[0][key];
  if(typeof e.subject!=='string'||typeof e.html!=='string'||typeof e.text!=='string')return no('template_unreadable: entry shape');
  const h=crypto.createHash('sha256');
  for(const part of [Buffer.from(e.subject,'utf8'),Buffer.from(String(e.preview_text||''),'utf8'),
                     fs.readFileSync(path.join(dir,e.html)),fs.readFileSync(path.join(dir,e.text))]){
   h.update(String(part.length)+':');h.update(part);}
  live=h.digest('hex');
 }catch(e){return no('template_unreadable: '+String(e.code||e.name||'error'));}
 if(live!==want)return no('template_pin_mismatch',{live_template_sha256:live});
 const tok=(process.env.INTERNAL_TOKENS||'').split(',').map(x=>x.trim()).find(x=>x.startsWith('admin:'));
 if(!tok){console.log(JSON.stringify({status:'rejected',reason:'no admin caller token in the pod'}));return;}
 try{const r=await fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/v1/send',{method:'POST',
  headers:{'content-type':'application/json',authorization:'Bearer '+tok.slice(6)},body:JSON.stringify(p)});
  const b=await r.json().catch(()=>({}));
  console.log(JSON.stringify({http:r.status,id:b.id,status:b.status,gate:b.gate,reason:b.reason||b.error}));}
 catch(e){console.log(JSON.stringify({status:'uncertain',reason:'fetch '+e.message}));}});
"""

# notify-gateway authenticates EVERY route but /healthz, /readyz and /metrics with one `onRequest`
# hook: `authorization: Bearer $NOTIFY_SERVICE_TOKEN` (server.ts). A wrong token is a 401 before the
# route is reached, so a 401 is a definite non-delivery, never an "uncertain". The body is
# Knock-shaped — `recipients` is REQUIRED and the status kinds answer `visibility` keyed by user id.
NOTIFY_JS = r"""
let s='';process.stdin.on('data',d=>s+=d).on('end',async()=>{
 const tok=process.env.NOTIFY_SERVICE_TOKEN||'';
 if(!tok){console.log(JSON.stringify({status:'rejected',reason:'no NOTIFY_SERVICE_TOKEN in the pod'}));return;}
 try{const p=JSON.parse(s);
  const r=await fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/v1/workflows/'+encodeURIComponent(p.key)+'/trigger',
   {method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+tok,
     ...(p.idempotency_key?{'idempotency-key':p.idempotency_key}:{})},body:JSON.stringify(p.body)});
  const b=await r.json().catch(()=>({}));
  console.log(JSON.stringify({http:r.status,workflow_run_id:b.workflow_run_id,visibility:b.visibility,
    reason:b.reason||b.error||b.message}));}
 catch(e){console.log(JSON.stringify({status:'uncertain',reason:'fetch '+e.message}));}});
"""


class Channels:
    """Injectable adapters. `intercom_post`, `send_gateway` and `notify_gateway` are the seams the
    tests drive; production defaults are the pod/HTTP calls below."""

    def __init__(self, *, policy: dict[str, Any], token: str = "",
                 intercom_post: Callable[[str, str, dict[str, Any] | None], dict[str, Any]] | None = None,
                 send_gateway: Callable[[dict[str, Any]], dict[str, Any]] | None = None,
                 notify_gateway: Callable[[str, dict[str, Any], str], dict[str, Any]] | None = None) -> None:
        self.policy = policy
        self.token = token or os.environ.get("MUSOAI_INTERCOM_TOKEN", "")
        self._intercom_post = intercom_post or self._intercom_http
        self._send_gateway = send_gateway or (lambda payload: _pod_json(SEND_GATEWAY_POD, payload, SEND_JS))
        self._notify_gateway = notify_gateway or (lambda key, body, idem="": _pod_json(
            NOTIFY_GATEWAY_POD, {"key": key, "body": body, "idempotency_key": idem}, NOTIFY_JS))

    # ---------- intercom ----------
    @staticmethod
    def _intercom_http(method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        tok = os.environ.get("MUSOAI_INTERCOM_TOKEN", "")
        if not tok:
            raise RuntimeError("no Intercom token")
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(INTERCOM + path, data=data, method=method, headers={
            "Authorization": f"Bearer {tok}", "Accept": "application/json",
            "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)

    def intercom(self, text: str, contact_id: str, *, admin_id: str,
                 conversation_id: str = "", typ: str = "", state: str = "") -> SendResult:
        conf = (self.policy.get("channels") or {}).get("intercom") or {}
        msg_type = str(conf.get("message_type") or "email")
        if conversation_id:
            # Reply ON the requester's own thread. The approved erasure acknowledgement promises
            # "Written confirmation on this thread" and the reference doc says "first reply, same
            # conversation, always"; a new outbound message would leave the thread they wrote on
            # unanswered while a second one appeared beside it. A reply is a `comment` from an
            # admin, not a `message` with a template and a subject.
            path = f"/conversations/{urllib.parse.quote(conversation_id, safe='')}/reply"
            payload: dict[str, Any] = {"message_type": "comment", "type": "admin",
                                       "admin_id": admin_id, "body": to_html(text)}
        else:
            path = "/messages"
            payload = {"message_type": msg_type, "from": {"type": "admin", "id": admin_id},
                       "to": {"type": "user", "id": contact_id}, "body": to_html(text)}
            if msg_type != "inapp":
                payload["template"] = "personal"
                payload["subject"] = str(conf.get("subject") or "Your Muso request")
        held = copy_hold(typ, state, payload["body"], str(payload.get("subject") or ""), frame="intercom")
        if held:
            return SendResult("rejected", "intercom", held, body_sha=body_sha(text))
        try:
            ans = self._intercom_post("POST", path, payload)
        except urllib.error.HTTPError as exc:
            # A 4xx is Intercom refusing the call before it created anything (401 bad token, 422
            # bad body, 429 rate limit). A 5xx is NOT proof of non-delivery: the message can be
            # created and the answer still fail, and `rejected` would let the driver climb or the
            # next tick retry and send a second copy. Same rule as the bell.
            if 400 <= exc.code < 500:
                return SendResult("rejected", "intercom", f"intercom {exc.code}", body_sha=body_sha(text))
            return SendResult("uncertain", "intercom", f"intercom {exc.code}", body_sha=body_sha(text))
        except (urllib.error.URLError, TimeoutError, ValueError, RuntimeError) as exc:
            return SendResult("uncertain", "intercom", f"{type(exc).__name__}", body_sha=body_sha(text))
        mid = str((ans or {}).get("id") or "")
        return SendResult("sent" if mid else "uncertain", "intercom",
                          "" if mid else "no message id in the answer", mid, body_sha(text), ans or {})

    # ---------- email (send-gateway) ----------
    def email(self, text: str, *, email: str, user_id: str, typ: str, request_ref: str,
              idempotency_key: str = "", state: str = "") -> SendResult:
        keys = ((self.policy.get("channels") or {}).get("email") or {}).get("template_keys") or {}
        key = str(keys.get(typ) or "").strip()
        if not key:
            return SendResult("rejected", "email", f"no template key for {typ}", body_sha=body_sha(text))
        pin = email_template_pin(self.policy, key)
        if not pin:
            # No recorded hash of the reviewed template = nobody can say which words surround the line.
            return SendResult("rejected", "email", f"copy_review_hold: email_template_unpinned:{key}",
                              body_sha=body_sha(text))
        held = copy_hold(typ, state, text, frame=f"email-template:{key}@{pin}")
        if held:
            return SendResult("rejected", "email", held, body_sha=body_sha(text))
        # The send-gateway renders the TEMPLATE for `key`; a payload of just a key could send copy
        # nobody approved while our ledger hashed the approved sentence. So the approved line
        # travels with the payload (`data.event.status_line`, rendered by `{{event.status_line}}`)
        # and the policy must declare that its templates use it (`template_uses_line_text`).
        payload = {"key": key, "to": {"email": email, "user_id": str(user_id)},
                   "data": {"event": {"status_line": text, "state": state, "request_type": typ,
                                      "request_ref": request_ref}},
                   # A STATE-AND-CYCLE key from the caller: keying on the ref alone makes the 48 h
                   # reminder about the same request look like a retry of the first letter.
                   "idempotency_key": idempotency_key or f"request-status:{request_ref}",
                   # Not a gateway field: SEND_JS strips it, hashes the live template in the pod and posts only
                   # when it is this hash - the one the verdict's frame names.
                   "_template_sha256": pin}
        ans = self._send_gateway(payload)
        if str(ans.get("reason") or "").startswith(("template_pin_", "template_unreadable")):
            # The pod refused before posting: the template it would render is not the one that was reviewed.
            return SendResult("rejected", "email", f"copy_review_hold: {str(ans.get('reason'))[:200]}",
                              body_sha=body_sha(text), answer=ans)
        st = str(ans.get("status") or "")
        if st == "sent":
            return SendResult("sent", "email", "", str(ans.get("id") or ""), body_sha(text), ans)
        if st in ("uncertain", "unconfirmed", "sent_unrecorded"):
            # `uncertain` from the transport (a lost reply, a timeout) is a MAYBE, never a rejection.
            return SendResult("uncertain", "email", st, str(ans.get("id") or ""), body_sha(text), ans)
        http = ans.get("http")
        if isinstance(http, int) and 200 <= http < 300 and not st:
            # A 2xx we could not READ (empty or malformed body -> the adapter keeps only the status
            # code) is the same maybe as a lost reply: the gateway may well have queued the letter.
            # Classified as `rejected` this would send a second copy on the next tick, or fall
            # through to another rung, breaking the one-message-per-person-per-day promise.
            return SendResult("uncertain", "email", "2xx with an unreadable body",
                              str(ans.get("id") or ""), body_sha(text), ans)
        if isinstance(http, int) and 200 <= http < 300 and st and st != "failed":
            # The gateway ANSWERED and declined (suppressed / unsubscribed / bounced / opted out).
            return SendResult("rejected", "email", str(ans.get("reason") or ans.get("gate") or "gateway declined"),
                              "", body_sha(text), ans)
        if isinstance(http, int) and http >= 500:
            # The gateway can fail AFTER it has queued the letter. `rejected` would let the next
            # tick send a second copy, and the retry carries a NEW idempotency epoch, so the
            # gateway cannot dedupe it either. Same rule as the bell and Intercom.
            return SendResult("uncertain", "email", str(ans.get("reason") or f"http {http}"),
                              str(ans.get("id") or ""), body_sha(text), ans)
        return SendResult("rejected", "email", str(ans.get("reason") or st or "send-gateway failed"),
                          "", body_sha(text), ans)

    # ---------- bell (notify-gateway) ----------
    def bell(self, workflow_key: str, *, user_id: str, data: dict[str, Any],
             idempotency_key: str = "") -> SendResult:
        """Trigger ONE status bell for ONE user.

        The WORDS are not ours here: each kind's copy lives in notify-gateway's catalog
        (`statusBell(...)` in services/notify-gateway/workflows/catalog.ts) and is rendered from
        `data`. `data.profile.name` is the one value the copy interpolates, so the caller must
        always supply it — see `request_comms.routing.bell_data`.
        """
        from .routing import BELL_KEYS  # noqa: PLC0415 — the pin is routing's, checked here too

        key = str(workflow_key or "").strip()
        text = json.dumps(data, sort_keys=True, ensure_ascii=False)      # the hashed body of record
        if not key:
            return SendResult("rejected", "bell", "no bell workflow key for this state", body_sha=body_sha(text))
        if key not in BELL_KEYS:
            # Verified live 2026-11-03: the gateway answers 200 + a workflow_run_id for a key that
            # is not one of its kinds, and no `visibility` with it. Sending a typo therefore looks
            # like "maybe" forever; refuse it here, where the pin lives.
            return SendResult("rejected", "bell", f"not one of the ten status bells: {key}",
                              body_sha=body_sha(text))
        body = {"recipients": [str(user_id)], "data": dict(data)}
        ans = self._notify_gateway(key, body, idempotency_key)
        st = str(ans.get("status") or "")
        run = str(ans.get("workflow_run_id") or "")
        if not run:
            # No run id is only a DEFINITE non-delivery when we know the call never landed. Two
            # cases prove that: the node script prints `status:"rejected"` BEFORE its POST (no
            # service token), and a 4xx is the gateway refusing the call before the route ran (401
            # on the service token, 400 on the body).
            http = ans.get("http")
            if st == "rejected":
                return SendResult("rejected", "bell", str(ans.get("reason") or st),
                                  "", body_sha(text), ans)
            if isinstance(http, int) and 400 <= http < 500:
                return SendResult("rejected", "bell", str(ans.get("reason") or f"http {http}"),
                                  "", body_sha(text), ans)
            # A 5xx is NOT proof of non-delivery: the gateway can fail AFTER it has enqueued the
            # run, and `rejected` would let the driver climb to Intercom and send the same update
            # twice. `uncertain` stops the ladder and blocks the next tick, which is the honest
            # answer to "we do not know". Same for a lost reply, a killed exec, or a 2xx whose
            # body we could not parse.
            why = "2xx with an unreadable body" if isinstance(http, int) and 200 <= http < 300 else (
                str(ans.get("reason") or st or (f"http {http}" if isinstance(http, int)
                                                else "no answer from the gateway")))
            return SendResult("uncertain", "bell", why, "", body_sha(text), ans)
        vis = ans.get("visibility")
        if isinstance(vis, dict) and vis:
            mine = vis.get(str(user_id)) if str(user_id) in vis else {}
            # `visibility` is keyed by user id and carries one flag per delivery surface the
            # gateway knows about — `feed` (the in-app bell), `knock` (the Knock leg) and `push`
            # (a device push). The gateway's contract is that ALL-FALSE means the item reached
            # nobody, so ANY true is a confirmed delivery. Checking only `feed` read a real push
            # as "reached nobody" and climbed to Intercom, sending the same update twice — and
            # today most users are exactly that shape, because the web reads Knock and the app
            # builds that read our bell are not released.
            legs = sorted(k for k, v in mine.items() if v is True) if isinstance(mine, dict) else []
            if legs:
                return SendResult("sent", "bell", "", run, body_sha(text), ans)
            return SendResult("unconfirmed", "bell",
                              f"no delivery leg is true ({json.dumps(mine)[:80]}): the bell reached nobody",
                              run, body_sha(text), ans)
        if vis is None:
            # No visibility block at all: the gateway answered without the status-kind contract.
            return SendResult("uncertain", "bell", "no visibility block in the answer", run, body_sha(text), ans)
        return SendResult("unconfirmed", "bell", f"visibility is empty: {json.dumps(vis)[:80]}",
                          run, body_sha(text), ans)
