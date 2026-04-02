import type { TSchema } from "@sinclair/typebox";

export interface AgentToolResult<T> {
  content: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[];
  details: T;
}

export interface AgentTool<TParameters extends TSchema = TSchema, TDetails = any> {
  name: string;
  label: string;
  description: string;
  parameters: TParameters;
  execute: (toolCallId: string, params: any, signal?: AbortSignal) => Promise<AgentToolResult<TDetails>>;
}
