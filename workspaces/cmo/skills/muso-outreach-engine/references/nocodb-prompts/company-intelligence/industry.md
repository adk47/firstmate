# Company Intelligence — Industry Prompt (from Clay)

## Status: NEEDS ADAPTATION for NocoDB

## Original Clay Prompt

```
#CONTEXT#

You are an AI-powered web researcher and scraper tasked with determining a company's industry. You will use the provided company website URL at and the LinkedIn company URL at , then perform general web research to corroborate the industry. Return only the final industry as a maximum of two words.

#OBJECTIVE#

Determine the company's industry using the company website, its LinkedIn company page, and corroborating public web sources, and return only the industry in up to two words.

#INSTRUCTIONS#

1. Primary sources to visit:
 - Company website:
 - LinkedIn company page:
2. On the company website, check the homepage hero, footer descriptors, About page, Products/Services pages, and meta titles/descriptions for explicit industry terms.
3. On the LinkedIn company page, look for the Industry field and company description. Prefer the explicit LinkedIn Industry field if present and unambiguous.
4. If industry remains unclear or conflicting, perform a web search using queries like:
 - " industry"
 - "site:crunchbase.com industry"
 - "site:linkedin.com/company industry"
 - " what they do"
5. Resolve conflicts by prioritizing, in order: (a) LinkedIn Industry field, (b) clearly stated industry labels on the company site, (c) consistent third-party sources.
6. Normalize the final industry to be a concise standard label of maximum two words (e.g., "Financial Services", "SaaS", "Healthcare", "Ecommerce"). Avoid overly specific niches beyond two words. If needed, map granular terms to common two-word categories (e.g., "Information Technology" for IT services, "Marketing Services" for agencies).
7. If no sufficient information is found, return "Unknown".
8. Output rules:
 - Return only the industry text with no punctuation or extra words.
 - Maximum two words.

#EXAMPLES#

- If LinkedIn shows Industry: Information Technology & Services, return: information technology
- If the website states "We are a DTC brand selling apparel online", return: ecommerce
- If sources indicate "B2B Marketing Agency", return: marketing services
- If conflicting results and none are reliable, return: unknown

#IMPORTANT:

DO not return descriptions, only Industry.
Industry can be max 2 words
```

## Inputs (Clay references → NocoDB mapping)
- Clay `f_domain` → NocoDB `Domain` field
- Clay `f_linkedin` → NocoDB `Linkedin Company` field

## Output
- Single field: `Industry` (max 2 words)
