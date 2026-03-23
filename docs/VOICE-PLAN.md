# HYDRA Voice — Talk to Your Agents

> **Version**: 2.0 | **Date**: 2026-03-23 | **Author**: Aaron (adk47)
>
> Voice interface for HYDRA agents. Self-hosted, CPU-only, $0/month additional cost.

---

## Table of Contents

1. [Problem](#problem)
2. [Solution Architecture](#solution-architecture)
3. [Tech Stack](#tech-stack)
4. [Integration with Existing HYDRA](#integration-with-existing-hydra)
5. [Hardware Budget](#hardware-budget)
6. [Networking & Security](#networking--security)
7. [Phase 1: PoC — CLI Voice Pipeline](#phase-1-poc--cli-voice-pipeline)
8. [Phase 2: Web Client + Slack Integration](#phase-2-web-client--slack-integration)
9. [Phase 3: Production Hardening](#phase-3-production-hardening)
10. [Phase 4: Polish](#phase-4-polish)
11. [K8s Manifest Requirements](#k8s-manifest-requirements)
12. [File & Directory Layout](#file--directory-layout)
13. [Configuration Reference](#configuration-reference)
14. [Rollback Plan](#rollback-plan)
15. [Verification Criteria](#verification-criteria)

---

## Problem

Slack Huddles **do not support bot voice**. The Slack Calls API is metadata-only (no audio streaming). No cloud voice API (OpenAI Realtime, ElevenLabs, Ultravox) can inject audio into a Huddle. We need voice conversations with HYDRA agents using an alternative transport.

**Existing TTS config in `openclaw.json`**: ElevenLabs is already configured (`"auto": "off"`, voice `NtS6nEHDYMQC9QczMQuq`). This is for text-to-audio-clip generation, not real-time voice. HYDRA Voice replaces this with streaming WebRTC.

---

## Solution Architecture

```
Slack (text)                              Voice (WebRTC)
    │                                          │
    │  User: "@Clio let's talk"               │  User clicks voice link
    │                                          │
    ▼                                          ▼
┌──────────────────┐                   ┌────────────────────────────────┐
│ HYDRA Agent      │ ─ posts link ──▶  │ Web UI (browser)               │
│ (OpenClaw)       │                   │ hydra-voice.ak.muso.ai         │
│ Slack Socket Mode│                   └────────────┬───────────────────┘
└──────────────────┘                                │ WebRTC (DTLS-SRTP)
                                                    │ UDP + TURN fallback
                                                    ▼
                                       ┌────────────────────────────────┐
                                       │ Pipecat Voice Server (Node 8)  │
                                       │                                │
                                       │  ┌──────────────────────────┐  │
                                       │  │ 1. VAD (Silero)          │  │
                                       │  │    Voice Activity Detect  │  │
                                       │  └──────────┬───────────────┘  │
                                       │             ▼                  │
                                       │  ┌──────────────────────────┐  │
                                       │  │ 2. STT (faster-whisper)  │  │
                                       │  │    CPU, base.en model    │  │
                                       │  │    ~1-2s latency         │  │
                                       │  └──────────┬───────────────┘  │
                                       │             ▼                  │
                                       │  ┌──────────────────────────┐  │
                                       │  │ 3. LLM (CLIProxyAPI)    │  │
                                       │  │    → Claude Opus/Sonnet  │  │
                                       │  │    Uses agent workspace  │  │
                                       │  │    ~1-3s latency         │  │
                                       │  └──────────┬───────────────┘  │
                                       │             ▼                  │
                                       │  ┌──────────────────────────┐  │
                                       │  │ 4. TTS (Piper via       │  │
                                       │  │    sherpa-onnx)          │  │
                                       │  │    CPU ONNX runtime      │  │
                                       │  │    ~0.2s latency         │  │
                                       │  └──────────┬───────────────┘  │
                                       │             ▼                  │
                                       │  ┌──────────────────────────┐  │
                                       │  │ 5. WebRTC Audio Out     │  │
                                       │  │    Opus codec, 48kHz     │  │
                                       │  └──────────────────────────┘  │
                                       │                                │
                                       │  Total round-trip: ~2-4s       │
                                       └────────────────────────────────┘
                                                    │
                                                    ▼ (on call end)
                                       ┌────────────────────────────────┐
                                       │ Post summary to Slack thread   │
                                       │ Log to hydra-audit             │
                                       └────────────────────────────────┘
```

**Key insight**: Voice happens in a lightweight web page, not Slack. The Slack integration is limited to: (a) detecting "let's talk" trigger, (b) posting the voice link, (c) logging the summary after the call.

---

## Tech Stack

| Component | Tool | Version | License | Repo |
|-----------|------|---------|---------|------|
| **Orchestrator** | Pipecat | ≥0.0.47 | Apache 2.0 | `pipecat-ai/pipecat` |
| **STT** | faster-whisper | ≥1.1.0 | MIT | `SYSTRAN/faster-whisper` |
| **STT model** | Whisper `base.en` | — | MIT | OpenAI (74M params, CPU-friendly) |
| **VAD** | Silero VAD | v5 | MIT | bundled with Pipecat |
| **TTS** | Piper via sherpa-onnx | ≥1.10 | Apache 2.0 | `k2-fsa/sherpa-onnx` |
| **TTS voice** | `en_US-amy-medium` | — | MIT | `rhasspy/piper` voices |
| **WebRTC** | Daily (Pipecat transport) | — | — | `daily-co/daily-python` |
| **Web UI** | Vanilla HTML/JS | — | — | Custom (~200 lines) |
| **Reverse proxy** | Caddy or Traefik (existing) | — | — | Already in cluster |
| **LLM** | Claude via CLIProxyAPI | — | — | `localhost:8317` (existing) |

### Why Pipecat over LiveKit Agents

| Criteria | Pipecat | LiveKit Agents |
|----------|---------|----------------|
| Self-hosted, no account needed | Yes (Daily self-hosted or local transport) | Yes |
| CPU-only STT/TTS | First-class (faster-whisper + Piper built-in) | Possible but not primary |
| Python, simple pipeline DSL | Yes | Yes |
| WebRTC transport | Via Daily or raw WebRTC | Via LiveKit server |
| Extra infra required | None (single Python process) | LiveKit media server (Go binary) |
| Community / maturity | Smaller but focused | Larger, more complex |

**Decision**: Pipecat — simpler, fewer moving parts, direct integration with faster-whisper and Piper. No additional media server process needed.

### Alternative: Pipecat with Local WebRTC (No Daily)

Pipecat supports `SmallWebRTCTransport` for fully self-hosted WebRTC without Daily's cloud service. This is the preferred approach since we want zero external dependencies.

```
pipecat[silero,webrtc,openai]  →  SmallWebRTCTransport (built-in TURN)
```

If `SmallWebRTCTransport` proves unreliable, fall back to Daily's free tier (10,000 participant-minutes/month — enough for internal use).

---

## Integration with Existing HYDRA

### CLIProxyAPI (LLM Backend)

The voice pipeline calls Claude through the **same CLIProxyAPI sidecar** that text agents use:

- **Endpoint**: `http://localhost:8317/v1/messages` (inside the pod) or `http://openclaw-gateway.hydra.svc:8317` (from a separate pod)
- **Auth**: `ANTHROPIC_API_KEY` from Vault (same as text agents)
- **Agent identity**: Pass `X-Agent-ID: {agent_id}` header so CLIProxyAPI logs voice interactions per-agent
- **Model**: Use the agent's configured model from `openclaw.json` (e.g., Clio uses Opus, DevOps uses Sonnet)

### Agent Workspace Context

Each voice session must know **which agent** the user is talking to. The Pipecat pipeline loads the agent's `SOUL.md` as the system prompt so the agent maintains its identity and rules in voice mode. The voice server reads from the same `/app/workspaces/{agent_id}/` volume.

### Slack Integration Hook

OpenClaw needs a trigger handler. When an agent detects phrases like "let's talk", "voice call", "can we talk", it:

1. Calls the voice session API: `POST http://hydra-voice.hydra.svc:8088/session/create`
   ```json
   {
     "agent_id": "clio",
     "slack_user_id": "U7RP6HKUZ",
     "slack_thread_ts": "1711152000.000001",
     "slack_channel_id": "C08GZPWAKBJ"
   }
   ```
2. Gets back a session URL: `https://hydra-voice.ak.muso.ai/session/{session_id}`
3. Posts the link in the Slack thread

This requires adding a **voice trigger skill** to each agent's workspace. The skill is a simple pattern match + HTTP call — implemented as a workspace skill file, not application code.

### Audit Trail

Voice sessions produce audit events identical to text interactions:
- **Start**: `voice_session_started` (agent, user, timestamp)
- **Each turn**: `voice_turn` (transcribed user text, agent response text, latency_ms)
- **End**: `voice_session_ended` (duration, turn_count, summary)

These are written to the same `hydra-audit-buffer` PVC and pushed hourly to `Muso-AI/hydra-audit` via the existing eDiscovery CronJob.

---

## Hardware Budget

**Node 8**: AMD EPYC 4464P (16c/32t), 64GB RAM, 2x960GB NVMe

### Current Usage (OpenClaw + CLIProxyAPI)

| Component | CPU Request | CPU Limit | RAM Request | RAM Limit |
|-----------|-------------|-----------|-------------|-----------|
| OpenClaw Gateway | 4 cores | 12 cores | 16 GB | 48 GB |
| CLIProxyAPI sidecar | 500m | 1 core | 512 MB | 1 GB |
| **Subtotal** | **4.5 cores** | **13 cores** | **16.5 GB** | **49 GB** |

### Voice Pipeline Addition

| Component | CPU (steady) | CPU (during inference) | RAM |
|-----------|-------------|----------------------|-----|
| Pipecat server | 0.5 cores | 0.5 cores | 256 MB |
| faster-whisper (base.en) | 0.5 cores idle | 2-4 cores (during transcription) | 500 MB |
| Piper TTS (sherpa-onnx) | 0.1 cores idle | 1-2 cores (during synthesis) | 200 MB |
| Silero VAD | negligible | 0.1 cores | 50 MB |
| WebRTC media | 0.5 cores per session | 0.5 cores per session | 100 MB/session |
| **Subtotal (1 session)** | **~1.6 cores** | **~5 cores peak** | **~1.1 GB** |
| **Subtotal (3 sessions)** | **~2.6 cores** | **~7 cores peak** | **~1.5 GB** |

### Total with Voice

| | CPU Request | CPU Limit | RAM Request | RAM Limit |
|--|-------------|-----------|-------------|-----------|
| OpenClaw + CLIProxyAPI | 4.5 | 13 | 16.5 GB | 49 GB |
| Voice (3 sessions) | 2 | 8 | 2 GB | 4 GB |
| **Total** | **6.5** | **21** | **18.5 GB** | **53 GB** |

Node 8 has 16c/32t and 64GB. CPU limits exceed physical cores, but that's fine — they won't all peak simultaneously. The K8s scheduler uses **requests** for placement decisions:
- CPU requests: 6.5/16 = 40% → comfortable
- RAM requests: 18.5/64 = 29% → comfortable

**Verdict**: Node 8 can handle OpenClaw + 3 concurrent voice sessions without contention. For 5+ sessions, consider adding a dedicated voice worker on node-5 (data-read, which has spare capacity outside pipeline runs).

---

## Networking & Security

### Port Requirements

| Port | Protocol | Direction | Purpose | Exposure |
|------|----------|-----------|---------|----------|
| 8088 | TCP | Ingress (cluster) | Voice session API (create/status/end) | ClusterIP only |
| 8089 | TCP | Ingress (external) | WebRTC signaling (HTTPS) | Via Ingress → Cloudflare |
| 10000-10100 | UDP | Ingress (external) | WebRTC media (SRTP) | NodePort on Node 8 |
| 3478 | UDP/TCP | Ingress (external) | TURN relay (for NAT traversal) | NodePort on Node 8 |
| 8317 | TCP | Egress (localhost) | CLIProxyAPI (existing) | Pod-internal only |

### WebRTC NAT Traversal

WebRTC requires direct UDP connectivity between browser and server. Since Node 8 has a public IP (40.160.32.80), most clients will connect directly via STUN. For clients behind strict NATs/firewalls, a TURN server is needed.

**TURN options** (pick one):
1. **coturn** (self-hosted, free) — lightweight TURN server, ~50MB RAM, runs as a sidecar or separate pod
2. **Pipecat built-in TURN** — `SmallWebRTCTransport` includes a basic TURN relay
3. **Cloudflare TURN** — Free tier available, no self-hosting

**Recommendation**: Start with Pipecat's built-in TURN. Add coturn only if users report connectivity issues from restrictive networks.

### DNS

| Record | Type | Value | Proxy |
|--------|------|-------|-------|
| `hydra-voice.ak.muso.ai` | CNAME | `ovh-node-8.ak.muso.ai` or direct A record | Cloudflare proxied (HTTPS only) |

**Note**: Cloudflare proxy terminates TLS for the signaling endpoint (port 8089/443). WebRTC media (UDP) must bypass Cloudflare — use a separate DNS record or Cloudflare Spectrum if needed. Simplest approach: signaling goes through Cloudflare (HTTPS), media connects directly to Node 8's public IP via STUN.

### Cilium Network Policy Additions

The existing `hydra` namespace has default-deny. Voice requires:

1. **Ingress from Traefik/Ingress controller** → voice pod on port 8089 (signaling)
2. **Ingress from external** → voice pod on UDP 10000-10100 (media) — via hostNetwork or NodePort
3. **Egress to CLIProxyAPI** → already allowed (pod-internal localhost)
4. **Egress to Cloudflare STUN** → `stun.cloudflare.com:3478` (UDP)

### Authentication

Voice sessions are authenticated by **Slack UID verification**:

1. Agent creates session with `slack_user_id` embedded
2. Voice web client receives a signed JWT (HMAC-SHA256, secret from Vault)
3. JWT contains: `session_id`, `agent_id`, `slack_user_id`, `exp` (15-minute TTL)
4. Pipecat server validates JWT before accepting WebRTC connection
5. No anonymous access — every voice session ties back to a Slack user

**Session lifecycle**:
- Max duration: 30 minutes (configurable)
- Idle timeout: 2 minutes of silence → auto-disconnect
- Cleanup: session state purged 5 minutes after disconnect

---

## Phase 1: PoC — CLI Voice Pipeline

**Goal**: Prove STT → LLM → TTS works on Node 8's CPU with acceptable latency.
**Duration**: ~1 week
**No web UI, no Slack integration, no K8s manifests yet.**

### Step 1: Install Dependencies on Node 8

SSH to Node 8 and set up a Python venv:

```bash
ssh root@10.0.0.8

# Create voice project directory
mkdir -p /opt/hydra-voice && cd /opt/hydra-voice

# Python 3.11+ venv
python3 -m venv venv
source venv/bin/activate

# Core dependencies
pip install \
  pipecat-ai[silero] \
  faster-whisper \
  sherpa-onnx \
  numpy \
  soundfile

# Download Whisper model (base.en — 74M params, ~150MB)
python3 -c "from faster_whisper import WhisperModel; WhisperModel('base.en', device='cpu', compute_type='int8')"

# Download Piper TTS voice (en_US-amy-medium)
mkdir -p models/piper
curl -L -o models/piper/en_US-amy-medium.onnx \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx
curl -L -o models/piper/en_US-amy-medium.onnx.json \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json
```

### Step 2: Test Each Component Independently

**Test STT (faster-whisper)**:
```bash
# Record 5s of audio (or use a sample .wav)
# Then transcribe:
python3 -c "
from faster_whisper import WhisperModel
import time

model = WhisperModel('base.en', device='cpu', compute_type='int8')
start = time.time()
segments, info = model.transcribe('test.wav', beam_size=5)
for seg in segments:
    print(f'[{seg.start:.1f}s → {seg.end:.1f}s] {seg.text}')
print(f'Latency: {time.time()-start:.2f}s')
"
```

**Target**: <2s for a 5-second utterance on CPU.

**Test TTS (Piper via sherpa-onnx)**:
```bash
python3 -c "
import sherpa_onnx
import time

tts = sherpa_onnx.OfflineTts(
    model=sherpa_onnx.OfflineTtsModelConfig(
        vits=sherpa_onnx.OfflineTtsVitsModelConfig(
            model='models/piper/en_US-amy-medium.onnx',
            tokens='models/piper/en_US-amy-medium.onnx.json',
        ),
    ),
    max_num_sentences=1,
)
start = time.time()
audio = tts.generate('Hello, I am Clio. How can I help you today?', sid=0, speed=1.0)
print(f'Generated {len(audio.samples)/audio.sample_rate:.1f}s of audio in {time.time()-start:.2f}s')
"
```

**Target**: <0.5s for a short sentence.

**Test LLM (CLIProxyAPI)**:
```bash
curl -s http://localhost:8317/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "X-Agent-ID: clio" \
  -d '{
    "model": "claude-sonnet-4-6",
    "max_tokens": 200,
    "system": "You are Clio, the coordinator of the HYDRA agent system. Keep responses concise for voice.",
    "messages": [{"role": "user", "content": "What is your role?"}]
  }' | python3 -m json.tool
```

### Step 3: End-to-End CLI Pipeline

Write a simple CLI script that chains: mic → STT → LLM → TTS → speaker. This validates the full loop without WebRTC complexity.

```
[mic input] → faster-whisper → text → CLIProxyAPI → response text → Piper → [speaker output]
```

Use `sounddevice` or `pyaudio` for mic/speaker I/O. This is throwaway code — the real pipeline will use Pipecat's transport layer.

### Step 4: Benchmark

Run 10 test utterances and record:

| Metric | Target | Measured |
|--------|--------|----------|
| STT latency (5s utterance) | <2s | |
| LLM latency (short response) | <2s | |
| TTS latency (1 sentence) | <0.5s | |
| Total round-trip | <4s | |
| STT accuracy (conversational English) | >90% WER | |
| CPU usage during inference | <8 cores | |
| RAM usage (all models loaded) | <2 GB | |

**If latency exceeds targets**:
- STT too slow → try `tiny.en` model (39M params, faster but less accurate)
- TTS too slow → try `en_US-amy-low` (lower quality, faster)
- LLM too slow → switch from Opus to Sonnet/Haiku for voice mode
- Overall → consider streaming TTS (start speaking before full LLM response)

### Phase 1 Deliverables

- [ ] Dependencies installed on Node 8
- [ ] faster-whisper base.en transcribes correctly on CPU
- [ ] Piper TTS generates intelligible speech on CPU
- [ ] CLIProxyAPI responds to voice-formatted prompts
- [ ] End-to-end CLI pipeline works
- [ ] Benchmark results documented
- [ ] Go/no-go decision for Phase 2

---

## Phase 2: Web Client + Slack Integration

**Goal**: Browser-based voice calls to HYDRA agents, triggered from Slack.
**Duration**: ~1-2 weeks
**Depends on**: Phase 1 benchmarks passing.

### Step 1: Pipecat Voice Server

Build the Pipecat pipeline as a Python service that:
- Listens for WebRTC connections via `SmallWebRTCTransport`
- Runs Silero VAD → faster-whisper STT → Claude LLM → Piper TTS
- Manages sessions (create, status, end)
- Exposes REST API for session management

**Key design decisions**:

| Decision | Choice | Rationale |
|----------|--------|-----------|
| WebRTC transport | `SmallWebRTCTransport` | Self-hosted, no external dependency |
| Session management | In-memory dict + cleanup thread | Simple, sufficient for 3-5 sessions |
| LLM integration | Custom Pipecat `LLMService` wrapping CLIProxyAPI | Reuse existing auth + logging |
| Agent identity | Load `SOUL.md` as system prompt per session | Same persona as text |
| Conversation history | In-memory per session, flush to audit on end | Keep voice turns for context |
| Streaming TTS | Yes — start speaking as LLM tokens arrive | Reduces perceived latency by ~1s |

**Streaming TTS detail**: Pipecat supports sentence-level streaming. As the LLM generates text, each complete sentence is sent to Piper immediately. The user hears the first sentence while the LLM is still generating the rest. This reduces perceived latency from ~4s to ~2-3s.

### Step 2: Web Client

Minimal HTML/JS page at `hydra-voice.ak.muso.ai/session/{session_id}`:

**Page elements**:
- Agent name + avatar (matches Slack bot avatar)
- "Connected to [Agent Name]" status
- Push-to-talk button (optional — VAD handles auto-detect)
- Audio visualizer (simple waveform, optional)
- "End Call" button
- Session timer

**No framework needed** — vanilla HTML + JS + WebRTC API. Keep it under 500 lines.

**WebRTC flow**:
1. Page loads → fetches session config from `/api/session/{id}`
2. Validates JWT (passed as URL param or cookie)
3. Creates `RTCPeerConnection` → sends offer to signaling endpoint
4. Server answers → ICE candidates exchanged
5. Media flows: browser mic → server STT → LLM → TTS → browser speaker
6. On disconnect → `POST /api/session/{id}/end` → triggers summary

### Step 3: Slack Trigger Integration

Add a **voice trigger skill** to each agent workspace. This is a workspace skill file that OpenClaw evaluates when it detects voice-related intent.

**Trigger phrases** (detected by the agent's LLM, not regex):
- "let's talk" / "can we talk" / "voice call" / "call me"
- "let's hop on a call" / "can I speak to you"

**Agent response flow**:
1. Agent detects voice intent in user message
2. Agent calls the voice session API (internal service)
3. Agent posts in Slack:
   > **Ready to talk.** Join the voice session:
   > https://hydra-voice.ak.muso.ai/session/abc123
   > _Session expires in 15 minutes. I'll post a summary here when we're done._

### Step 4: Deploy

**Docker image**: Build a `hydra-voice` image containing:
- Python 3.11 + venv with all deps
- Whisper base.en model (baked in, ~150MB)
- Piper amy-medium voice (baked in, ~60MB)
- Pipecat voice server code
- Web client static files (served by Pipecat's HTTP server or Caddy sidecar)

**K8s deployment**: Separate Deployment in `hydra` namespace (not a sidecar of OpenClaw — different lifecycle and resource profile).

**Ingress**: Add `hydra-voice.ak.muso.ai` to the existing Traefik IngressRoute or create a new one.

### Phase 2 Deliverables

- [ ] Pipecat voice server with WebRTC
- [ ] Web client page functional in Chrome/Safari/Firefox
- [ ] Slack trigger posts voice link
- [ ] Session create/join/end lifecycle works
- [ ] Audio quality is conversational (not robotic)
- [ ] 2 concurrent sessions work without degradation

---

## Phase 3: Production Hardening

**Goal**: Security, logging, reliability.
**Duration**: ~1 week

### Agent Identity in Voice

Each agent gets a distinct voice greeting and personality in voice mode:

| Agent | Greeting | Voice Speed | System Prompt Additions |
|-------|----------|-------------|------------------------|
| Clio (coordinator) | "Hello, I'm Clio. What would you like to discuss?" | 1.0x | "You are in voice mode. Keep responses concise — 2-3 sentences max unless asked to elaborate." |
| CEO | "Hi, this is the CEO agent. What's on your mind?" | 1.0x | Same conciseness rule |
| CTO | "Hey, CTO agent here. What are we looking at?" | 1.05x | May reference code — spell out variable names |
| DevOps | "DevOps agent, go ahead." | 1.0x | Speak IP addresses digit by digit |

**Voice prompt addition** (appended to each agent's SOUL.md context for voice sessions):
```
You are in a voice conversation. Rules:
- Keep responses to 2-3 sentences unless the user asks for detail
- Avoid markdown, bullet points, or formatting — speak naturally
- Spell out abbreviations (say "kubernetes" not "k-8-s")
- For numbers/IPs, speak them clearly (say "ten dot zero dot zero dot eight")
- If the user asks something complex, offer to send details to Slack instead
- Say "I'll send that to Slack" and post the detailed response in the original thread
```

### Conversation Logging

Every voice session produces an audit record:

```json
{
  "type": "voice_session",
  "session_id": "abc123",
  "agent_id": "clio",
  "slack_user_id": "U7RP6HKUZ",
  "slack_channel_id": "C08GZPWAKBJ",
  "slack_thread_ts": "1711152000.000001",
  "started_at": "2026-03-25T14:30:00Z",
  "ended_at": "2026-03-25T14:35:22Z",
  "duration_seconds": 322,
  "turns": [
    {
      "role": "user",
      "text": "What's the status of the data pipeline?",
      "timestamp": "2026-03-25T14:30:05Z",
      "stt_latency_ms": 1200
    },
    {
      "role": "agent",
      "text": "The data pipeline ran successfully at 6 AM today. All 47 DAGs completed without errors. The next run is scheduled for 6 PM.",
      "timestamp": "2026-03-25T14:30:08Z",
      "llm_latency_ms": 1800,
      "tts_latency_ms": 350
    }
  ],
  "summary": "User asked about data pipeline status. Agent confirmed all 47 DAGs ran successfully, next run at 6 PM.",
  "total_tokens": 1250,
  "model": "claude-sonnet-4-6"
}
```

Written to `/app/audit/voice/` directory, picked up by eDiscovery CronJob.

### Slack Summary Post

When a voice session ends, the agent posts a summary to the original Slack thread:

> **Voice session ended** (5m 22s, 8 turns)
>
> **Summary**: Discussed data pipeline status (all healthy), reviewed Trino query performance (p99 at 4.2s), and planned tomorrow's capacity test.
>
> _Full transcript available in audit log._

The summary is generated by Claude (using the conversation transcript as input) in a separate, cheap Haiku call.

### Security Hardening

1. **JWT validation**: Every WebRTC connection must present a valid JWT. Reject expired/invalid tokens immediately.
2. **Rate limiting**: Max 5 session creates per user per hour. Prevents abuse.
3. **Session isolation**: Each Pipecat pipeline runs in its own asyncio task with separate model context. No cross-session data leakage.
4. **No audio storage**: Audio is processed in-memory only. Only transcribed text is logged. No audio files written to disk.
5. **TURN credentials**: If using coturn, generate ephemeral TURN credentials per session (time-limited, user-specific).

### Error Handling

| Scenario | Behavior |
|----------|----------|
| WebRTC connection drops | Wait 10s for reconnect, then end session + post partial summary |
| STT returns empty | Ignore (silence), reset VAD state |
| CLIProxyAPI timeout (>30s) | Return "I'm having trouble thinking right now. Try again?" via TTS |
| CLIProxyAPI 429 (rate limit) | Return "I need a moment, I'm handling too many requests" via TTS |
| TTS failure | Return error beep + text in Slack thread |
| Node 8 OOM | Voice pod gets evicted first (lower priority than OpenClaw) — graceful degradation |

### Phase 3 Deliverables

- [ ] Agent-specific voice greetings and personas
- [ ] Full audit logging for voice sessions
- [ ] Slack summary posted on session end
- [ ] JWT authentication enforced
- [ ] Error handling for all failure modes
- [ ] No audio files persisted to disk
- [ ] Pod priority set below OpenClaw

---

## Phase 4: Polish

**Goal**: Quality of life improvements. No deadline — ongoing.

### Voice Quality Tuning

- **VAD sensitivity**: Tune Silero VAD threshold to avoid cutting off mid-sentence. Start at 0.5, adjust based on user feedback.
- **Noise suppression**: Enable WebRTC's built-in noise suppression (`RTCRtpSender.setParameters` with `noiseSuppression: true`) on the browser side. No server-side processing needed.
- **Echo cancellation**: Browser handles this natively via `echoCancellation: true` in `getUserMedia`.
- **Interruption handling**: If user speaks while agent is speaking, stop TTS playback immediately and process the new utterance. Pipecat supports this via `InterruptionStrategy.INTERRUPT`.

### Multiple Concurrent Sessions

Default: 3 concurrent sessions. To scale:
1. Run multiple Pipecat workers (1 per 3 sessions) behind a load balancer
2. Session affinity: once connected, stick to the same worker (WebRTC state is per-connection)
3. New sessions round-robin to least-loaded worker
4. Monitor via Prometheus: `hydra_voice_active_sessions`, `hydra_voice_queue_depth`

### Optional: ElevenLabs TTS Upgrade

The `openclaw.json` already has ElevenLabs configured (`voiceId: NtS6nEHDYMQC9QczMQuq`). To use it for voice:

| Tier | Cost | Quality | Latency |
|------|------|---------|---------|
| Piper (default) | $0 | Good (robotic at times) | ~0.2s |
| ElevenLabs Starter | $5/mo (30k chars) | Premium, natural | ~0.5s (network) |
| ElevenLabs Scale | $99/mo (500k chars) | Premium, natural | ~0.3s (priority) |

**Implementation**: Swap Piper TTS service for ElevenLabs TTS service in the Pipecat pipeline. Pipecat has a built-in `ElevenLabsTTSService`. The voice ID is already in config.

**Recommendation**: Ship with Piper first. If users complain about voice quality, upgrade to ElevenLabs Starter ($5/mo). The API key is already provisioned.

### Optional: Phone Dial-In

For users who want to call from a phone (not browser):
- **Twilio SIP trunk** → connect to Pipecat via SIP transport
- Cost: ~$1/mo + $0.0085/min
- Not recommended initially — browser WebRTC covers all use cases

---

## K8s Manifest Requirements

### New Resources Needed

| Resource | File | Purpose |
|----------|------|---------|
| Deployment | `k8s/prod/hydra/voice-deployment.yaml` | Pipecat voice server |
| Service | `k8s/prod/hydra/voice-service.yaml` | ClusterIP for session API + signaling |
| Ingress | `k8s/prod/hydra/voice-ingress.yaml` | `hydra-voice.ak.muso.ai` → voice service |
| PVC | (reuse `hydra-workspaces`) | Read agent SOUL.md files |
| ExternalSecret | (add to existing `external-secrets.yaml`) | `HYDRA_VOICE_JWT_SECRET` from Vault |
| NetworkPolicy | (add to existing `network-policies.yaml`) | Allow ingress for WebRTC signaling |

### Deployment Spec (Guidance)

```
Container: hydra-voice
  Image: registry.ak.muso.ai/hydra-voice:latest
  Ports: 8088 (session API), 8089 (WebRTC signaling)
  Resources:
    requests: cpu=2, memory=2Gi
    limits: cpu=8, memory=4Gi
  HostNetwork: true (for UDP media — or use NodePort range)
  NodeSelector: kubernetes.io/hostname=ovh-node-8
  Tolerations: dedicated=hydra:NoSchedule
  Priority: lower than openclaw-gateway
  VolumeMounts:
    - hydra-workspaces → /app/workspaces (readOnly)
    - hydra-audit-buffer → /app/audit
  Env:
    - ANTHROPIC_API_KEY (from Vault)
    - HYDRA_VOICE_JWT_SECRET (from Vault)
    - CLIPROXYAPI_URL=http://openclaw-gateway.hydra.svc:8317
    - WHISPER_MODEL=base.en
    - PIPER_VOICE=en_US-amy-medium
    - MAX_SESSIONS=5
    - SESSION_TTL_MINUTES=30
    - IDLE_TIMEOUT_SECONDS=120
  Probes:
    liveness: GET /health (8088)
    readiness: GET /ready (8088) — true when models loaded
```

### HostNetwork vs NodePort

**HostNetwork** (recommended): The voice pod uses the host's network stack directly. WebRTC media flows to Node 8's public IP on ephemeral UDP ports. Simpler, fewer NAT issues.

**NodePort**: Expose UDP 10000-10100 as NodePorts. More K8s-native but adds a layer of NAT that can complicate WebRTC.

**Decision**: Use `hostNetwork: true` for the voice pod. It's the only pod on Node 8 that needs external UDP access, so there's no port conflict risk.

---

## File & Directory Layout

```
hydra/
├── voice/                              # NEW — voice pipeline code
│   ├── Dockerfile                      # Python 3.11, models baked in
│   ├── requirements.txt                # pipecat, faster-whisper, sherpa-onnx
│   ├── server.py                       # Main Pipecat voice server
│   ├── session.py                      # Session management (create, validate, end)
│   ├── llm_service.py                  # Custom Pipecat LLMService wrapping CLIProxyAPI
│   ├── config.py                       # Environment-based configuration
│   ├── audit.py                        # Voice audit event writer
│   ├── web/                            # Static web client
│   │   ├── index.html                  # Voice session page
│   │   ├── style.css                   # Minimal styling
│   │   └── voice.js                    # WebRTC client logic
│   └── models/                         # Downloaded at build time
│       ├── whisper-base-en/            # faster-whisper base.en model
│       └── piper/                      # Piper voice files
│           ├── en_US-amy-medium.onnx
│           └── en_US-amy-medium.onnx.json
│
├── docs/
│   └── VOICE-PLAN.md                   # This document
│
k8s/prod/hydra/
├── voice-deployment.yaml               # NEW
├── voice-service.yaml                  # NEW
└── voice-ingress.yaml                  # NEW
```

---

## Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLIPROXYAPI_URL` | `http://localhost:8317` | CLIProxyAPI endpoint |
| `ANTHROPIC_API_KEY` | (from Vault) | Passed through to CLIProxyAPI |
| `HYDRA_VOICE_JWT_SECRET` | (from Vault) | Signs session JWTs |
| `WHISPER_MODEL` | `base.en` | faster-whisper model name |
| `WHISPER_COMPUTE_TYPE` | `int8` | Quantization (int8 for CPU) |
| `WHISPER_BEAM_SIZE` | `5` | Beam search width |
| `PIPER_VOICE` | `en_US-amy-medium` | Piper voice model name |
| `PIPER_SPEED` | `1.0` | TTS speech rate |
| `MAX_SESSIONS` | `5` | Max concurrent voice sessions |
| `SESSION_TTL_MINUTES` | `30` | Max session duration |
| `IDLE_TIMEOUT_SECONDS` | `120` | Silence before auto-disconnect |
| `VAD_THRESHOLD` | `0.5` | Silero VAD sensitivity (0-1) |
| `WEBRTC_PORT` | `8089` | WebRTC signaling port |
| `API_PORT` | `8088` | Session management API port |
| `LOG_LEVEL` | `info` | Logging level |
| `STUN_SERVERS` | `stun:stun.cloudflare.com:3478` | STUN server list |

### Voice Session API

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/session/create` | Internal (ClusterIP) | Create new voice session |
| `GET` | `/session/{id}` | JWT | Get session status + WebRTC config |
| `POST` | `/session/{id}/end` | JWT | End session, trigger summary |
| `GET` | `/health` | None | Health check |
| `GET` | `/ready` | None | Readiness (models loaded) |
| `GET` | `/metrics` | None | Prometheus metrics |

### Prometheus Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `hydra_voice_active_sessions` | Gauge | Currently active voice sessions |
| `hydra_voice_sessions_total` | Counter | Total sessions created |
| `hydra_voice_stt_latency_seconds` | Histogram | STT processing time |
| `hydra_voice_llm_latency_seconds` | Histogram | LLM response time |
| `hydra_voice_tts_latency_seconds` | Histogram | TTS generation time |
| `hydra_voice_round_trip_seconds` | Histogram | Full round-trip (user speech → agent speech) |
| `hydra_voice_turns_total` | Counter | Total conversation turns |
| `hydra_voice_errors_total` | Counter | Errors by type (stt, llm, tts, webrtc) |

---

## Rollback Plan

Voice is a fully additive feature. Rollback = delete the voice resources:

```bash
# Remove voice pod (does not affect OpenClaw or text agents)
kubectl delete deployment hydra-voice -n hydra
kubectl delete service hydra-voice -n hydra
kubectl delete ingress hydra-voice -n hydra

# Remove DNS (if created)
# → Cloudflare: delete hydra-voice.ak.muso.ai CNAME

# Remove voice trigger skill from agent workspaces
# → Delete voice-trigger skill files from each workspace

# OpenClaw and all text agents continue operating normally
```

**Impact of rollback**: Zero. Voice is a separate pod with separate ingress. Text agents don't depend on it. The only shared resources are the workspaces PVC (read-only) and audit PVC (append-only).

---

## Verification Criteria

### Phase 1 (PoC)
- [ ] faster-whisper transcribes a 5s English utterance in <2s on Node 8 CPU
- [ ] Piper TTS generates a sentence of speech in <0.5s on Node 8 CPU
- [ ] CLIProxyAPI returns a voice-appropriate response in <2s
- [ ] End-to-end CLI pipeline: speak → hear response in <4s
- [ ] CPU usage during inference stays under 8 cores
- [ ] RAM usage with all models loaded stays under 2GB

### Phase 2 (Web Client)
- [ ] User says "@Clio let's talk" → gets voice link in Slack within 3s
- [ ] Click link → browser connects → hear "Hello, I'm Clio" within 5s
- [ ] Speak a question → get spoken response in <4s
- [ ] Works in Chrome, Safari, Firefox (desktop + mobile)
- [ ] 2 concurrent sessions work without degradation
- [ ] Session auto-ends after 2 minutes of silence

### Phase 3 (Production)
- [ ] Conversation summary appears in Slack thread after call ends
- [ ] Voice session audit records appear in hydra-audit repo
- [ ] JWT authentication rejects invalid/expired tokens
- [ ] Agent persona matches text mode (same SOUL.md identity)
- [ ] 3-5 concurrent voice sessions without degradation
- [ ] Voice pod restart doesn't affect OpenClaw text agents

### Phase 4 (Polish)
- [ ] Interruption handling works (speak while agent talks → agent stops)
- [ ] No echo or feedback loops
- [ ] Prometheus metrics visible in Grafana
- [ ] Optional ElevenLabs upgrade tested and documented

---

## What You Get vs. Don't Get

| Feature | Status | Notes |
|---------|--------|-------|
| Talk to any HYDRA agent by voice | Yes | Via web link from Slack |
| Works on phone + desktop | Yes | WebRTC (any modern browser) |
| Same Claude intelligence as text | Yes | Same CLIProxyAPI backend |
| Conversation logged to Slack | Yes | Summary posted on call end |
| Full audit trail | Yes | Transcript in hydra-audit |
| Runs on existing hardware | Yes | Node 8, no new servers |
| No GPU needed | Yes | CPU-only (int8 quantized) |
| $0/month additional cost | Yes | All open source |
| Native Slack Huddle integration | No | Slack API doesn't support bot voice |
| Sub-second latency | No | ~2-4s on CPU (acceptable for conversation) |
| ElevenLabs voice quality | Upgrade path | Piper ships first, ElevenLabs available at $5-99/mo |
| Phone dial-in | Upgrade path | Twilio SIP possible, not planned |

---

## Cost Summary

| Item | Monthly Cost |
|------|-------------|
| Self-hosted STT (faster-whisper) | $0 |
| Self-hosted TTS (Piper) | $0 |
| Self-hosted WebRTC (Pipecat) | $0 |
| Claude API (existing CLIProxyAPI) | $0 incremental |
| DNS (Cloudflare, existing) | $0 |
| Hardware (Node 8, existing) | $0 incremental |
| **Total** | **$0/month** |

Cloud alternative comparison:
- OpenAI Whisper API + ElevenLabs: ~$60-170/month
- Assembly AI + ElevenLabs: ~$80-200/month
- Ultravox (hosted): ~$100-300/month
