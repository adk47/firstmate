---
name: "playlist-regeneration"
description: "Regenerate expired profile playlists with live gates and verified replacement."
---

# Profile Playlist Regeneration

Use for a bounded request to rebuild one expired Muso-generated Spotify discography playlist.

1. Resolve the exact profile and read its live admin state. Continue only when the intended stuck state still holds: the seat is active, the playlist is enabled, and the playlist is expired; otherwise stop with the changed state.
2. Verify behavior against the deployed production image and worker source, not a local checkout. Confirm the deployed regeneration path can reassign the playlist's current account status before treating the endpoint as capable.
3. Read the live Spotify service-account pool. Require at least one account with ACTIVE status, a non-null refresh token, and profile-playlist usage below 10,000. If the eligible count is zero, stop without dispatching because the queued job cannot complete.
4. Record the pre-write audit for the single profile, then call only `POST /admin/profile/:profileId/playlist/regenerate` with requester attribution. Do not edit database rows, modify the old public playlist, or expand into a batch.
5. Treat the HTTP response as dispatch evidence only. Read back until the bounded operation reaches a terminal observable state, then require a replacement playlist ID/URL, an eligible ACTIVE owning account, `isEnabled=true`, and `status` no longer expired before reporting success.
6. If the write errors or times out, read the authoritative profile state before deciding what happened; never re-fire blindly. Return the operation artifact when available and the pre/post audit references.
