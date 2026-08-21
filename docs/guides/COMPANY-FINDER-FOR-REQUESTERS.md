# Company Finder: how to ask Scout for companies

For McLaren, Nick, and Aaron. If you are debugging the pipeline itself, you want
`workspaces/scout/skills/muso-outreach-discovery/SKILL.md` instead.

## Ask like this

```
@Scout find me 5 companies in category Creator production tools
```

That is the whole prompt. **Do not paste a criteria template.**

The rules already live inside Scout's skill and are applied to every batch: niche fit,
real website, active LinkedIn page, genuinely new, visible marketing spend in the last
12 months, English-speaking or US/UK/EU market, 2 to 500 employees, not a Muso
competitor, not dead or acquired, parents rather than subsidiaries. Tier 1 to 3 are
surfaced and labelled; Tier 4 only if you ask.

Pasting an older copy of those rules does not add anything, and if the paste has drifted
from the skill it can actively break the run. One old template told Scout to check each
candidate one at a time, which used up its dedupe budget on the first company and
returned an empty batch. If you have that template saved anywhere, delete it.

## What you can steer

| You want | Say |
|---|---|
| A different count | "find me 8 companies in ..." (10 is the per-run cap) |
| A specific tier | "Tier 1 and 2 only" |
| A different angle | "... in category X, focus on UK and EU" |

Anything else, just say it in plain language.

## Reading the answer

- **A batch in #company-finder** is the finished product. Every company in it has been
  deduped against our CRM and the Seen Ledger, and its website was checked live. React
  with a tick or thumbs up to approve, or reply with the ones to reject.
- **"Category looks mined out: N of M already in our base"** means the category is
  genuinely used up, not that Scout failed. Zero new companies is a real and correct
  answer for a category we have worked hard. Try an adjacent category.
- **A short wait ("results in about N minutes")** is normal. Scout limits how often it
  can run the expensive dedupe pass. It will tell you when it can retry, then deliver.
  You do not need to chase anyone.

## Checking a category before you ask

To see how mined out a category already is, on node-8:

```bash
bash /opt/hydra/scripts/company-finder/category-saturation.sh
```

That prints per-category counts of what is already in the CRM, already suggested,
approved, and rejected.

## When to get a human

Scout handles rate limits, mined-out categories, and its own mistakes on its own, and
should tell you what it is doing. Escalate to Nick only if Scout reports a genuine
outage, for example a dedupe source or the ledger being unavailable, or if a batch never
arrives and Scout has gone quiet.
