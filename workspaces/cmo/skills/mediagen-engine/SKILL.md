# MediaGen-Engine — AI Media Production Skill

> *One skill, multiple capabilities.* Generates images, videos, audio, and handles post-production — all through Freepik's API. Designed for marketing asset creation with visual consistency built in.

## Quick Reference

| Need | Use |
|------|-----|
| Marketing photo | `generate_image` → Mystic realism |
| Portrait / headshot | `generate_image` → Mystic editorial_portraits |
| Illustration / concept | `generate_image` → Mystic flexible |
| Fast draft | `generate_image` → Seedream 4.5 |
| Consistent series | `generate_image` → Flux Kontext Pro + input_image |
| Animate a still | `generate_video` → Kling 2.6 Pro (image-to-video) |
| Background music | `generate_music` → ElevenLabs |
| Remove background | `edit_image` → bg-remove |
| Upscale | `edit_image` → upscale |
| Fix lighting | `edit_image` → relight |
| Style unification | `edit_image` → style-transfer |
| Stock content | `search_stock` |

---

## Auth & Config

```bash
# All requests use this header
x-freepik-api-key: $FREEPIK_API_KEY

# Base URL
https://api.freepik.com
```

Key stored in `/opt/hydra/workspaces/cmo/.env`

---

## 1. IMAGE GENERATION

### 1A. Mystic (Primary — Highest Quality)

```bash
# Generate
POST /v1/ai/mystic

# Poll
GET /v1/ai/mystic/{task-id}

# List LoRAs
GET /v1/ai/loras
```

#### Parameters
| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `prompt` | string | — | See Prompting Guide below |
| `model` | string | `realism` | `realism`, `fluid`, `zen`, `flexible`, `super_real`, `editorial_portraits` |
| `resolution` | string | `2k` | `1k`, `2k`, `4k` |
| `aspect_ratio` | string | `square_1_1` | See Aspect Ratios table |
| `engine` | string | `automatic` | `automatic`, `magnific_illusio`, `magnific_sharpy`, `magnific_sparkle` |
| `creative_detailing` | int | 33 | 0-100. Keep 20-40 for natural look. |
| `fixed_generation` | bool | false | Enable for reproducible results |
| `filter_nsfw` | bool | true | Cannot be disabled (standard API) |
| `structure_reference` | base64 | — | Layout/composition guide |
| `structure_strength` | int | 50 | 0-100 |
| `style_reference` | base64 | — | Visual style guide. **MOST POWERFUL for consistency** |
| `adherence` | int | 50 | 0-100 (style_reference prompt adherence) |
| `hdr` | int | 50 | 0-100 (style_reference detail level) |
| `styling.styles` | array | — | LoRA styles: `[{"name": "lowkeycinematic"}]` |
| `styling.characters` | array | — | LoRA characters: `[{"name": "rafael", "strength": 100}]` |
| `styling.colors` | array | — | Brand palette: `[{"color": "#1A1A2E", "weight": 0.3}, ...]` (up to 5, weight 0-1) |
| `webhook_url` | url | — | Callback for completion notification |

#### Model Selection Matrix
| Scenario | Model | Engine | Creative Detailing |
|----------|-------|--------|-------------------|
| Product marketing photo | `realism` | `magnific_sharpy` | 25-35 |
| Maximum photorealism | `super_real` | `magnific_sharpy` | 20-30 |
| Editorial portrait (close-up) | `editorial_portraits` | `automatic` | 30-40 |
| Creative illustration | `flexible` | `magnific_illusio` | 40-60 |
| Prompt-faithful concept | `fluid` | `automatic` | 30-40 |
| Soft/clean/minimal | `zen` | `magnific_illusio` | 20-30 |

#### LoRA Styles for Music/Entertainment Marketing
| Style | What It Does |
|-------|-------------|
| `lowkeycinematic` | Dark, moody cinema lighting |
| `editorial` | High-end editorial look |
| `cinematicstill` | Movie-frame aesthetic |
| `warmfineart` | Warm tones + light leaks |
| `productphotography` | Clean product showcase |
| `videoclip` | Music video aesthetic |
| `coverartabstract` | Album cover art vibes |
| `darkfantasy` | Dark luxe, moody |
| `futuristicneon` | Neon + cinematic |
| `classyanalog` | Sophisticated film feel |
| `aetherial` | Deep gold + blue drama |
| `moodybw` | Dramatic B&W |

⚠️ LoRAs are SILENTLY IGNORED when using `structure_reference`, `style_reference`, or models `fluid`/`flexible`/`super_real`/`editorial_portraits`.

#### Aspect Ratios
| Code | Ratio | Best For |
|------|-------|----------|
| `square_1_1` | 1:1 | Instagram post, thumbnails |
| `classic_4_3` | 4:3 | Blog images, presentations |
| `traditional_3_4` | 3:4 | Pinterest, portrait |
| `widescreen_16_9` | 16:9 | YouTube, website headers, OG |
| `social_story_9_16` | 9:16 | Instagram/TikTok Stories |
| `standard_3_2` | 3:2 | Photography standard |
| `portrait_2_3` | 2:3 | Tall portrait |
| `horizontal_2_1` | 2:1 | Email header, wide banner |
| `social_5_4` | 5:4 | Social feed |
| `social_post_4_5` | 4:5 | Instagram feed (recommended) |

### 1B. Flux Kontext Pro (Consistency-Focused)

```bash
POST /v1/ai/text-to-image/flux-kontext-pro
GET  /v1/ai/text-to-image/flux-kontext-pro/{task-id}
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `prompt` | string | required | |
| `input_image` | URL | — | **KEY FOR CONSISTENCY** — guides style/composition |
| `prompt_upsampling` | bool | false | Auto-expand prompt for creativity |
| `guidance` | float | 3.0 | 1-10 (higher = more literal) |
| `steps` | int | 50 | 1-100 (more = better quality, slower) |
| `aspect_ratio` | string | `square_1_1` | Same codes as Mystic |
| `seed` | int | random | Lock for reproducibility |

### 1C. Other Image Models

```bash
# Seedream 4.5 (fast + good)
POST /v1/ai/text-to-image/seedream-v4-5

# Flux 2 Pro (professional)
POST /v1/ai/text-to-image/flux-2-pro

# Flux 2 Turbo (fast iterations)
POST /v1/ai/text-to-image/flux-2-turbo
```

---

## 2. VIDEO GENERATION

### 2A. Kling 2.6 Pro (Recommended)

```bash
# Image-to-video OR text-to-video
POST /v1/ai/image-to-video/kling-v2-6-pro
GET  /v1/ai/image-to-video/kling-v2-6-pro/{task-id}
```

#### Text-to-Video Parameters
| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `prompt` | string | required | Describe MOTION, not scene |
| `negative_prompt` | string | — | "blurry, distorted, morphing, deformed" |
| `duration` | string | — | `"5"` or `"10"` (seconds) |
| `cfg_scale` | float | 0.5 | 0-1 (higher = more prompt control) |
| `aspect_ratio` | string | — | `"1:1"`, `"16:9"`, `"9:16"`, `"4:3"`, `"3:4"` |
| `generate_audio` | bool | false | Auto-generate matching audio |

#### Image-to-Video Parameters
Same as above, plus:
| Param | Type | Notes |
|-------|------|-------|
| `image` | base64/URL | Starting frame. Max 10MB, min 300x300px, ratio 1:2.5-2.5:1 |

#### Best Practice: Image → Video Pipeline
1. Generate perfect still with Mystic (`fixed_generation: true`)
2. Use that image as `image` param in Kling 2.6 Pro
3. Prompt describes only the MOTION: "camera slowly pushes in, subject turns head slightly"
4. Use `duration: "5"` — shorter clips = higher quality
5. Add `negative_prompt: "blurry, distorted, morphing, flickering, deformed hands, sudden scene changes"`

### 2B. Other Video Models

```bash
# MiniMax Hailuo 2.3 (cinematic)
POST /v1/ai/image-to-video/minimax-hailuo-2-3-1080p

# RunWay Gen4 Turbo (fast)
POST /v1/ai/image-to-video/runway-gen4-turbo

# WAN 2.6 (high-res)
POST /v1/ai/image-to-video/wan-v2-6-1080p
```

---

## 3. AUDIO GENERATION

### 3A. Music (ElevenLabs)

```bash
POST /v1/ai/music-generation
GET  /v1/ai/music-generation/{task-id}
```

| Param | Type | Required | Notes |
|-------|------|----------|-------|
| `prompt` | string | yes | Genre + mood + instruments + tempo |
| `music_length_seconds` | int | yes | 10-240 |
| `webhook_url` | URL | no | |

**Prompt Template:**
```
"[Genre] [sub-genre], [primary instrument] melody, [secondary instruments], [mood adjectives], [BPM] BPM, [overall feel]"
```

**Example:** "Cinematic ambient electronic, minimal piano melody, subtle bass pulses, atmospheric pads, contemplative and modern, 85 BPM, sophisticated and understated"

### 3B. Sound Effects

```bash
POST /v1/ai/sound-effects
GET  /v1/ai/sound-effects/{task-id}
```

### 3C. Audio Isolation (SAM)

```bash
POST /v1/ai/audio-isolation
GET  /v1/ai/audio-isolation/{task-id}
```

---

## 4. IMAGE EDITING

### 4A. Background Removal (Instant — NOT async)

```bash
POST /v1/ai/beta/remove-background
Content-Type: application/x-www-form-urlencoded

image_url=<URL>
```

Returns `{ original, high_resolution, preview, url }` immediately. URLs valid 5 minutes.

### 4B. Magnific Upscaler (Creative)

```bash
POST /v1/ai/image-upscaler
GET  /v1/ai/image-upscaler/{task-id}
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `image` | base64 | required | |
| `scale_factor` | string | `2x` | `2x`, `4x`, `8x`, `16x` |
| `optimized_for` | string | `standard` | `standard`, `soft_portraits`, `hard_portraits`, `art_n_illustration`, `videogame_assets`, `nature_n_landscapes`, `films_n_photography`, `3d_renders`, `science_fiction_n_horror` |
| `prompt` | string | — | Reuse original generation prompt |
| `creativity` | int | 0 | -10 to 10 |
| `hdr` | int | 0 | -10 to 10 |
| `resemblance` | int | 0 | -10 to 10 |
| `engine` | string | — | `magnific_illusio`, `magnific_sharpy`, `magnific_sparkle` |

### 4C. Relight

```bash
POST /v1/ai/image-relight
GET  /v1/ai/image-relight/{task-id}
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `image` | base64/URL | required | |
| `prompt` | string | — | Describe desired lighting |
| `transfer_light_from_reference_image` | base64/URL | — | OR use lightmap |
| `transfer_light_from_lightmap` | base64/URL | — | Black=no light, lighter=light |
| `light_transfer_strength` | int | 100 | 0-100 |
| `interpolate_from_original` | bool | false | |
| `change_background` | bool | false | |
| `style` | string | — | `smooth` or other |
| `advanced_settings.engine` | string | — | `illusio` |
| `advanced_settings.fixed_generation` | bool | false | |

**Emphasis in prompts:** Use `(descriptor:weight)` syntax. Example: `"(warm golden hour:1.3) studio lighting"`

### 4D. Style Transfer

```bash
POST /v1/ai/image-style-transfer
GET  /v1/ai/image-style-transfer/{task-id}
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `image` | base64/URL | required | |
| `reference_image` | base64/URL | — | Style source |
| `prompt` | string | — | Guide the transfer |
| `style_strength` | int | 100 | 0-100 |
| `structure_strength` | int | 50 | 0-100 |
| `is_portrait` | bool | false | Enable portrait enhancements |
| `portrait_style` | string | `standard` | `standard`, `pop`, `super_pop` |
| `portrait_beautifier` | string | — | `beautify_face`, `beautify_face_max` |
| `flavor` | string | `faithful` | `faithful`, `gen_z`, `psychedelia`, `detaily`, `clear`, `donotstyle`, `donotstyle_sharp` |
| `engine` | string | `balanced` | `balanced`, `definio`, `illusio`, `3d_cartoon`, `colorful_anime`, `caricature`, `real`, `super_real`, `softy` |
| `fixed_generation` | bool | false | |

---

## 5. STOCK CONTENT

```bash
# Search
GET /v1/resources?term=<query>&limit=10&order=popular

# Get details
GET /v1/resources/{id}

# Download
GET /v1/resources/{id}/download
GET /v1/resources/{id}/download/{format}

# Icons
GET /v1/icons?term=<query>

# Stock video
GET /v1/videos?term=<query>
```

---

## 6. PROMPTING GUIDE

### The Muso Marketing Prompt Template

```
[Subject with specifics] in [setting/location], [lighting description], [atmosphere/mood], [camera/lens specs], [quality modifiers]
```

### Music Industry Prompt Examples

**Artist/Producer Portrait:**
> "Music producer in professional studio, hands on analog mixing console, warm amber studio lighting from above, creative focused atmosphere, Canon R5 85mm f/1.4, shallow depth of field, editorial photography"

**Product/Platform Marketing:**
> "Modern laptop displaying music analytics dashboard, clean minimalist desk setup, soft diffused side lighting, professional and innovative atmosphere, product photography, sharp focus, clean background"

**Concert/Live Music:**
> "Live concert from crowd perspective, performer silhouette on stage, dramatic red and blue stage lighting, electric atmosphere, wide angle 24mm lens, motion blur on crowd hands, concert photography"

**Abstract/Brand:**
> "Sound waves visualized as golden light trails flowing through dark space, abstract and premium, deep navy and gold color palette, cinematic lighting, macro photography style"

### Video Motion Prompts

**Subtle/Elegant:**
> "Camera slowly pushes forward, soft light shifts gradually from left, subtle focus pull, minimal subject movement"

**Dynamic/Energetic:**
> "Quick camera rotation, subject gestures expressively, dynamic lighting shifts, energetic pacing"

**Product Reveal:**
> "Camera orbits smoothly around subject, light catches reflective surface, revealing details, luxurious pacing"

---

## 7. CONSISTENCY PLAYBOOK

### For a Campaign (Multiple Related Images)

1. *Generate hero image* with Mystic (pick best model, dial in settings)
2. *Lock settings*: record model, engine, creative_detailing, LoRA style
3. *Use hero as style_reference* for all variants (adherence 40-60)
4. *Lock brand colors* via `styling.colors`
5. *Same aspect_ratio* per channel across all assets
6. *Same prompt structure* — vary only the subject/scene portion

### For a Video Series

1. Generate all keyframes with *identical Mystic settings*
2. Use *same negative_prompt* across all Kling requests
3. Use *same cfg_scale and duration* for motion consistency
4. Stitch clips with consistent transitions

### For Cross-Channel Assets (Same Concept, Different Formats)

1. Generate one `square_1_1` hero
2. Use `structure_reference` (hero) + new `aspect_ratio` for each channel
3. Adjust `structure_strength` 40-60 to allow natural reframing

---

## 8. ASYNC PATTERN

Most AI endpoints are asynchronous:

```bash
# 1. Submit task
curl -X POST "https://api.freepik.com/v1/ai/mystic" \
  -H "x-freepik-api-key: $FREEPIK_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "..."}' 
# Returns: {"data": {"task_id": "xxx", "status": "CREATED"}}

# 2. Poll for completion
curl -H "x-freepik-api-key: $FREEPIK_API_KEY" \
  "https://api.freepik.com/v1/ai/mystic/{task-id}"
# Returns: {"data": {"task_id": "xxx", "status": "COMPLETED", "generated": ["url1", ...]}}

# 3. Download result (URLs are temporary — download immediately)
curl -L -o output.png "https://ai-statics.freepik.com/..."
```

**Polling strategy:** Wait 10-15s for images, 30-60s for video, 15-30s for music. Then poll every 5s.

**Exception:** Background removal is SYNCHRONOUS — returns result immediately.

---

## 9. COST MANAGEMENT

| Tier | Strategy |
|------|----------|
| *Drafting* | Seedream 4.5 or Flux 2 Turbo (cheap, fast) |
| *Concept approval* | Mystic 1k resolution (saves credits vs 2k/4k) |
| *Final production* | Mystic 2k/4k, Kling 2.6 Pro |
| *Iteration* | `fixed_generation: true` + change one param |

---

## Related Files
- Research notes: `research/ai-media-generation-2026.md`
- Raw API reference: `skills/muso-freepik/SKILL.md`
- Generated assets: `media/generated/` (create per-campaign subdirectories)
