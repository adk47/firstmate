# KT: User Requests Part 2

**Date:** 2026-02-03
**Participants:** Oleg Mamchich, Serhii Ostapchuk, Jay Ruffing
**Source:** kt-recordings/2026-02-03-User_Requests-pt-2

## Summary

Oleg and Serhii worked through multiple user support cases, demonstrating operational procedures for track deletion, non-musical link fixes, YouTube stream refresh, source link issues, and label disambiguation.

## Key Procedures Demonstrated

### Track Deletion
- Use Retool delete button
- Verify `deleted: true` flag in database after short delay
- **Rule**: Check with Aaron first if stream count is very high

### "Non-Musical" Link Fix
- Source of "non-music" flag: Ops Hub → risky analytics links
- Fix location: Aurora stats database
- Set `is_not_music = false`
- Stats update next day when pipeline runs
- No Retool unmark option currently

### YouTube Refresh Script
- Selects all tracks for a profile
- Finds analytics links:
  - Not updated in 14 days, OR
  - Zero streams
- Adds to capture queue for refresh
- Oleg proposed converting to API endpoint

### Source Link Removal Bug
- **Bug**: "no URL protocol specified error" when clicking Remove
- **Workaround**: Manually reassign in database
- **Status**: Serhii investigating (Retool, core-backend, or industry-processing)

### Spotify Mirror Limitation
- Muso mirrors industry data from Spotify
- Cannot remove credits that exist on Spotify
- User must fix at source (Spotify/distributor)

## Label Disambiguation Challenge

### Problem
Spotify provides label name as **lowercase string only** (no ID). Two labels with same name = ambiguous.

### Example: "Allison Records"
Multiple labels share this name, causing incorrect artist associations.

### Temporary Fix
1. Create new profile for one label
2. Manually move credits to new profile
3. Caveat: new tracks still assign to original profile (has Spotify raw ID)

### Permanent Solution (Task Created)
- Custom rules for artist-to-label mapping in industry processing
- Only assign credits if artist matches mapping
- Task: "labels disambiguation" (high priority)

## YouTube Playlist Claiming
- If playlist contains multiple tracks all belonging to user
- OK to assign single YouTube link to any one of user's tracks

## Action Items (from meeting)
- [ ] Convert YouTube refresh script to API (Oleg)
- [ ] Debug Retool source link removal (Serhii)
- [ ] Implement labels disambiguation feature (Serhii)

---

*Curated from KT meeting notes. See raw transcript for full context.*
