#!/usr/bin/env bash
set -euo pipefail

# HYDRA Clio Knowledge Extraction
# ================================
# Runs 9 extraction prompts against Clio (Mac Mini) to populate
# agent workspaces with domain knowledge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLIO_HOST="${CLIO_HOST:-clio.local}"
CLIO_PORT="${CLIO_PORT:-8080}"
CLIO_API="${CLIO_API:-http://$CLIO_HOST:$CLIO_PORT/api/v1/extract}"
OUTPUT_DIR="$HYDRA_ROOT/extraction"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

mkdir -p "$OUTPUT_DIR"

extract() {
  local agent="$1"
  local prompt="$2"
  local output_file="$OUTPUT_DIR/${agent}.md"

  log "Extracting: $agent..."
  RESPONSE=$(curl -sf -X POST "$CLIO_API" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json
print(json.dumps({
    'prompt': '''$prompt''',
    'format': 'markdown',
    'max_tokens': 8000
}))
")" 2>&1) || {
    log "  ERROR: Extraction failed for $agent"
    return 1
  }

  echo "$RESPONSE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('content', data.get('text', json.dumps(data, indent=2))))
" > "$output_file" 2>/dev/null || {
    # If JSON parsing fails, write raw response
    echo "$RESPONSE" > "$output_file"
  }

  log "  Saved to $output_file ($(wc -c < "$output_file") bytes)"
}

# -------------------------------------------------------------------
# Extraction 1: CEO — Company strategy & board context
# -------------------------------------------------------------------
extract "ceo" "
Extract all company strategy information including:
- Mission statement, vision, and core values
- Board meeting notes and strategic decisions
- Investor relations and fundraising context
- Company OKRs and quarterly goals
- Competitive landscape and positioning
- Revenue targets and growth strategy
- Key partnerships and business development initiatives
Focus on context that a CEO-level AI agent would need to make strategic decisions.
"

# -------------------------------------------------------------------
# Extraction 2: CMO — Marketing campaigns & brand voice
# -------------------------------------------------------------------
extract "cmo" "
Extract all marketing and brand information including:
- Brand guidelines, voice, and tone documentation
- Active and past marketing campaigns with performance data
- Content calendar and editorial strategy
- Social media strategy and engagement metrics
- SEO/SEM strategy and keyword targets
- Email marketing templates and sequences
- Customer acquisition channels and CAC metrics
- Competitor marketing analysis
- Press releases and media coverage
Focus on context that a CMO-level AI agent would need to drive growth and brand consistency.
"

# -------------------------------------------------------------------
# Extraction 3: CTO — Technical architecture & codebase patterns
# -------------------------------------------------------------------
extract "cto" "
Extract all technical architecture information including:
- System architecture diagrams and descriptions
- Tech stack decisions and rationale
- API design patterns and conventions
- Database schemas and data models
- Codebase organization and module boundaries
- Technical debt inventory and priorities
- Performance benchmarks and SLAs
- Security architecture and threat models
- Development workflow and branching strategy
- Dependency management and upgrade policies
Focus on context that a CTO-level AI agent would need to make technical decisions and guide development.
"

# -------------------------------------------------------------------
# Extraction 4: QA — Test patterns & QA processes
# -------------------------------------------------------------------
extract "qa" "
Extract all quality assurance information including:
- Test strategy and coverage requirements
- Test automation frameworks and patterns
- E2E test suites and their organization
- Regression test procedures
- Bug triage process and severity definitions
- Performance testing benchmarks
- Security testing checklists
- Release qualification criteria
- Known flaky tests and workarounds
- Test environment configurations
Focus on context that a QA-level AI agent would need to ensure product quality.
"

# -------------------------------------------------------------------
# Extraction 5: Finance — Financial data & budget context
# -------------------------------------------------------------------
extract "finance" "
Extract all financial operations information including:
- Budget allocations by department
- Monthly burn rate and runway
- Revenue streams and pricing models
- Vendor contracts and payment schedules
- Payroll structure and compensation bands
- Financial reporting templates and cadence
- Tax compliance requirements
- Expense approval workflows
- Financial forecasting models
- Audit trail requirements
Focus on context that a Finance-level AI agent would need for financial operations and reporting.
"

# -------------------------------------------------------------------
# Extraction 6: Operations — Ops processes & support workflows
# -------------------------------------------------------------------
extract "operations" "
Extract all operations information including:
- Customer support workflows and escalation paths
- SLA definitions and response time targets
- Onboarding processes for customers and employees
- Incident response procedures
- Vendor management processes
- Office/facility operations
- HR policies and procedures
- Meeting cadences and team rituals
- Tool stack for operations (Zendesk, Intercom, etc.)
- Customer feedback collection and processing
Focus on context that an Operations-level AI agent would need to manage day-to-day business operations.
"

# -------------------------------------------------------------------
# Extraction 7: DevOps — Infrastructure knowledge & runbooks
# -------------------------------------------------------------------
extract "devops" "
Extract all infrastructure and DevOps information including:
- Server inventory and specifications
- Kubernetes cluster configuration and namespaces
- CI/CD pipeline architecture and scripts
- Monitoring and alerting rules
- Backup and disaster recovery procedures
- SSL/TLS certificate management
- DNS configuration and domain management
- Network topology and firewall rules
- Deployment runbooks and rollback procedures
- Capacity planning and scaling thresholds
- Secret management (Vault paths, ESO config)
Focus on context that a DevOps-level AI agent would need to manage infrastructure.
"

# -------------------------------------------------------------------
# Extraction 8: Design — Design system & UX patterns
# -------------------------------------------------------------------
extract "design" "
Extract all design information including:
- Design system components and tokens
- Color palette, typography, and spacing scales
- Component library documentation
- UX patterns and interaction guidelines
- Accessibility standards and WCAG compliance
- Responsive design breakpoints
- Icon system and illustration style
- User research findings and personas
- Information architecture and navigation patterns
- Design review process and approval workflow
Focus on context that a Design-level AI agent would need to maintain design consistency.
"

# -------------------------------------------------------------------
# Extraction 9: Coordinator — Routing rules & cross-agent protocols
# -------------------------------------------------------------------
extract "coordinator" "
Extract all cross-functional coordination information including:
- Team communication patterns and channels
- Decision-making frameworks and RACI matrices
- Cross-team dependencies and handoff protocols
- Meeting agendas and action item tracking
- Project management workflows
- Escalation paths for different issue types
- Stakeholder mapping and communication preferences
- Status reporting templates and cadence
- Knowledge sharing processes
- Inter-department SLAs and contracts
Focus on context that a Coordinator AI agent would need to route requests between departments.
"

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
log ""
log "Extraction complete. Output files:"
for f in "$OUTPUT_DIR"/*.md; do
  log "  $(basename "$f"): $(wc -c < "$f") bytes"
done
log ""
log "Next step: Review and copy relevant content into workspaces/<agent>/context/"
