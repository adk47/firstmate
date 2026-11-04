# Shared by the validate-config-matrix-*.bats suites that exercise checks other
# than #9 (model-ref catalog, MUS-8564). Their minimal fixtures carry agent model
# refs but no models.providers block; declare every agent model/imageModel ref
# found in "$PROFILE" so check #9 is satisfied and the case still tests only the
# check it was written for (reasoning:true keeps check #3 quiet for claude ids; baseUrl marks an HTTP provider, so a provider-key
# imageModel prefix passes check #9). validate-config-matrix-model-refs.bats does NOT use
# this: it mutates copies of the real profiles and proves check #9 itself.
#
# An openrouter deepseek/z-ai ref also gets the one ZDR routing block, because
# check #10 (scripts/check-zdr-routing.py) refuses a catalog entry for those
# families that has no compat.openRouterRouting. The block is spelled out here
# rather than imported so a fixture can never silently inherit a weakened one.
declare_model_catalog() {
  jq '
    def zdr: {zdr: true, data_collection: "deny", sort: "price",
              quantizations: ["fp8", "bf16", "fp16"],
              max_price: {prompt: 0.30, completion: 1.20},
              ignore: ["Google"]};
    . as $r
    | [ $r.agents | .. | objects | (.model?, .imageModel?) | objects
        | (.primary?, .fallbacks[]?) | strings | select(index("/") != null) ]
    | unique
    | map({p: .[:index("/")], id: .[index("/") + 1:]})
    | group_by(.p)
    | map(.[0].p as $p | {key: $p, value: {baseUrl: "https://fixture.invalid/v1",
        models: map({id, reasoning: true}
          + (if ($p == "openrouter") and (.id | test("^(deepseek|z-ai|zai|qwen|thudm)/"))
             then {compat: {openRouterRouting: zdr}} else {} end))}})
    | from_entries as $c
    | $r | .models.providers = ($c + (.models.providers // {}))
  ' "$PROFILE" > "$PROFILE.catalog"
  mv "$PROFILE.catalog" "$PROFILE"
}
