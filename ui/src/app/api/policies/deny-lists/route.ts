import { NextRequest, NextResponse } from 'next/server';
import { readFile } from 'fs/promises';

const DENY_LISTS_PATH = process.env.DENY_LISTS_PATH || '/opt/hydra/config/policies/tool-deny-lists.yaml';
const HYDRA_REPO = process.env.HYDRA_REPO || 'Muso-AI/H-DevOps';
const GH_TOKEN = process.env.GH_TOKEN || '';

interface DenyListEntry {
  agent: string;
  tools: string[];
}

async function parseDenyLists(): Promise<DenyListEntry[]> {
  try {
    const raw = await readFile(DENY_LISTS_PATH, 'utf-8');
    const lines = raw.split('\n');
    const entries: DenyListEntry[] = [];
    let currentAgent: string | null = null;
    let currentTools: string[] = [];
    let inTools = false;

    for (const line of lines) {
      // Skip comments and empty lines
      if (line.trim().startsWith('#') || line.trim() === '') continue;

      // Top-level agent key (not indented, ends with colon)
      const agentMatch = line.match(/^(\w+):$/);
      if (agentMatch) {
        if (currentAgent) {
          entries.push({ agent: currentAgent, tools: currentTools });
        }
        currentAgent = agentMatch[1];
        currentTools = [];
        inTools = false;
        continue;
      }

      if (line.match(/^\s+tools:/)) {
        inTools = true;
        continue;
      }

      if (inTools && line.match(/^\s+-\s+/)) {
        currentTools.push(line.replace(/^\s+-\s+/, '').trim());
      }
    }

    if (currentAgent) {
      entries.push({ agent: currentAgent, tools: currentTools });
    }

    return entries;
  } catch {
    return [];
  }
}

export async function GET() {
  const denyLists = await parseDenyLists();

  return NextResponse.json({
    denyLists,
    egressLists: [], // TODO: implement egress list parsing
  });
}

export async function PUT(request: NextRequest) {
  try {
    const changes: Record<string, string[]> = await request.json();

    if (!GH_TOKEN) {
      return NextResponse.json(
        { error: 'GitHub token not configured. Cannot create PR.' },
        { status: 500 }
      );
    }

    // Generate YAML content for the updated deny lists
    let yamlContent = '# Tool deny lists per agent\n# Denials can only grow, never shrink\n\n';
    for (const [agent, tools] of Object.entries(changes)) {
      yamlContent += `${agent}:\n  tools:\n`;
      for (const tool of tools) {
        yamlContent += `    - ${tool}\n`;
      }
      yamlContent += '\n';
    }

    // Create a branch and PR via GitHub API
    const branchName = `policy-update-${Date.now()}`;

    const { execSync } = await import('child_process');

    // Use gh CLI to create the PR
    try {
      // Get current main SHA
      const shaResult = execSync(
        `gh api repos/${HYDRA_REPO}/git/ref/heads/main --jq '.object.sha'`,
        { timeout: 10000, encoding: 'utf-8', env: { ...process.env, GH_TOKEN } }
      );
      const mainSha = shaResult.trim();

      // Create branch
      execSync(
        `gh api repos/${HYDRA_REPO}/git/refs -f ref="refs/heads/${branchName}" -f sha="${mainSha}"`,
        { timeout: 10000, encoding: 'utf-8', env: { ...process.env, GH_TOKEN } }
      );

      // Get current file SHA
      const fileResult = execSync(
        `gh api repos/${HYDRA_REPO}/contents/hydra/policies/tool-deny-lists.yaml --jq '.sha'`,
        { timeout: 10000, encoding: 'utf-8', env: { ...process.env, GH_TOKEN } }
      );
      const fileSha = fileResult.trim();

      // Update file on branch
      const contentBase64 = Buffer.from(yamlContent).toString('base64');
      execSync(
        `gh api repos/${HYDRA_REPO}/contents/hydra/policies/tool-deny-lists.yaml ` +
        `-f message="Update tool deny lists via HYDRA Control" ` +
        `-f content="${contentBase64}" ` +
        `-f sha="${fileSha}" ` +
        `-f branch="${branchName}"`,
        { timeout: 10000, encoding: 'utf-8', env: { ...process.env, GH_TOKEN } }
      );

      // Create PR
      const prResult = execSync(
        `gh pr create --repo ${HYDRA_REPO} --head ${branchName} --base main ` +
        `--title "Update tool deny lists" ` +
        `--body "Automated policy update from HYDRA Control dashboard."`,
        { timeout: 15000, encoding: 'utf-8', env: { ...process.env, GH_TOKEN } }
      );

      const prUrl = prResult.trim();
      return NextResponse.json({ prUrl });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Unknown error';
      return NextResponse.json(
        { error: `Failed to create PR: ${message}` },
        { status: 500 }
      );
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
