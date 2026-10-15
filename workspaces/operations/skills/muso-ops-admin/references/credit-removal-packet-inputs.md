# Credit-removal packet inputs — verified `GET /admin/profile/:id` fields

_Recon for MUS-10236 (feeds MUS-10163). Verified live on **dev** 2026-10-14; handler source read on `core-backend` develop **and** master (byte-identical: `src/apis/_admin/profile/getProfile.js`, `src/services/claiming/getProfileProcessedClaiming.js`)._
_Route: `GET {MUSO_API_URL}/admin/profile/:profileId` where the dev base is `…/api/v3`. A request with no `Authorization` header answers 401 (control)._
_Envelope: `{"result":"ok","code":200,"data":{…profile…}}`. Every path below is relative to `.data` (`.body.data` in the wrapper's output)._

## How the payload is built

The handler spreads industry-api's `GET /profile/{id}` result (catalog fields), then adds three things itself: `isClaimed`, `workspaces`, `playlist`. `isClaimed` is true when a `claiming` row with `status = processed` exists for the profile. `workspaces` is built from `roster_seats` (`seatId = profileId`) joined to `teams`, and is **only set when the profile has at least one roster seat**.

## Field table

| Field | JSON path | Type | Sample (dev) | dev | prod |
|---|---|---|---|---|---|
| Popularity | `.data.popularity` | number | `45` (Ty Taylor, catalog artist) · `0` (unclaimed e2e profile) | live | source-identical, not read live |
| Rank | `.data.rank` | number | `4` (popularity 45) · `5` (popularity 0) | live | source-identical, not read live |
| Display name | `.data.name` | string | `"Ty Taylor"` | live | source-identical, not read live |
| Profile id | `.data.id` | string (UUID; some test profiles use a slug) | `0069d885-…` | live | source-identical, not read live |
| Claimed? | `.data.isClaimed` | boolean, always present | `true` / `false` | live | source-identical, not read live |
| Workspaces | `.data.workspaces[]` | array of objects, **key may be absent** | `[{"id":"194216a4-…","name":"Filtersettings's Workspace","email":"<redacted>","isClaimed":true}]` | live | source-identical, not read live |
| Workspace email | `.data.workspaces[].email` | string | `<redacted>` | live | source-identical, not read live |
| Workspace claimed? | `.data.workspaces[].isClaimed` | boolean (`claiming.teamId == workspace.id`) | `true` / `false` | live | source-identical, not read live |
| Workspace name / id | `.data.workspaces[].name`, `.id` | string | `"Filtersettings's Workspace"` | live | source-identical, not read live |
| Also present | `.data.creditCount`, `.creditCount1Y`, `.creditCountYTD`, `.collaboratorsCount`, `.albumCount`, `.type`, `.subType` | number / string | — | live | source-identical, not read live |
| `trackPopularities` | `.data.trackPopularities[]` | `[{popularity:"<string bucket>", track_count:number}]` or `null` | per-track-bucket counts, not a profile score | live | not read live |

`firstName`, `lastName`, `legalName`, `knownAsNames` exist but were `null` / `[]` on every dev sample. Use `.name`.

### Which field to use for "popularity"

`.data.popularity` (number) is present and is the profile score. `.data.rank` is also present. Observed only: rank 4 at popularity 45, rank 5 at popularity 0, so a **lower rank means more popular**. The scale and its upper bound were **not** confirmed; do not threshold on `rank` without asking industry-api's owner. Dev popularity is `0` for most e2e fixtures, so a VIP threshold cannot be calibrated from dev. Calibrate from prod values.

## Unclaimed-profile shape (what the gate must tell apart from "read failed")

Three states observed live on dev:

| Profile state | HTTP | `.data.isClaimed` | `.data.workspaces` |
|---|---|---|---|
| Unclaimed, **no roster seat** | 200 | `false` | **key absent** (not `[]`, not `null`) |
| Unclaimed, has a roster seat | 200 | `false` | `[{…, "isClaimed": false}]` |
| Claimed, has a roster seat | 200 | `true` | `[{…, "isClaimed": true}]` |
| Claimed, **no roster seat** (seen on dev) | 200 | `true` | **key absent** |

Consequences for the gate:

- `isClaimed` is a real boolean on every 200. A **missing or non-boolean `isClaimed`**, a non-200, or a body without `.data` is "read failed", never "unclaimed".
- `workspaces` absent is **valid** (jq: `(.data.workspaces // [])`). It does not mean "read failed", and it does not mean "unclaimed" either: a claimed profile can lack it.
- Do not derive "claimed" from `workspaces`. Use `.data.isClaimed`. A claimed profile with no roster seat has no `workspaces[]` to name an owner.
- Nonexistent id: handler throws NotFound (404, `result` ≠ `ok`). Not read live in this recon.

## Not available

| Needed | Status | What exists instead |
|---|---|---|
| Claimed owner's **last activity** | **Not in the admin profile payload.** Not in `workspaces[]` (`id`, `name`, `email`, `isClaimed` only). `GET /admin/user` list handler has no `lastActiveTime` reference. | `users.lastActiveTime` (timestamp, ~68% non-null on dev), reached from the processed `claiming` row's `userId`. One replica SELECT per profile; the query is in the MUS-10236 card comment, not here. It is stamped by the `updateLastActiveTime` middleware (e.g. on `GET /v4/user`), so it means "last authenticated call", and NULL means "never stamped", not "inactive". |
| Owner **user id** | Not in the payload. `workspaces[]` gives team id and team email only. | `claiming.userId`, same SELECT as above. |
| Prod live values | **Not read in this recon.** The documented in-pod session recipe is dev-only and no prod admin credential was used. | Both handler files are byte-identical on `develop` and `master`. Re-confirm with one wrapper `GET` under the operator's own session before the gate ships. |
| `rank` scale / upper bound | Not confirmed. | Observed values only (4, 5). |
