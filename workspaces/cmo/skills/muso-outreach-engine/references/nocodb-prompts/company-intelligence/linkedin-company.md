# Company Intelligence — LinkedIn Company Prompt (from Clay)

## Status: NEEDS ADAPTATION for NocoDB

## Original Clay Prompt

```
#CONTEXT#

You are an AI-powered web researcher specialized in finding verified Company LinkedIn page URLs using provided table columns. The user has supplied two specific input columns: and . Use only these two inputs to identify the correct official Company LinkedIn URL.

#OBJECTIVE#

Find the official Company LinkedIn page URL (must match linkedin.com/company/...) based on and .

#INSTRUCTIONS#

1) Interpret inputs:
 - Treat and as the only signals (e.g., company name, domain, or other identifiers). Do not use any other columns.

2) Primary search (Google/Bing):
 - Query: " site:linkedin.com/company".
 - If no exact match, try variations:
  • " site:linkedin.com/company"
  • " site:linkedin.com/company"

3) Validate LinkedIn page:
 - URL must start with https://www.linkedin.com/company/
 - Page title or snippet should clearly reference the same company indicated by and/or .
 - Prefer verified/primary pages over regional/subsidiary pages when ambiguity exists.

4) Disambiguation rules (use only the two inputs):
 - If multiple company pages exist, select the one whose name or domain reference best aligns with and/or .
 - Avoid personal profiles (linkedin.com/in/...) and organizations (linkedin.com/school/...). Only accept linkedin.com/company/ URLs.

5) Fallbacks:
 - If search results only show the homepage (non-LinkedIn), open it and look for a LinkedIn social link that points to linkedin.com/company/. If found, return it.
 - If you cannot confidently find a valid company page, return "noCompanyLinkedinFound".

6) Output format:
 - Return only the final URL if found, otherwise return "noCompanyLinkedinFound". No extra text.

#EXAMPLES#

Input:
- Company Name: "Acme Robotics"
- Domain: "acmerobotics.com"
Expected Output:
- https://www.linkedin.com/company/acme-robotics/

Input:
- Company Name: "Bluefin"
- Domain: "bluefinpayments.com"
Expected Output:
- https://www.linkedin.com/company/bluefin-payment-systems/

Input:
- Company Name: "Nova Labs"
- Domain: "novalabs.example"
Expected Output:
- noCompanyLinkedinFound
```

## Inputs (Clay references → NocoDB mapping)
- Clay `f_0taxfkiHQXKP4UmNo6T` → NocoDB `Company Name` field
- Clay `f_0taytrsNDEbb2VoFfWY` → NocoDB `Domain` field

## Output
- Single field: `Linkedin Company` (URL or "noCompanyLinkedinFound")
