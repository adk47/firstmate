# IPI Linking Workflow

How to handle requests to add/verify IPI numbers for publisher profiles.

## Step 1: Check IPI Status in MLC

Run this query to see if the IPI exists in MLC and if it's linked to a Muso profile:

```sql
SELECT
    _id,
    name,
    is_deleted,
    m.*
FROM "platform-industry-bi-prod".matvw_catalog_profile AS p
CROSS JOIN UNNEST(raw_profile_ids) AS pr(rid)
RIGHT JOIN (
    SELECT
        'mlc:' || CAST(feedproviderspartyid AS VARCHAR) AS rid,
        ipinamenumber,
        fullname
    FROM "platform-industry-mlc-bi-prod".parties
    WHERE ipinamenumber IN (
        1026291486  -- Replace with IPI(s) to look up
    )
) AS m USING(rid)
ORDER BY is_deleted, ipinamenumber, _id
```

## Step 2: Handle Based on Result

### Case 1: IPI Already Linked to Correct Profile
- Query returns a profile that matches the user's intended profile
- **Action**: Done! No changes needed
- Example: `https://credits.muso.ai/profile/7855b1d2-f6a3-4bd9-8995-51c115be7c3b`

### Case 2: IPI Linked to Wrong Profile (Needs Merge)
- Query returns a profile, but it's not the user's intended profile
- **Action**: Use Retool to merge that profile into the correct one
- Common scenario: Profile needs to be merged into company/publisher profile

### Case 3: IPI Missing from MLC
- Query returns nothing (no rows)
- **Action**: Tell user to:
  1. Register in MLC first at https://portal.themlc.com
  2. Ensure their works have recordings linked to them
- We cannot add IPI if it doesn't exist in MLC database

## IPI Format Requirements

**IMPORTANT**: IPIs must be 11 characters with leading zeros!

```
❌ 1026291486     (10 digits - wrong)
✅ 01026291486    (11 digits - correct)
```

## MLC Public Search

You can verify IPIs in MLC's public database:
- **URL**: https://portal.themlc.com/search#publisher
- Search by publisher name or IPI
- Useful for verifying before running queries

## Handling Multiple IPIs (Profile Splitting)

When a profile has multiple IPIs that need to be relinked to a new profile:

1. Query with ALL the IPIs to find all affected profiles:
```sql
WHERE ipinamenumber IN (
    1026291486,
    2034567890,
    3045678901
    -- Add all IPIs
)
```

2. Review results - each row is a profile that needs to be:
   - **Unmerged** from the old profile
   - **Merged** into the new profile

3. Use Retool for unmerge/merge operations

4. **Note**: Credits and analytics update the next day after merge

## Limitations

- **Profile splitting is tricky** - requires understanding which sources to unlink
- **Ops team lacks tooling** for complex cases - escalate to engineering
- Future improvement: Unlinking specific MLC raw_id could auto-unmerge

## Example Workflow

User request: "Add IPI 01026291486 to Luzonic Publishing profile"

1. Run IPI query → Found linked to "Luzonic Entertainment" (wrong profile)
2. Check if user wants to separate entities → Yes, new profile exists
3. Query all IPIs on old profile to find profiles needing relink
4. Unmerge → Merge each affected profile in Retool
5. Notify user: "Credits and analytics will update tomorrow"
