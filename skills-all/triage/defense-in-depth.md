# Defense in depth — make the bug structurally impossible

When you fix a bug caused by bad data, validating in one place feels like enough. But a
single check is bypassed by a different code path, a refactor, or a mock. Validate at **every
layer** the data passes through, so the bug can't come back through a side door.

Single validation says "we fixed the bug." Layered validation says "we made the bug
impossible."

## The four layers

**1. Entry-point validation** — reject obviously-invalid input at the boundary (API handler,
public function):

```js
function createProject(name, workingDir) {
  if (!workingDir || workingDir.trim() === '') {
    throw new Error('workingDir cannot be empty');
  }
  if (!fs.existsSync(workingDir)) {
    throw new Error(`workingDir does not exist: ${workingDir}`);
  }
  // ...
}
```

**2. Business-logic validation** — enforce what must be true for *this* operation, deeper in:

```js
function initWorkspace(projectDir, sessionId) {
  if (!projectDir) throw new Error('projectDir required to init workspace');
  // ...
}
```

**3. Environment guards** — refuse dangerous operations in contexts where they'd do harm:

```js
async function gitInit(dir) {
  if (process.env.NODE_ENV === 'test') {
    const resolved = path.resolve(dir);
    if (!resolved.startsWith(path.resolve(os.tmpdir()))) {
      throw new Error(`refusing git init outside tmp during tests: ${dir}`);
    }
  }
  // ...
}
```

**4. Debug instrumentation** — when the other layers somehow fail, capture the context to
diagnose it (see `root-cause-tracing.md`):

```js
logger.debug('about to git init', { dir, cwd: process.cwd(), stack: new Error().stack });
```

## Why each layer earns its place

Different layers catch different failures: entry validation stops most bad input;
business-logic catches edge cases the boundary let through; environment guards stop
context-specific damage (a mock or test harness bypassing the upper checks); debug logging is
your forensic trail when something still slips through. In real incidents each layer catches a
bug the others missed.

## Don't over-apply it

This is for a bug that *already bit you* and would be expensive to hit again — not a reason to
wrap every function in four checks. Match the codebase's existing validation style; one
well-placed guard at the true source often beats four scattered ones. Layer the path the bad
data actually travelled, and no more.
