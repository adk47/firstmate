# ICP Name Drops

Used in cold email copy to establish credibility with genre relevant artists.

**Always include Bad Bunny.** Then add 2 names relevant to the prospect's
`ICPCategory Label` (from the `company_intelligence` sheet).

All names verified on Muso catalog with real credits as of 2026-03-06.

## Name Drop Table

| ICP Category | Name Drop Line | Why These Names |
|---|---|---|
| Pro Audio / Gear Brands | "from Bad Bunny and Serban Ghenea to Manny Marroquin" | Mixing and mastering engineers the audience worships (Serban: 7,525 credits, Manny: 6,069) |
| Music Software / Plugin Companies | "from Bad Bunny and FINNEAS to Jack Antonoff" | Producer household names who use the tools (FINNEAS: 9,501 credits, Antonoff: 7,805) |
| Music Education / Online Courses | "from Bad Bunny and Poo Bear to Quincy Jones" | Aspirational range: active hitmaker plus living legend |
| Music Services / Platforms | "from Bad Bunny and Max Martin to Pharrell Williams" | Max Martin: 39,644 credits, the GOAT stat for platform buyers |
| Live Sound / Touring / Venues | "from Bad Bunny and Travis Scott to deadmau5" | Touring heavy artists relatable for the live industry |
| Streaming / Content Platforms | "from Bad Bunny and Billie Eilish to Metro Boomin" | Streaming era names with Gen Z appeal |
| Lifestyle / Adjacent Brands | "from Bad Bunny and DJ Snake to Steve Aoki" | Crossover appeal: fashion, lifestyle, brand collabs |
| Music Industry Services | "from Bad Bunny and Rick Rubin to Hans Zimmer" | Breadth flex: pop to film scoring, 10K+ credits each |

## Default (No ICPCategory Match)

When `ICPCategory Label` is missing or does not map to any row above, use:

`from Bad Bunny and Max Martin to Poo Bear`

Universal appeal across music categories.

## Usage in Templates

Insert the name drop line into this sentence pattern:

```
We have nearly 1M active music professionals, {name_drop_line}, using our
platform daily to track credits, catalog, and career data.
```

## Rules

- Always verify a name is on the Muso catalog before using (check Athena
  `public_claiming` or the Muso profiles table).
- Prioritize claimed profiles over unclaimed.
- Names must be currently active (recent credits within the last 2 years).
- When a company has a claimed Muso profile, prioritize names relevant to that
  company's specific niche over the generic ICP mapping.
- If a name becomes controversial or loses cultural standing, drop it from this
  table and replace with a safer current equivalent.

## History

- 2026-03-06: initial table compiled from Muso catalog data
- 2026-04-09: migrated from inline skill content to a dedicated reference file
