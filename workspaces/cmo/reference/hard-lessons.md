# Hard Lessons (keep these forever)

The expensive ones. Never lose these, even as memory gets rotated.

- **Batch QA failures**: Sent batches without proper QA; caught errors post-send. Always validate before bulk operations.
- **Crosscheck failures**: Attributed data to wrong sources, mixed up metrics between platforms. Triple-check data provenance.
- **GHL auto-sync**: GoHighLevel syncs can overwrite manual edits. Be aware of sync direction and timing.
- **GHL pagination**: API paginates differently than standard REST. Always handle pagination explicitly. Check for next page tokens.
- **Follow-up draft failures**: Generated drafts that didn't match brand voice. All drafts get a Nick review.
- **EOD spam incident (Feb 27)**: Sent 5+ duplicate EOD reports. Rule: EOD is ONCE per day only. Track in state.
- **Message attribution**: Check sender_id EVERY TIME against the people roster. Jan = U038BM16T7W. Never infer from content. Misattribution destroys trust.
- **Athena ≠ lead sourcing**: Got this wrong by trusting old Clio migration notes. Always verify inherited context with Nick. (2026-04-11)
- **Never guess domains**: Posted 8 fake/dead domains in a 50-company batch. ygaacoustics.com, minimalaudio.com, superbavox.com, soundlily.com, monstermusician.com, festicket.com, chromatik.com, soundfocus.com — none existed. DNS + HTTP + content validation is mandatory before posting. (2026-04-11)
- **Validate industry fit**: LingoAce, Domestika, Panda Corner were posted as music companies but had zero music connection. Always fetch homepage and confirm industry relevance. (2026-04-11)
- **Use native Slack tables**: A table was asked for 5 times before I figured out Slack has Block Kit `table` blocks. Code blocks, TSVs, CSVs, and pipe-aligned text are NOT tables. Use `blocks` parameter with `type: table`. (2026-04-11)
- **Check acquisitions**: Nura (acquired by Masimo/Denon), Community Loudspeakers (acquired by Biamp), Festicket (rebranded to DICE). Always verify companies still operate independently. (2026-04-11)
- **Never cite numbers from memory**: Said "~199 contacts" when it was 1,249. Inaccuracy is not tolerated (team rule). ALWAYS pull the real number from the source system before quoting it. No approximations, no stale data. (2026-04-11)
- **No em dashes**: Never write an em dash in any output (emails, Slack, drafts). Use a comma, colon or full stop. Team rule.
- **No self-initiative**: Prep, analysis and drafting are fine. Executing changes only when Nick asks. Team rule.
- **Batch QA**: Every outreach batch is QA'd before sending. No bulk sends without review. Team rule.
