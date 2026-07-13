# Entity Deletion Operations

Source: KT 2026-01-20 (Oleg Mamchich)

## Key Principles

1. **Soft delete only** — Primary entities (track, album, profile) are never hard deleted
2. **Muso source required** — To delete, create a Muso raw source and mark IT as deleted
3. **Muso priority wins** — Muso source > Spotify, so marking Muso deleted cascades to catalog
4. **Track deletion policy** — Never delete tracks/albums that exist on Spotify

## Deletion Fields

**⚠️ Field path: deletion state lives under the `deleted` EMBEDDED SUBDOC —
never at the top level of the document.** Every collection (raw_* and
catalog_*) inherits `deleted = EmbeddedDocumentField(Deleted)` from
`industry-data-processing/db/collections/base.py`; the `Deleted` / `ActionBy`
embedded documents are `db/collections/common/deleted.py` and
`db/collections/common/action_by.py`.

Reading top-level `is_deleted` / `deleted_timestamp` / `deleted_by` on a
`catalog_profile` doc returns null/missing for EVERY profile — deleted or not.
That exact mistake made an ops-deleted profile read as "not deleted" and
produced a false "profile resurrection" claim in the 2026-07 systemic-data-issue
report (task #200 RCA). Always read/query `deleted.is_deleted`,
`deleted.deleted_timestamp`, `deleted.deleted_by.*`.

When an entity is deleted, these fields are set:

```javascript
{
  "deleted": {
    "is_deleted": true,
    "deleted_timestamp": ISODate("2026-01-20T..."),
    "deleted_by": {
      "id": "jan@muso.ai",       // actor: ops email, admin/user id, or raw source
      "type": "operations",      // enum: "operations" | "user" | "raw"
      "sub_type": "clio"         // e.g. "retool", "clio", "backend", "clickup", a task id
    }
  }
}
```

Query examples:

```javascript
// mongosh / pymongo — is this profile deleted?
db.catalog_profile.findOne({ _id: "UUID" }, { deleted: 1, name: 1 })
// deleted iff doc.deleted && doc.deleted.is_deleted === true

// all ops-deleted, non-merged profiles
db.catalog_profile.find({
  "deleted.is_deleted": true,
  "deleted.deleted_by.type": "operations",
  "merged": { "$exists": false }
})
```

```python
# mongoengine
CatalogProfile.objects(deleted__is_deleted=True,
                       deleted__deleted_by__type="operations")
```

| `deleted_by.type` | Meaning |
|------|---------|
| `operations` | Admin action (via Retool, Clio, or backend script) |
| `user` | User-initiated action |
| `raw` | Raw-source-driven (pipeline cascade) |

---

## Profile Deletion Procedure

### Prerequisites

1. SSH tunnel to MongoDB production
2. SSH tunnel to PostgreSQL production
3. `industry-data-processing` repo, branch: `running_same_in_prod`
4. Config file: `config_local.ini` (prod connection strings — get from Keybase)

### Steps

1. Open `delete_profile.py` notebook in VS Code (Cmd+P → "delete")
2. Set variables:
   ```python
   profile_id = "UUID-from-retool"
   task_id = "clickup-task-id"
   ```
3. Run `delete_profile(profile_id, task_id)`

### What the Function Does

```python
def delete_profile(profile_id, task_id):
    # 1. Create Muso raw profile if doesn't exist
    send_message({
        "action": "upsert",
        "origin": "muso",
        "data_source": "muso",
        "entity": "profile",
        "id": f"muso:profile:{profile_id}"
    })

    # 2. Mark Muso profile as deleted. The actor payload key is `action_by`
    #    (NOT `deleted_by`) with fields id / type / sub_type — the IDP raw
    #    parser reads data["action_by"] and maps them onto the ActionBy
    #    embedded doc (parsers/muso_parser.py `parse_action_by`). A legacy
    #    `deleted_by`/`subtype` payload is silently ignored and the
    #    tombstone loses actor + task attribution.
    send_message({
        "action": "delete",
        "raw_id": f"muso:profile:{profile_id}",
        "action_by": {
            "id": "ops-user@muso.ai",   # who performed the deletion
            "type": "operations",
            "sub_type": task_id          # e.g. clickup task id / "retool" / "clio"
        }
    })
```

### Why Create Muso Source First?

- Cannot delete Spotify data directly
- Muso source has highest priority (6 > Spotify's 5)
- When catalog syncs, it sees: Spotify (not deleted) + Muso (deleted)
- Muso wins → catalog entity marked deleted

### Cascade Effects

- **Profile deleted** → soft deleted in catalog
- **Tracks where profile is ONLY collaborator** → also deleted
- **Other tracks** → profile hard-deleted from `profiles` array (credit removed)

---

## Track/Album Deletion Policy

**NEVER delete if entity exists on Spotify.**

### When Deletion Is Allowed

1. User requests deletion AND
2. Track/album no longer exists on Spotify (verify manually by clicking Spotify link)

### How to Delete (Retool)

1. Go to Track Details in Retool
2. Click Spotify link to verify it 404s
3. If 404: Click "Delete" button
4. If exists: Reject deletion request

**Note**: "Capture from Sources" button does NOT delete anymore (legacy behavior changed).

---

## Entity Restoration

If entity was accidentally deleted:

### Step 1: Try Sync Message

```python
from helpers import trigger_helper

# Send sync without deletion flag
trigger_helper.notify_profile(raw_id="muso:profile:UUID")
```

This may automatically undelete if the sync logic determines entity should exist.

### Step 2: Manual Database Fix (if sync fails)

```javascript
// 1. Fix raw collection (deleted.* subdoc paths — NOT top-level)
db.raw_profile.updateOne(
  { _id: "muso:profile:UUID" },
  {
    $set: { "deleted.is_deleted": false },
    $unset: { "deleted.deleted_timestamp": "", "deleted.deleted_by": "" }
  }
)

// 2. Trigger sync to propagate to catalog
// Use Python helper or send SQS message
```

### Step 3: Fix Catalog Directly (last resort)

```javascript
db.catalog_profile.updateOne(
  { _id: "UUID" },
  {
    $set: { "deleted.is_deleted": false },
    $unset: { "deleted.deleted_timestamp": "", "deleted.deleted_by": "" }
  }
)
```

**Never** `$set` top-level `is_deleted` / `deleted_timestamp` / `deleted_by` —
that creates phantom top-level fields the pipeline ignores, while the real
`deleted.*` subdoc keeps its previous state.

---

## Hard Delete vs Soft Delete

| Entity Type | Delete Type | Location |
|-------------|-------------|----------|
| Track, Album, Profile | **Soft** | `catalog_*` collections |
| Credits inside track | **Hard** | Removed from `profiles` array |
| Raw relationships | **Soft** | `raw_*_credit` collections |

### Example: Deleting a Credit

When a credit (profile-track relationship) is deleted:

1. Raw: `raw_recording_credit` marked `deleted.is_deleted: true`
2. Catalog: Profile hard-removed from track's `profiles` array
3. Restoration: Undelete raw → sync → profile re-added to track

---

## Related Files

- `delete_profile.py` — Profile deletion notebook
- `common_issues.py` — General helper notebook with sync triggers
- `config_local.ini` — Production database credentials (Keybase)

---

Last updated: 2026-07-12 (deletion field paths corrected to the `deleted.*`
embedded subdoc after the task #200 false-resurrection RCA; originally from
KT 2026-01-20)
