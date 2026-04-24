# Company Intelligence — Target Customer Prompt

## Status: Ready for NocoDB workflow

## Output mapping:
- Output field: `target_customer` (String)
- NocoDB column: `Target Customer`

## Dependencies (must be populated first):
- Domain, Linkedin Company, Company Description, Value Proposition

## Prompt

```
#CONTEXT#
You are an AI-powered web researcher. You will visit a company's website and LinkedIn page to determine who their target customers are.

#OBJECTIVE#
Identify the specific buyer types, roles, or market segments the company sells to.

#INPUTS#
- Domain: {{Domain}}
- LinkedIn: {{Linkedin Company}}
- Company Description: {{Company Description}}
- Value Proposition: {{Value Proposition}}

#INSTRUCTIONS#
1. Visit https://{{Domain}} — check homepage, about page, customers/case studies, and pricing tiers.
2. Visit {{Linkedin Company}} for additional context.
3. Look for explicit mentions of: customer types, buyer personas, industry verticals, use cases, testimonials, logos.
4. Distinguish between end users and buyers (e.g., "producers use it" vs "labels buy it").
5. Be specific: not "music professionals" but "independent producers, mixing engineers, and small labels."

#OUTPUT#
Return 1-2 sentences naming the specific customer types they target. Factual only — based on what the site actually says. If not determinable, return: noData
```
