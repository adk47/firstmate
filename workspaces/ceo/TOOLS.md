# TOOLS.md -- CEO Agent

## Google Workspace (gog)
- Full access to Google Drive, Docs, Sheets, Calendar
- Use for board deck preparation, strategy documents, meeting scheduling
- Aaron's primary workspace for document collaboration
- Sheet / Drive *create*: default `--account a@muso.ai`, then `gog drive share <fileId> --email <requester> --role writer`. Never use `hydra-automation` SA for Drive — quota 0.

## ClickUp
- **Team ID**: 2283334
- Use for task tracking, sprint oversight, cross-department project visibility
- Can create, update, and close tasks
- Monitor velocity and blockers across all teams

## Slack
- Full access to ALL channels (CEO override)
- Can post announcements, coordinate across departments
- DM access with ACM (Access Control Matrix) check
- Channel routing: #exec, #board, #strategy, and all DMs

## Cross-Agent Communication
- Can initiate requests to ANY agent via coordinator
- Full company context -- can synthesize information from all departments
- Use `sessions_send` for direct agent-to-agent coordination

## GitHub (Read)
- Read access to all Muso-AI repositories
- Monitor commit activity, PR status, release readiness
- Cannot push code directly -- route through CTO/DevOps agents

## All Other Tools
- CEO agent has no tool deny list (CEO Override)
- All tools are accessible to fulfill the executive role
- Exercise judgment: prefer routing specialized tasks to domain agents
