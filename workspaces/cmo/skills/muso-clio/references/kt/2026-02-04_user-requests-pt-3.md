# KT: User Requests Part 3 (Final Session)

**Date:** 2026-02-04
**Participants:** Oleg Mamchich, Serhii Ostapchuk, Jay Ruffing, Michael Kureshi
**Source:** kt-recordings/2026-02-04-User_Requests-pt-3

## Summary

Final routine KT session. Oleg announced future meetings will be ad hoc. Session covered stream merging logic changes, new analytics recompute API, album merge request policy, TikTok escalation, and profile disambiguation procedures.

## Key Updates

### MCP REST API Deployed
- REST API for MCP dogs successfully deployed
- Serhii can now work on improving this service

### Stream Merging Logic Changed
- **Old threshold**: 10,000 streams
- **New threshold**: 1,000 streams
- Merge rule: tracks within 30% stream difference get merged
- PR created for Dave Ramos to review

### New Analytics Recompute API
- Created API to recompute analytics data for a profile
- Limited to **top 1,000 tracks** for large profiles (ordered by popularity + release date)
- Adds items to high-priority capture queue
- Successfully tested with YouTube and Shazam links
- **Note**: SoundCloud links not included (to be addressed)

## Policy Decisions

### Decline Album Merge Requests
- **Decision**: Decline requests to merge tracks into albums
- **Reason**: Database changes too complex/"hacky"
- Protects system integrity
- Applies especially to small/low-impact requests

### TikTok Data Issues
- Widespread zero-data issues reported
- **Escalate to**: Zite and Aaron
- Not a temporary fix situation

## Profile Disambiguation

### MLC Profiles Without IPI
**Problem**: MLC profiles without IPI (Industry Standard Profile Identifier) auto-link by name similarity alone.

**Symptoms**: Wrong lyricist/songwriter credits on artist profile.

**Fix procedure** (demonstrated with "Tyler Hicks" case):
1. Identify MLC profile causing wrong credits
2. Unlink MLC profile from wrong catalog profile
3. Link MLC profile to correct profile (e.g., "Tyler Jeffrey Hicks")
4. Manually remove incorrect credits (overrides raw source)
5. No IPI = won't create new profile automatically

### Profile Merging Decisions
- Single artists often merged with professional profiles (Taylor Swift)
- Not always appropriate (Skrillex/Sony case)
- **After unmerge**: Only release date updates in real-time; other changes need pipeline

### Duplicate Profile Fix
- "Bossy" vs "Buzzy" case: recapture track from sources
- Manual merge when auto-created duplicates
- Post-merge: profile has two Spotify IDs (correct)

## Stream Count Investigation

### Merged Tracks Query
SQL query shared to find merged links from last 360 days:
- Explains sudden stream count decreases
- Shows tracks with similar streams that were merged
- Example: Two tracks with 1B streams each merged

## Action Items (from meeting)
- [ ] Run SoundCloud search, add to new API if working (Oleg)
- [ ] Merge PR for stream threshold change (Dave Ramos)
- [ ] Fix failing API tests (Oleg)
- [ ] Resolve source link removal bug (Serhii)
- [ ] Handle primary artist credit change request (Serhii)
- [ ] Share merged tracks SQL query with Serhii (Oleg)

## Transition Note

This was the final routine KT session. Future meetings will be scheduled ad hoc as needed.

---

*Curated from KT meeting notes. See raw transcript for full context.*
