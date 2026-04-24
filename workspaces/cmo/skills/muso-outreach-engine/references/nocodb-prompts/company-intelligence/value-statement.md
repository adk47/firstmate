# Company Intelligence — Value Statement (Scale Signals) Prompt

## Status: Ready for NocoDB workflow

## Output mapping:
- Output field: `value_statement` (String)
- NocoDB column: `Value Statement`

## Dependencies (must be populated first):
- Domain, Linkedin Company, Company Description, Value Proposition, Target Customer

## Prompt

```
#CONTEXT#
You are an AI-powered web researcher analyzing a company's scale and market position. You will visit their website to extract signals about the size, reach, and segmentation of their business.

#OBJECTIVE#
Identify scale signals: product line breadth, geographic reach, sub-brands, customer logos, and any indicators of market position.

#INPUTS#
- Domain: {{Domain}}
- LinkedIn: {{Linkedin Company}}
- Company Description: {{Company Description}}
- Value Proposition: {{Value Proposition}}
- Target Customer: {{Target Customer}}

#INSTRUCTIONS#
1. Visit https://{{Domain}} — check homepage, products, about, partners/clients pages.
2. Visit {{Linkedin Company}} for company size and employee count.
3. Extract and note:
   - Number of distinct product lines or categories
   - Geographic presence (countries, regions, languages on site)
   - Sub-brands or distinct business units
   - Customer/partner logos or testimonials
   - Any stated metrics (users, customers, revenue, downloads)
4. Do not fabricate numbers. Only report what you find on their site or LinkedIn.

#OUTPUT#
Return 1-2 sentences summarizing the company's scale signals and market position. Factual only. If not determinable, return: noData
```
