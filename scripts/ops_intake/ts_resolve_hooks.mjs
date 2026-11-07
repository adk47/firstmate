/**
 * Resolve `./x.js` to `./x.ts` when the importing module is a `.ts` file.
 *
 * The plugin sources import each other with the COMPILED specifier (`./answer-bank.js`) because
 * tsc emits ESM with explicit extensions. Node's `--experimental-strip-types` runs the `.ts`
 * source but does NOT rewrite specifiers, so importing `caroline-output-guard.ts` directly fails
 * with "Cannot find module .../answer-bank.js".
 *
 * WHY THIS EXISTS AT ALL: the Ops summarize/resolve surface (scripts/ops_intake) must run the REAL
 * output guard on every customer reply it sends, not a second implementation of it. A Python port
 * of the guard would be a second source of truth for the exact strings that may reach a customer —
 * the class of drift `scripts/check-caroline-answer-bank.sh` already exists to prevent. So the
 * Python side shells out to this loader and imports the plugin's own module. Nothing here changes
 * behaviour: it only tells Node where the (already-correct) TypeScript file is.
 *
 * Uses `module.registerHooks` (sync, in-thread; Node >= 22.15), so it needs no separate worker and
 * cannot deadlock against the module loader. Verified on the repo's pinned Node 22.
 */
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";

registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context);
    } catch (err) {
      const parent = context?.parentURL;
      if (specifier.endsWith(".js") && typeof parent === "string" && parent.endsWith(".ts")) {
        const candidate = new URL(`${specifier.slice(0, -3)}.ts`, parent);
        if (existsSync(fileURLToPath(candidate))) {
          return { url: candidate.href, shortCircuit: true };
        }
      }
      throw err;
    }
  },
});
