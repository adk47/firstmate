# Shared by the validate-config-matrix-*.bats suites that exercise checks other
# than #9 (model-ref catalog, MUS-8564). Their minimal fixtures carry agent model
# refs but no models.providers block; declare every agent model/imageModel ref
# found in "$PROFILE" so check #9 is satisfied and the case still tests only the
# check it was written for (reasoning:true keeps check #3 quiet for claude ids; baseUrl marks an HTTP provider, so a provider-key
# imageModel prefix passes check #9). validate-config-matrix-model-refs.bats does NOT use
# this: it mutates copies of the real profiles and proves check #9 itself.
declare_model_catalog() {
  jq '
    . as $r
    | [ $r.agents | .. | objects | (.model?, .imageModel?) | objects
        | (.primary?, .fallbacks[]?) | strings | select(index("/") != null) ]
    | unique
    | map({p: .[:index("/")], id: .[index("/") + 1:]})
    | group_by(.p)
    | map({key: .[0].p, value: {baseUrl: "https://fixture.invalid/v1", models: map({id, reasoning: true})}})
    | from_entries as $c
    | $r | .models.providers = ($c + (.models.providers // {}))
  ' "$PROFILE" > "$PROFILE.catalog"
  mv "$PROFILE.catalog" "$PROFILE"
}
