"use strict";
// Resolve PROMPTGUARD_MODE for scripts/intercom-webhook.js.
//
// Split out of the webhook so the rule is testable without booting the intake server (that file
// refuses to start without the Intercom credentials). The rule itself is the safety decision:
//
//   unset / empty  -> "shadow"  (the documented default during the measurement window)
//   "shadow"       -> shadow
//   "enforce"      -> enforce   (case-insensitive, surrounding whitespace ignored)
//   anything else  -> enforce   + a warning naming the raw value
//
// Why an unrecognised value ENFORCES rather than falling back to shadow: the operator clearly
// meant to configure this control, and silently weakening it is the one direction it must never
// fail in. Why it does not exit: a crash loop on the live intake lane would be a larger blast
// radius than the mode being guarded, and the warning makes the typo loud instead.
const VALID_MODES = ["shadow", "enforce"];

function resolvePromptguardMode(raw) {
  const requested = raw === undefined || raw === null || String(raw).trim() === ""
    ? "shadow"
    : String(raw).trim().toLowerCase();
  if (!VALID_MODES.includes(requested)) {
    return {
      mode: "enforce",
      enforcing: true,
      valid: false,
      warning:
        `PROMPTGUARD_MODE=${JSON.stringify(raw)} is not one of ${VALID_MODES.join("|")} -- enforcing ` +
        `rather than silently falling back to shadow. Fix the unit environment.`,
    };
  }
  return { mode: requested, enforcing: requested === "enforce", valid: true, warning: null };
}

module.exports = { resolvePromptguardMode, VALID_MODES };
