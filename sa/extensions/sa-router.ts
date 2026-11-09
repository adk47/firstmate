/**
 * sa-router - the Router's entire tool surface.
 *
 * A Router Pi session has exactly five tools: sa_ticket, sa_assign, sa_reply,
 * sa_rule, sa_escalate. It has no shell, no file read, no file edit, no write.
 * That is the premise of the factory (design.md section 0.1), so this file
 * registers five tools and nothing else: no commands, no event hooks that run
 * input, no generic "run this" escape hatch.
 *
 * Each tool is a thin wrapper over `python3 <repo>/sa/bin/sa-cli <verb> ...`,
 * executed with pi.exec (no shell). The CLI is the only thing reachable from
 * here, and the CLI has exactly five verbs.
 */

import { type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url)); // <repo>/sa/extensions
const REPO = dirname(dirname(HERE)); // <repo>
const CLI = join(REPO, "sa", "bin", "sa-cli");

type CliResult = { code: number; stdout: string; stderr: string };

async function runCli(
  pi: ExtensionAPI,
  args: string[],
  signal: AbortSignal | undefined,
): Promise<CliResult> {
  const result = await pi.exec("python3", [CLI, ...args], { signal });
  return {
    code: result.code ?? 0,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function render(result: CliResult): {
  content: { type: "text"; text: string }[];
  details: CliResult;
} {
  const text =
    result.code === 0
      ? result.stdout.trim()
      : `sa-cli failed (exit ${result.code}): ${result.stderr.trim()}`;
  return { content: [{ type: "text", text }], details: result };
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "sa_ticket",
    label: "SA ticket",
    description:
      "Open a ticket. Returns the ticket id. This is the only way to create work.",
    parameters: Type.Object({
      title: Type.String({ description: "One-line ticket title" }),
      body: Type.String({ description: "What the requester wants" }),
      requester: Type.String({ description: "Who asked for it" }),
      acceptance: Type.Optional(
        Type.String({
          description:
            'JSON acceptance object, e.g. {"command":"pytest -q"} or {"signal":"exit:0"}',
        }),
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const args = [
        "ticket",
        "--title",
        params.title,
        "--body",
        params.body,
        "--requester",
        params.requester,
      ];
      if (params.acceptance !== undefined) {
        args.push("--acceptance", params.acceptance);
      }
      return render(await runCli(pi, args, signal));
    },
  });

  pi.registerTool({
    name: "sa_assign",
    label: "SA assign",
    description: "Assign a ticket to an owner, with the reason for the choice.",
    parameters: Type.Object({
      ticket: Type.String({ description: "Ticket id, e.g. T-0001" }),
      owner: Type.String({ description: "Owner to assign the ticket to" }),
      reason: Type.String({ description: "Why this owner" }),
    }),
    async execute(_toolCallId, params, signal) {
      return render(
        await runCli(
          pi,
          [
            "assign",
            "--ticket",
            params.ticket,
            "--owner",
            params.owner,
            "--reason",
            params.reason,
          ],
          signal,
        ),
      );
    },
  });

  pi.registerTool({
    name: "sa_reply",
    label: "SA reply",
    description: "Post a reply on a ticket's thread.",
    parameters: Type.Object({
      ticket: Type.String({ description: "Ticket id, e.g. T-0001" }),
      text: Type.String({ description: "Reply text" }),
    }),
    async execute(_toolCallId, params, signal) {
      return render(
        await runCli(
          pi,
          ["reply", "--ticket", params.ticket, "--text", params.text],
          signal,
        ),
      );
    },
  });

  pi.registerTool({
    name: "sa_rule",
    label: "SA rule",
    description: "Record a ruling on a ticket, with its rationale.",
    parameters: Type.Object({
      ticket: Type.String({ description: "Ticket id, e.g. T-0001" }),
      ruling: Type.String({ description: "The ruling" }),
      rationale: Type.String({ description: "Why this ruling" }),
    }),
    async execute(_toolCallId, params, signal) {
      return render(
        await runCli(
          pi,
          [
            "rule",
            "--ticket",
            params.ticket,
            "--ruling",
            params.ruling,
            "--rationale",
            params.rationale,
          ],
          signal,
        ),
      );
    },
  });

  pi.registerTool({
    name: "sa_escalate",
    label: "SA escalate",
    description: "Escalate a ticket to someone, with the reason.",
    parameters: Type.Object({
      ticket: Type.String({ description: "Ticket id, e.g. T-0001" }),
      to: Type.String({ description: "Who to escalate to" }),
      why: Type.String({ description: "Why it is being escalated" }),
    }),
    async execute(_toolCallId, params, signal) {
      return render(
        await runCli(
          pi,
          [
            "escalate",
            "--ticket",
            params.ticket,
            "--to",
            params.to,
            "--why",
            params.why,
          ],
          signal,
        ),
      );
    },
  });
}
