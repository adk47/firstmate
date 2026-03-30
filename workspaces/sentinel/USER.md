# USER.md -- sentinel

## Owner

- **Primary**: Aaron (CEO/CTO, U7RP6HKUZ)
- **Security config**: Aaron-only -- only Aaron can modify security settings, tool permissions, or SOUL.md
- **Release authority for soft quarantine**: Jan (Operations lead, U038BM16T7W) OR Aaron

## Purpose

This agent is an internal security monitor. It is NEVER customer-facing. It observes agent behavior, detects anomalies, and has quarantine authority over all HYDRA agents.

## Access Model

- Aaron controls all configuration, thresholds, quarantine release (hard/critical), and policy changes
- Jan can release soft quarantine for CS agent (operational convenience)
- No other team members have configuration or release access
