# FEEDBACK.md — User Feedback Log

_Every dialog: analyze what the user said back. Did they correct me? Accept it? Push back? Redirect? That's the real quality signal._

## How to Read Feedback

| Signal | Meaning | Action |
|--------|---------|--------|
| User corrects a fact | I was wrong | Log correction, update EVIDENCE_STRATEGY anti-patterns |
| User says "not quite" / redirects | Partially wrong or missed the point | Log what I missed, refine approach |
| User asks follow-up building on my answer | Answer was useful, on track | Log as positive signal |
| User ignores my answer, asks something else | Answer wasn't useful or was off-topic | Log as weak negative |
| User explicitly says "good" / "exactly" | Strong positive | Log as confirmed good |
| User teaches me something new | Knowledge gap | Log lesson, update relevant files |
| User pushes back on methodology | Process issue, not just fact issue | Update EVIDENCE_STRATEGY |

## Feedback Log

### 2026-02-25

**Dialog:** Andrey asks how I measure answer quality and evidence
- **My answer:** Proposed emoji-based reactions (point 3)
- **Feedback:** Andrey correctly pointed out emoji reactions are unreliable — not everyone uses them. Real feedback comes from interpreting what people *say*.
- **Lesson:** Don't propose lazy metrics. Analyze conversational signals, not opt-in behaviors.
- **Quality:** My points 1, 2, 4 were accepted. Point 3 was rejected. Overall: partial hit.
- **Action:** Built this file + EVIDENCE_STRATEGY.md per Andrey's guidance.

### 2026-02-22

**Dialog:** Andrey caught me bluffing about S3 checkpoint freshness
- **Feedback:** Direct correction — I claimed data was fresh without checking actual source
- **Lesson:** Always verify time-sensitive claims against actual source, never infer
- **Quality:** Wrong. Major error.
- **Action:** Added to EVIDENCE_STRATEGY anti-patterns, added checkpoint check to HEARTBEAT.md

### 2026-02-23

**Dialog:** Andrey on duplicate PK root cause in matvw_catalog_track
- **Feedback:** Taught me the actual root cause + fix (`.distinct()`)
- **Lesson:** Don't theorize about data bugs — query the data, find the actual duplicates
- **Quality:** I was investigating but hadn't found root cause. Andrey accelerated it.
- **Action:** Logged lesson, updated memory

---

_Review weekly: are correction rates dropping? Are the same anti-patterns recurring? That's the trendline._
