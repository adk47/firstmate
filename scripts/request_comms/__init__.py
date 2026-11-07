"""Automatic request status updates: one ledger, one hourly driver, one copy policy.

Modules
  store.py     request_comm_state, the append-only sha256-chained ledger (the (request, state) unit)
  sources.py   the owning tables, normalised into (received | verifying | need_you | decided)
  guard.py     the messaging ban set (fraud lens holds, the decider's deny list), fail-closed
  identity.py  email -> the Intercom contact that IS this account, by the r5 rules
  routing.py   due? which channel? why not — plus the 48 h floor and the 24 h breach
  channels.py  bell / Intercom / send-gateway, each with the confirmation its provider answers
  lines.py     policies/request-status-lines.json: the fixed copy and its rules
  report.py    time-to-first-message, the gap between messages, breaches — measured
  driver.py    the tick
"""
