# Operations Runbooks

Step-by-step workflows for common operational tasks.

## Available Runbooks

| File | Purpose |
|------|---------|
| `openclaw-environment-setup.md` | **READ THIS FIRST** - How to configure environment variables for CLI tools in OpenClaw |
| `stripe-payments.md` | **USE THIS FOR PAYMENT/REFUND QUERIES** - Stripe CLI commands for refunds, payments, customers, subscriptions |
| `user_requests_workflow.md` | ClickUp workflow for handling user requests, service health checks |
| `entity_deletion.md` | Profile/track/album deletion procedures, restoration steps |
| `ipi_linking_workflow.md` | Handle IPI add/verify requests for publisher profiles |
| `retool.md` | Retool internal admin panel - workspace management, user lookup, SSO setup |
| `data-access.md` | Data access patterns + secret hygiene (read-only posture, tunneling, env var names) |
| `knowledge-base-configuration.md` | How this knowledge-base repo is configured + deployment checklist |

## When to Use

Load these runbooks when:
- Handling user requests from ClickUp
- Deleting or restoring profiles, tracks, or albums
- Handling customer support requests about profile data
- Processing IPI/publisher linking requests
- Debugging profile merge/unmerge issues
- Working with MLC data integration
- Managing workspaces in Retool
- Looking up users or artists
- Setting up SSO clients for partners
- Managing Encore plaques

## Key Tools

| Tool | URL | Purpose |
|------|-----|---------|
| **Retool** | [musoai.retool.com](https://musoai.retool.com/) | Internal admin panel |
| **Slack** | #b2b-onboarding | Workspace cleansing requests |
| **Amplitude** | - | User analytics lookup |
| **Klaviyo** | - | User login email sends |
