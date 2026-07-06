# Root-cause tracing — find the source, not the symptom

Bugs surface deep in the call stack, far from where they start. Your instinct is to fix
where the error appears. That treats the symptom and leaves the real bug to resurface
somewhere else. Instead, trace the bad value **backward** to where it first appears — that's
where the fix belongs.

## The process

1. **Observe the symptom.** Where does the error actually surface? (exception, wrong value,
   failed assertion)
2. **Find the immediate cause.** Which line directly produced it?
3. **Ask: what called this with the bad input?** Look one frame up.
4. **Keep tracing up.** At each level, inspect the value being passed in: is it already wrong
   here, or did this frame corrupt it?
5. **Find the original trigger** — the first place the bad value came into being. That's the
   root cause.

> Never stop at where the error appears. Trace back to the original trigger.

## When manual tracing runs out

Add a one-shot stack dump right before the dangerous operation, run once, and read where the
bad value actually comes from.

In a Node / Express service:

```js
function loadConfig(key) {
  if (!key) {
    console.error('DEBUG loadConfig empty key', {
      key,
      stack: new Error().stack,
    });
  }
  // ...
}
```

In a Python pipeline stage:

```python
import sys, traceback
if not partition_key:
    print(f"DEBUG empty partition_key for task={task_id}", file=sys.stderr)
    traceback.print_stack()
```

Use stderr / `console.error`, not a logger that might be filtered out in the failing
environment. Remove the instrumentation once you've found the source — or, if it's genuinely
useful, fold it into a proper debug-level log as part of the fix.

## Worked example (shape, not literal)

```
Symptom:    a report endpoint returns rows for the wrong account
Trace:      the query is keyed on accountId
        ←   the writer stored rows under accountId = ""   (empty)
        ←   the importer passed accountId from a record not yet normalized
        ←   normalization ran AFTER the enqueue, not before
Root cause: ordering — enqueue happened before normalization
Fix:        normalize before enqueue (the source), NOT "skip empty accountId"
            in the report query (the symptom)
```

The symptom-level "fix" (filter empty `accountId` at read time) would have hidden the bug and
left every other consumer of those rows broken. The source fix corrects all of them at once.
