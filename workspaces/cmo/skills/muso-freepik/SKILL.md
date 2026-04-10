# Freepik API — CMO Skill

## Overview
Freepik API provides AI-powered image generation, image editing, video generation, audio generation, and stock content access. Credit-based pricing (pay-per-use). All endpoints are async (POST returns task_id → poll GET until COMPLETED, or use webhook_url).

## Authentication
- Header: `x-freepik-api-key: $FREEPIK_API_KEY`
- Base URL: `https://api.freepik.com`
- Key stored in workspace `.env`

## Rate Limits (Free Tier)
Check dashboard for current plan. Free tier examples:
- Mystic (image gen): 125/day
- Upscaler Creative: 125/day
- Relight: 125/day
- Style Transfer: 125/day (est.)
- Remove Background: 125/day (est.)
- Flux models: 100/day
- Kling video: 5-20/day (varies by model)
- Music gen: check dashboard
- Stock resources: 50/day

Premium tiers have 10-100x higher limits.

---

## Capabilities & Endpoints

### 1. AI Image Generation

#### Mystic (Recommended — Freepik exclusive)
Ultra-realistic, high-res images (1K/2K/4K). LoRA styles + characters.
```
POST /v1/ai/mystic
GET  /v1/ai/mystic/{task-id}
GET  /v1/ai/mystic              (list all tasks)
GET  /v1/ai/loras               (list available LoRA styles)
```
Body (JSON):
```json
{
  "prompt": "description of image",
  "resolution": "2k",
  "webhook_url": "https://...",
  "structure_reference": "<base64 image>",
  "structure_strength": 50,
  "style_reference": "<base64 image>",
  "styling": {
    "characters": [{"name": "character_name", "strength": 100}],
    "styles": [{"name": "style_name"}]
  }
}
```
- Characters in prompt: `@character_name` or `@character_name::strength`
- LoRAs ignored when using structure_reference, style_reference, or specific models (fluid, flexible, super_real, editorial_portraits)

#### Flux Models (Multiple Options)
| Model | Endpoint | Speed | Quality |
|-------|----------|-------|---------|
| Flux Kontext Pro | POST /v1/ai/flux-kontext-pro | Medium | High, context-aware |
| Flux 2 Pro | POST /v1/ai/flux-2-pro | Medium | Professional |
| Flux 2 Turbo | POST /v1/ai/flux-2-turbo | Fast | Good (lower cost) |
| Flux 2 Klein | POST /v1/ai/flux-2-klein | Sub-second | Good (up to 4 ref images) |
| Hyperflux | POST /v1/ai/hyperflux | Ultra-fast | Good |

#### Other Image Models
- Seedream 4/4.5: `POST /v1/ai/seedream-v4-5` — fast, high quality
- Z-Image Turbo: fast iterations
- RunWay Text-to-Image: `POST /v1/ai/runway`

### 2. Image Editing

#### Magnific Upscaler (Creative)
Prompt-guided upscaling — adds/infers detail. 2x/4x/8x/16x.
```
POST /v1/ai/image-upscaler
GET  /v1/ai/image-upscaler/{task-id}
```

#### Magnific Upscaler (Precision)
Faithful upscaling — no added detail, just clean enlargement.
```
POST /v1/ai/image-upscaler-precision
```

#### Relight
Change lighting of entire scene via prompt, reference image, or lightmap.
```
POST /v1/ai/image-relight
GET  /v1/ai/image-relight/{task-id}
```

#### Style Transfer
Apply artistic styles to images. Control intensity + structure preservation.
```
POST /v1/ai/image-style-transfer
GET  /v1/ai/image-style-transfer/{task-id}
```

#### Remove Background
Instant background removal. Supports JPG/PNG up to 20MB. Returns preview + high-res URLs (valid 5 min).
```
POST /v1/ai/beta/remove-background
Content-Type: application/x-www-form-urlencoded
Body: image_url=<URL>
```
Response: `{ original, high_resolution, preview, url }`
⚠️ NOT async — returns result immediately (no task_id polling).

#### Image Expand
Extend image boundaries (outpainting).
```
POST /v1/ai/image-expand (flux-pro based)
```

#### Seedream 4.5 Edit
Text-guided image editing.
```
POST /v1/ai/seedream-v4-5-edit
```

### 3. Video Generation

#### Kling Models (Most Popular)
| Model | Endpoint | Notes |
|-------|----------|-------|
| Kling 2.6 Pro | POST /v1/ai/kling-v2-6-pro | Latest, motion control |
| Kling 2.5 Pro | POST /v1/ai/kling-v2-5-pro | Enhanced motion |
| Kling 2.1 Pro | POST /v1/ai/kling-v2-1-pro | High quality |
| Kling O1 Pro | POST /v1/ai/kling-o1-pro | Enhanced reasoning |
| Kling Motion Control | POST /v1/ai/kling-v2-6-motion-control | Camera + motion |

#### Other Video Models
- MiniMax Hailuo 2.3: `POST /v1/ai/minimax-hailuo-2-3-1080p`
- WAN 2.6 1080p: `POST /v1/ai/wan-v2-6-1080p`
- RunWay Gen4 Turbo: `POST /v1/ai/runway-gen4-turbo`
- RunWay Act Two: character-consistent video
- Seedance Pro: ByteDance model
- PixVerse V5: creative effects
- LTX 2.0 Pro: text-to-video
- OmniHuman 1.5: audio-driven human animation
- VFX: visual effects

### 4. Audio

#### Music Generation (ElevenLabs)
Generate original music from text descriptions. 10-240 seconds. MP3 output.
```
POST /v1/ai/music-generation
GET  /v1/ai/music-generation/{task-id}
GET  /v1/ai/music-generation              (list tasks)
```
Body:
```json
{
  "prompt": "Upbeat jazz with piano and drums",
  "music_length_seconds": 60,
  "webhook_url": "https://..."
}
```
Prompt tips: include genre, mood, instruments, tempo.

#### Sound Effects
```
POST /v1/ai/sound-effects
GET  /v1/ai/sound-effects/{task-id}
```

#### Audio Isolation (SAM Audio)
Isolate specific sounds from audio or video files.
```
POST /v1/ai/audio-isolation
GET  /v1/ai/audio-isolation/{task-id}
```

### 5. Stock Content

#### Images & Templates
```
GET /v1/resources                                    — search/list
GET /v1/resources/{id}                               — get details
GET /v1/resources/{id}/download                      — download
GET /v1/resources/{id}/download/{format}             — download specific format
```
Params: `locale`, `page`, `limit`, `order` (latest|popular), `term` (search query)

#### Icons
```
GET /v1/icons                                        — search icons
```

#### Videos (Stock)
```
GET /v1/videos                                       — search stock videos
```

### 6. AI Classifier
Detect AI-generated content.
```
POST /v1/ai/beta/ai-classifier
```

---

## Async Pattern (Most AI Endpoints)
1. `POST` → returns `{ task_id, status: "IN_PROGRESS" }`
2. Poll `GET /{task-id}` until `status: "COMPLETED"`
3. Or pass `webhook_url` for push notification
4. Completed response includes image/video/audio URLs (temporary, download promptly)

## curl Template
```bash
# Generate image
curl -X POST "https://api.freepik.com/v1/ai/mystic" \
  -H "x-freepik-api-key: $FREEPIK_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "your prompt here"}'

# Check task status
curl -H "x-freepik-api-key: $FREEPIK_API_KEY" \
  "https://api.freepik.com/v1/ai/mystic/{task-id}"

# Remove background (sync)
curl -X POST "https://api.freepik.com/v1/ai/beta/remove-background" \
  -H "x-freepik-api-key: $FREEPIK_API_KEY" \
  -d "image_url=https://example.com/photo.jpg"

# Search stock
curl -H "x-freepik-api-key: $FREEPIK_API_KEY" \
  "https://api.freepik.com/v1/resources?term=music+studio&limit=10"
```

## Best Practices
- Send original images via URL when possible (avoid re-encoding/resizing)
- Base64 of original file is also fine for max quality
- Don't resize or convert PNG→JPEG before sending
- Download result URLs promptly — they're temporary (5 min for some endpoints)
- Use webhook_url in production to avoid polling loops

## Docs Reference
- Full docs: https://docs.freepik.com
- LLM-friendly: https://docs.freepik.com/llms.txt
- OpenAPI spec: https://storage.googleapis.com/fc-freepik-pro-rev1-eu-api-specs/freepik-api-v1-openapi.yaml
- Any page as markdown: append `.md` to URL
