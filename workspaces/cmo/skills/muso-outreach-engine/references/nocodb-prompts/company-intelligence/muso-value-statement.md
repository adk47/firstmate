# Company Intelligence — Muso Value Statement Prompt (from Clay)

## Status: NEEDS ADAPTATION for NocoDB

## This is a MULTI-OUTPUT prompt — one call, 5 fields written back

### Output mapping (Clay → NocoDB):
- `whyMusoAdsMattersToT` → `Why Muso Ads Matters`
- `whatTheySell` → `Value Proposition`
- `whoTheySellTo` → `Target Customer`
- `scaleSignals` → `Value Statement`
- `mappedIcpCategory` → `ICPCategory Label`

## Original Clay Prompt

```
#CONTEXT#

You are an AI-powered web scraper, research analyst, and B2B sales strategist for Muso Ads. Your task is to visit a company's website using and combine on-site facts with the provided starting data from ,

 (as description) and craft a precise, 1–2 sentence "Why Muso Ads Matters to Them" value statement. Use only the company's own website for web facts. Muso Ads uniquely reaches 500K+ verified music professionals with role-, stream-tier, credit-count, recency, and geographic targeting, plus multiple campaign types and placements.

#OBJECTIVE#

Visit and extract on-site facts to write a 1–2 sentence value statement for "Why Muso Ads Matters to Them" that explicitly ties the company's business model to Muso Ads' audience and targeting capabilities.

#INSTRUCTIONS#

1) Inputs and starting context:
 - domain:
 - companyName:
 - description: .
 - additionalContext: Search the web
 Use description/additionalContext if they already state what the company sells and to whom. Do not infer other columns.

2) Site browsing scope (static pages only; skip auth/paywalled/JS-heavy areas):
 - Prioritize in order: Homepage → Products/Solutions → About → Customers/Case Studies → Pricing.
 - Only use information found on the company's own website. Do not use LinkedIn, Wikipedia, or third-party sources.

3) Extract and note (do not fabricate):
 - whatTheySell: products/services/subscriptions/marketplace/hardware/software
 - whoTheySellTo: specific music roles or buyer types if stated
 - howTheyMakeMoney: ecommerce, SaaS, marketplace fees, education, licensing, subscriptions
 - scaleSignals: product lines, logos, geography, sub-brands
 - segments/subBrands: any distinct product categories that map to different Muso targeting setups

4) Map to closest ICP from these categories (based on site facts + description/additionalContext):
 - Pro Audio/Gear Brands; Music Software/Plugin Companies; Music Education/Online Courses; Music Services/Platforms; Streaming/Content Platforms; Live Sound/Touring/Venues; Music Industry Services; Lifestyle/Adjacent Brands.

5) Compose the 1–2 sentence output following these rules:
 - Name specific Muso targeting dimensions that apply (e.g., role types with approximate counts: Producer ~61.8K, Primary Artist ~134K, Mixing Engineer ~41K, Mastering Engineer ~12.4K, Composer ~129K; stream tiers; credit-count ranges; credit recency windows; geography like USA 272K, UK 36K, etc.). Use only these provided approximations; do not invent new numbers.
 - Reference the most fitting campaign type (Offer, Brand Awareness, Sponsorship/Giveaway) and, when relevant, placements ("For You" for hyper-targeting, Email for high open rate 63%, Push for time-sensitive, Feed, AMP Shop, Social Media).
 - Connect their revenue model to Muso's audience (e.g., "every producer on Muso is a potential buyer for their plugin suite"). Mention multi-product potential if applicable.
 - Reference concrete on-site facts (product categories, target markets, customer types) found on or in description/additionalContext.
 - Be outcome-specific (product launches, conversions, awareness among decision-makers).
 - Length: maximum 2 sentences. Avoid generic statements, vague claims, corporate jargon, and any invented data.

6) Failure handling:
 - If is inaccessible or lacks useful on-site info, fall back to confirmed details in , and .
 - Produce a conservative 1–2 sentence statement using only confirmed facts and the most logical Muso targeting dimension for that category.

#EXAMPLES#

Input (site facts summarized): Kali Audio makes studio monitors and subs for producers and engineers.
Expected output: "Kali can run Offer campaigns targeting the 61K+ producers and 41K+ mixing engineers on Muso by role, then use stream-tier filtering to match their budget-friendly line to emerging creators and their premium monitors to established pros with 100M+ streams. With 272K US users and geographic targeting across 210 countries, they can align campaigns precisely to their distribution footprint."

Input (site facts summarized): Splice is a sample marketplace with rent-to-own plugins and AI tools for producers.
Expected output: "Splice can target producers and composers who added credits in the last 30-90 days—people actively in the studio right now who need fresh samples and tools. Their rent-to-own plugin model is a natural fit for credit-count targeting: emerging producers (under 25 credits) building their toolkit with affordable access vs established names (100+) upgrading to premium."

Input (site facts summarized): iZotope sells mastering, mixing, and repair software.
Expected output: "iZotope can run separate 'For You' campaigns for each product line—mastering engineers (~12.4K) for Ozone, mixing engineers (~41K) for Neutron, and sound designers for RX—using granular role targeting across 145 verified role types. That's precision impossible on Meta or LinkedIn, where 'producer' could mean anyone with a SoundCloud account."
```

## Inputs (Clay references → NocoDB mapping)
- Domain → `Domain`
- Company Name → `Company Name`
- Description → `Company Description` (CASCADE: must be populated first)
- Additional context → web search

## Dependencies
- Requires `Company Description` to be populated first (cascade from company-description prompt)
- Requires `Domain` and `Company Name` as manual inputs
