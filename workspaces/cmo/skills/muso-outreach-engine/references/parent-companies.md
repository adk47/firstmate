# Parent Company Mapping

Companies we track at the PARENT level only. Subsidiaries are rolled up to the
parent to avoid duplicate outreach and to kill multiple birds with one contact.

When outreach is done to a parent, treat all listed subsidiaries as covered.

## Known Parent Companies

### Audiotonix (audiotonix.com)
- solidstatelogic.com, SSL
- slatedigital.com, Slate Digital
- allen-heath.com, Allen & Heath
- sounddevices.com, Sound Devices
- jhaudio.com, JH Audio

### Music Tribe (behringer.com)
- tcelectronic.com, TC Electronic
- tchelicon.com, TC-Helicon
- turbosound.com, Turbosound
- wharfedaleproaudio.com, Wharfedale Pro
- tannoy.com, Tannoy

### HARMAN / Samsung (jblpro.com)
- akg.com, AKG
- crownaudio.com, Crown
- dbxpro.com, dbx
- lexiconpro.com, Lexicon

### inMusic (akaipro.com)
- numark.com, Numark
- headrushfx.com, HeadRush
- digitech.com, DigiTech

### Roland (roland.com)
- boss.info, BOSS

### Gibson (gibson.com)
- mesaboogie.com, Mesa/Boogie

### Yamaha (yamaha.com)
- ampeg.com, Ampeg

### KORG (korg.com)
- voxamps.com, VOX

## Rules

1. Target only the parent domain. Never cold outreach a subsidiary if the parent
   is already in NocoDB or has been contacted.
2. When the daily company finder surfaces a subsidiary of a known parent, collapse
   the result to the parent and skip.
3. When the finder surfaces a new parent that owns subsidiaries already in NocoDB,
   flag it for rollup: add the parent here, update NocoDB Contacts Intelligence
   (`m9vsbijhrr9ddeu`) to reflect the parent relationship, and remove or deactivate
   the subsidiary rows.
4. If a subsidiary has a meaningfully separate audience from the parent (very
   different product line, different buyer), flag it for Fede review before
   adding as a separate entry.
5. Use the parent's primary domain as the canonical entry in NocoDB Company Intelligence (`mvr6nmzcv7albxt`).

## How to Add a New Parent

When discovering a new parent during the daily company finder or during manual
research:

1. Add the parent under a new `### {Parent Name} ({domain})` heading
2. List known subsidiaries below as `- domain, short name`
3. Update NocoDB Company Intelligence (`mvr6nmzcv7albxt`) to mark the parent as `Parent Company = TRUE`
4. Remove or deactivate duplicate subsidiary rows in NocoDB Contacts Intelligence (`m9vsbijhrr9ddeu`)
5. Post a note to `#company-finder` describing the rollup so Fede can sanity check

## History

- 2026-04-09: initial mapping captured for Audiotonix, Music Tribe, HARMAN, inMusic,
  Roland, Gibson, Yamaha, KORG (9 parents, 18 subsidiaries).
