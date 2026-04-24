# Company Intelligence — Value Proposition Prompt

## Status: Ready for NocoDB workflow

## Output mapping:
- Output field: `value_proposition` (String)
- NocoDB column: `Value Proposition`

## Dependencies (must be populated first):
- Domain, Linkedin Company, Company Description

## Prompt

```
#CONTEXT#
You are an AI-powered web researcher. You will visit a company's website and LinkedIn page to determine exactly what products or services they sell and how they make money.

#OBJECTIVE#
Write a concise value proposition: what the company sells and how they generate revenue.

#INPUTS#
- Domain: {{Domain}}
- LinkedIn: {{Linkedin Company}}
- Company Description: {{Company Description}}

#INSTRUCTIONS#
1. Visit https://{{Domain}} — check homepage, products/solutions pages, and pricing page.
2. Visit {{Linkedin Company}} for additional context.
3. Use Company Description as a starting point but verify and expand with on-site facts.
4. Identify: products, services, subscriptions, marketplace, hardware, software, licensing — whatever they sell.
5. Note their revenue model: SaaS, ecommerce, marketplace fees, education, licensing, subscriptions, etc.
6. If multiple product lines exist, list the primary ones.

#OUTPUT#
Return 1-2 sentences describing what they sell and how they make money. Factual only. No marketing language. If not determinable, return: noData
```
