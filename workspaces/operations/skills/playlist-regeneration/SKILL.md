---
name: "playlist-regeneration"
description: "Regenerate expired profile playlists with live gates and verified replacement."
---

# Profile Playlist Regeneration

Use for a bounded request to rebuild one expired Muso-generated Spotify discography playlist or a completed playlist whose visible song count is stale or incomplete.

1. Resolve the exact profile and read its live admin state. Require an active seat and `isEnabled=true`. Continue when the playlist is expired, or when the requester supplied a concrete count mismatch that still reproduces; otherwise stop with the changed state.
2. Run the deployed track-selection service read-only and record the selected-track count and the subset with usable Spotify IDs. Use the usable-ID count as the expected rebuilt playlist count; a profile credit count does not guarantee the same number of Spotify-eligible songs.
3. Verify behavior against the deployed production image and worker source, not a local checkout. Confirm the manual endpoint forces a rebuild and can reassign the playlist's current account status before treating it as capable.
4. Read the live Spotify service-account pool. Require at least one account with ACTIVE status, a non-null refresh token, and profile-playlist usage below 10,000. If the current account is paused or deactivated, require eligible replacement capacity. If the eligible count is zero, stop without dispatching because the queued job cannot complete. Route account-capacity restoration to the credential/OAuth owner under separate authorization; never reactivate a paused account merely because it is available—first establish why it was paused and verify its refresh token and remaining capacity, then rerun the eligibility check.
5. Record the pre-write audit for the single profile, then call only `POST /admin/profile/:profileId/playlist/regenerate` with requester attribution. Do not edit database rows, modify the old public playlist, or expand into a batch.
6. Treat the HTTP response as dispatch evidence only. Read back until the bounded operation reaches a terminal observable state, then require a valid playlist ID/URL, an eligible ACTIVE owning account, `isEnabled=true`, terminal `completed` status, and a Spotify song count equal to the precomputed usable-ID count before reporting success. A replacement playlist ID is required only when account reassignment or recreation occurred; an in-place rebuild may retain the existing ID.
7. If the write errors or times out, read the authoritative profile state before deciding what happened; never re-fire blindly. Return the operation artifact when available and the pre/post audit references.
