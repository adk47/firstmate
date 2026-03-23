# Slack Diagram Sharing (ASCII Only)

This guide covers how to share diagrams in Slack using ASCII only (no rendering, no Mermaid).

Kroki-based rendering has been intentionally disabled (diagram quality + security posture). The supported behavior is: post an ASCII diagram directly in Slack.

## Security Policy (Required)

- Never send Muso internal/proprietary diagrams to public third-party diagram renderers/editors (e.g. kroki.io, web-based Mermaid editors).
- Do not generate “paste this into a website” links for diagrams.
- Prefer in-message code blocks (ASCII only).

## ASCII Diagram

```text
Source --> Queue --> Worker --> DB
```

## Style Tips

- Keep diagrams small (5–7 nodes); split if needed.
- Prefer left-to-right or top-to-bottom flow.
- Use stable names (service/repo names) and avoid deep detail in one diagram.
