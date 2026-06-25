# CMO - Onboarding Guide

## Trigger
When Nick (or any authorized user) says **"CMO - Onboarding Guide"** — deliver the full 12-part Muso onboarding story as voice messages in Slack.

## What It Is
A pre-recorded 12-part audio guide that explains everything about Muso.AI — from credits to AMP to the new hire's role. Calm, storytelling voice. Each part flows into the next with cliffhangers.

## How To Deliver

Send each part as a *separate Slack message* in the channel/thread where requested. Each message has:
1. A text intro (heading + 1-2 sentence description of what they'll learn)
2. The audio file uploaded in the same message

### Delivery Steps

1. Determine the target channel and thread (use the channel/thread where the trigger was posted, or a specific channel if Nick specifies one)
2. Post all 12 parts sequentially — one message per part
3. Use the Slack `files.getUploadURLExternal` → upload → `files.completeUploadExternal` flow (same as the upload script in `audio/upload_onboarding.py`)
4. Wait ~2 seconds between uploads to avoid Slack rate limits
5. After all 12, post a closing message

### Audio Files
Stored at: `skills/cmo-onboarding-guide/audio/part_XX.mp3` (resolve relative to skill directory)

### Message Format Per Part

Each message should be posted as a single upload with the text as the `initial_comment`. Format:

---

**Part [N] — [Title]**
_[1-2 sentence description of what this part covers]_

[attached: audio file]

---

### Part Catalog

| Part | Title | Description |
|------|-------|-------------|
| 1 | What is Muso AI? | The origin story — how Muso started and why music credits matter. The foundation of everything. |
| 2 | Credits Explained | What credits are in music, who gets them, and what Muso lets you do with yours. |
| 3 | Subscription Tiers | Lite, Pro, and Business — what each tier unlocks and who it's for. |
| 4 | Analytics | What Pro analytics look like — streaming data, rankings, milestones. Why Muso is LinkedIn for music. |
| 5 | What is AMP? | Amplify — Muso's advertising and discovery platform. How it works for users and advertisers. |
| 6 | Muso Ads | Muso's ads manager — like Meta Ads but built for the music industry. How companies reach verified music professionals. |
| 7 | Audits | How Muso helps find missing royalties by cross-checking the MLC database. |
| 8 | Music Industry Context | Labels vs. publishers — the two sides of the industry and why it matters for Muso's audience. |
| 9 | Shareables and Plaques | How shareable tiles and acrylic plaques drive organic marketing. |
| 10 | Upcoming Features | Profile Views, Chat and Connect, better Feed — what's next for Muso. |
| 11 | Your Role | Executive Marketing Assistant — focus areas, channels, hours, reporting. |
| 12 | Using CMO — Your AI Assistant | How to use me effectively — what I can do, how to tag me, caveats. |

### ElevenLabs Voice Details (for regeneration)
- **Voice ID**: `NtS6nEHDYMQC9QczMQuq`
- **Model**: `eleven_multilingual_v2`
- **Settings**: stability=0.65, similarity_boost=0.75, style=0.15, speaker_boost=true
- **Vibe**: Calm, relaxed storytelling voice

### Upload Script
A reusable upload script is at `skills/cmo-onboarding-guide/audio/upload_onboarding.py`. It takes a channel ID, thread TS, and posts all 12 parts with the text intros. Run it via:
```
python3 skills/cmo-onboarding-guide/audio/upload_onboarding.py <CHANNEL_ID> <THREAD_TS>
```

### Regeneration
If the transcripts need updating, the full text for each part is stored in `skills/cmo-onboarding-guide/transcripts.json`. Regenerate audio using the ElevenLabs settings above.

## Rules
- Always deliver all 12 parts in order
- Each part is its own message (not all dumped in one)
- ~2 second gap between uploads
- If a specific part is requested (e.g. "just Part 5"), deliver only that part
- If asked to regenerate, use the same voice ID and settings
