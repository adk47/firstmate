# Key Context

Operational reference — things I use during normal sessions that are too detailed to keep in MEMORY.md.

## Google Drive — HYDRA Folders (2026-04-10)

- HYDRA shared folder: `1fG_pQ4hBJfHhoHXNUJTi_pmwJIxLFOg_` — https://drive.google.com/drive/folders/1fG_pQ4hBJfHhoHXNUJTi_pmwJIxLFOg_
- CMO subfolder: `1GFqT8LwewQedb73thkvOmUkCNVwNPT5w` — https://drive.google.com/drive/folders/1GFqT8LwewQedb73thkvOmUkCNVwNPT5w
- Drive access is via *a@muso.ai* OAuth token (f@muso.ai can't see these folders)
- HYDRA folder name: "Media Generation Temporary"
- CMO folder name: "CMO" — default drop location for all generated assets

## Freepik API (2026-04-10)

- Key stored in `.env` as `FREEPIK_API_KEY` (not in memory per policy)
- Full capabilities: image gen (Mystic, Flux), video gen (Kling, Hailuo), audio (ElevenLabs), editing (upscale, relight, style transfer, bg remove), stock content
- Skills: `muso-freepik` (raw API ref), `mediagen-engine` (full production skill)
- Research: `research/ai-media-generation-2026.md`
- Color weight format: `{"color": "#hex", "weight": 0.0-1.0}` (API rejects integer weights)
- ⚠️ *HARD RULE (Fede directive 2026-04-10):* EVERY image/video/audio generation request from CMO MUST go through Freepik API via mediagen-engine skill. NEVER use the built-in `image_generate` tool. No exceptions.

## Snov.io Email Verification Gate (2026-04-11)

- Pre-send email verification is now a HARD STEP (Step 5.5) in `muso-outreach-sender`
- Auth: OAuth2 client_credentials, env vars `$SNOVIO_CLIENT_ID` / `$SNOVIO_CLIENT_SECRET`
- Flow: `add-emails-to-verification` → wait 5s → `get-emails-verification-status` (poll up to 30s)
- `smtpStatus: not_valid` = SKIP the contact, mark as `Email Invalid (Snov)` in sheet
- `smtpStatus: valid` = proceed normally
- `smtpStatus: unknown` + catchall = proceed with warning flag
- API down / timeout = STOP, notify Nick, do NOT send unverified
- Tested 2026-04-11: victoria.chan@yousician.com correctly returned `not_valid` (yesterday's bounce)
- Logs: `api-logs/snov/YYYY-MM-DD.jsonl`
- Config: `muso-outreach-engine/references/config.md` (Snov.io section)
- This is non-negotiable. Every email, every batch, every time. No exceptions.

## MXWM = Mix With The Masters (2026-04-09)

Tom Bonnell (tom@mixwiththemasters.com). Closed Won. $6,127.80/mo × 3 months = $18,383.40 total. Zachary Anderson kept as contact only (not an opportunity).
