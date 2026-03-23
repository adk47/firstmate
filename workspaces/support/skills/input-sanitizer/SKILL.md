---
name: input-sanitizer
description: Pre-processing rules for customer messages before they reach the LLM
triggers: []
---

# Input Sanitizer

## Purpose

Pre-process all incoming customer messages before they reach the LLM. This skill defines rules enforced by the runtime layer (not by the LLM itself).

## Pre-Processing Steps (applied in order)

### 1. Strip Control Characters
Remove all control characters that could be used for injection:
- Null bytes (`\x00`)
- Backspace (`\x08`)
- Unicode RTL override (`\u202E`, `\u202D`, `\u200F`)
- Unicode zero-width characters (`\u200B`, `\u200C`, `\u200D`, `\uFEFF`)
- Bell (`\x07`), vertical tab (`\x0B`), form feed (`\x0C`)

**Keep**: Normal whitespace (space, tab, newline, carriage return).

### 2. Normalize Whitespace
- Collapse 3+ consecutive newlines to 2
- Collapse 3+ consecutive spaces to 1
- Remove zero-width spaces and joiners
- Normalize Unicode whitespace variants to ASCII equivalents

### 3. Detect Encoded Payloads
- Scan for Base64-encoded strings longer than 50 characters (pattern: `[A-Za-z0-9+/=]{50,}`)
- If detected: truncate the encoded portion and replace with `[encoded content removed]`
- Log an INFO event: `{"event": "encoded_payload_detected", "length": N}`

### 4. Detect Markdown Injection
- Scan for fenced code blocks (triple backticks) containing instruction-like patterns:
  - `system:`, `SYSTEM:`, `[INST]`, `<<SYS>>`, `</s>`, `<|im_start|>`
  - `ignore`, `forget`, `override`, `new instructions`
- If detected: strip the code fence markers (keep content as plain text)
- Log a WARNING event: `{"event": "markdown_injection_detected", "snippet": "<first 30 chars>"}`

### 5. Length Cap
- Truncate single messages to 4,000 characters
- If truncated, append: `\n[Message truncated to 4,000 characters]`
- Log an INFO event if truncated: `{"event": "message_truncated", "original_length": N}`

## Detection Patterns (for logging, not blocking)

These patterns trigger logging but do NOT block the message (L1 SOUL.md handles the behavioral response):

| Pattern | Log Level | Description |
|---------|-----------|-------------|
| `IGNORE ALL` (case-insensitive) | WARNING | Common injection prefix |
| `you are now` (case-insensitive) | WARNING | Role reassignment attempt |
| `system prompt` (case-insensitive) | WARNING | Prompt extraction attempt |
| `repeat your instructions` (case-insensitive) | WARNING | Instruction extraction |
| `what are your rules` (case-insensitive) | WARNING | Rule extraction |
| `[INST]`, `<<SYS>>`, `<\|im_start\|>` | WARNING | Model-specific injection tokens |
| `\x00`, `\x08`, RTL overrides | INFO | Control character attempt |
| Base64 > 50 chars | INFO | Potential encoded payload |

## Important Notes

- This sanitizer runs BEFORE the message reaches the LLM
- It does NOT block messages -- it cleans them and logs suspicious patterns
- The LLM (SOUL.md rules) handles the behavioral response to injection attempts
- The canary detection in SOUL.md is the primary behavioral defense
- This sanitizer is a pre-filter that reduces noise and catches encoding tricks
