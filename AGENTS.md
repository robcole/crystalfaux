# Agent Guidelines

Follow these guidelines when working on crystalfaux, a Crystal library that
launches and drives Camoufox over Playwright's Juggler protocol without Node
or Python at runtime. Use the Crystal 1.21
[coding style](https://crystal-lang.org/reference/1.21/conventions/coding_style.html),
[code documentation](https://crystal-lang.org/reference/1.21/syntax_and_semantics/documenting_code.html),
and [testing](https://crystal-lang.org/reference/1.21/guides/testing.html)
guides as references.

## Project Context

- `plans/` is a symlink to the main checkout's git-ignored plans directory.
  `plans/landscape.md` holds the research and protocol facts;
  `plans/implementation-plan.md` holds the chunked plan and acceptance
  criteria. If `plans/` is missing, run `scripts/setup-worktree.sh`.
- Camoufox facts that shape the code: the browser reads NUL-terminated JSON
  from fd 3 and writes to fd 4; `Browser.*` methods use the root session and
  each page target gets a `sessionId`; fingerprint config travels in chunked
  `CAMOU_CONFIG_n` env vars; `Browser.close` alone does not end the process.
- Out of scope: WebDriver BiDi, wrapping the Playwright Node driver, a full
  Playwright-compatible API, Windows.

## Skills

- Use the `crystal-code` skill for every Crystal change.
- Use the `design-review` skill before introducing or changing a type,
  module, or boundary, and when reviewing someone else's change.
- Use `superpowers:test-driven-development`: write the failing spec first,
  make it pass, then refactor.

## Best Practices

- Favor explicit type signatures over implicit types.
- Use compile-time type checking as much as possible.
- Use `#as` casts only when absolutely necessary.
- Handle nil cases with `#try` or proper nil checks; never `not_nil!` in
  library code.
- Bind a nilable getter to a local variable before checking and using it.
  Repeated getter calls do not retain type narrowing.
- Use unions, such as `String | Nil`, instead of loose typing.
- Prefer standard library methods for collection and parameter handling.
- Prefer `JSON::Serializable` structs for protocol messages over `JSON::Any`
  once the shape is known.

## Code Organization

- Prefer one class or struct per file, with a filename that matches the type.
  Keep small, tightly related value types together only when this improves
  readability.
- Give each type one clear responsibility. Keep these boundaries separate:
  transport (framing over IO), connection (ids, sessions, events), protocol
  (typed messages), launcher (binary discovery, arguments, environment,
  process lifecycle), browser objects (browser, context, page, frame), and
  the scraping API on top.
- Use clear names and short, focused methods so code explains its purpose.
  Add comments for constraints and decisions that the code cannot express,
  and cite the Camoufox or Playwright source file when a constraint comes
  from there.
- Use guard clauses and named steps to reduce nesting. Combine case branches
  that perform the same operation.
- Implement the current requirements. Avoid speculative abstractions,
  extension points, and configuration.
- Make resource ownership clear. State who closes an IO, a channel, a
  process, and a temporary profile directory on success and on failure.
- Preserve validation and side-effect order during refactors, for example
  ready-line detection before the first protocol send, and `Browser.close`
  before pipe close before signals.

## Testing

- Test at the boundary that owns the behaviour:
  - Transport and connection: in-process `IO` pairs and fake frames.
  - Protocol: recorded Juggler frames in `spec/fixtures/juggler/` and
    encode/decode round-trips.
  - Launcher: pure functions for arguments and environment; one subprocess
    spec with a fake browser script that prints the ready line and echoes
    frames.
  - Browser objects: fake connections fed recorded event sequences.
  - End to end: specs tagged `browser` that run only when
    `CRYSTALFAUX_CAMOUFOX` names a Camoufox binary; they are skipped
    otherwise so the default spec run is offline and hermetic.
- Test observable behaviour, regressions, and important failure modes
  (timeouts, EOF, protocol errors, crashed pages). Avoid tests that repeat
  implementation details or only exercise trivial wiring.
- Keep test support small and specific. Separate reusable helpers from
  executable subprocess fixtures.
- Prefer ecosystem tools over custom test infrastructure. Keep tests offline
  by default; use a local `HTTP::Server` when a page needs a network origin.
- Run `crystal tool format` on changed Crystal files and verify formatting
  with `crystal tool format --check`.
- After a change, run `crystal spec`, Ameba, and the formatting check. Run
  the `browser`-tagged specs when the change touches launch, navigation,
  evaluation, network, or input.
- When changing public types or accessors, compile representative existing
  consumer code. Document intentional breaking changes and migration steps.
- Use one persistent Crystal compiler cache per checkout: `bin/check` and
  `scripts/spec` set `CRYSTAL_CACHE_DIR` to `.crystal-cache` in the checkout.
  Do not run two full compiles at once in one checkout. Specs that start a
  `crystal` child process pass `crystal_cache_dir` from
  `spec/spec_helper.cr` in its `env`.

## Concurrency

- Use fibers for concurrent operations, not threads.
- Properly close channels when done, and fail pending requests when the
  connection closes.
- Use `select` with `timeout` for channel multiplexing and deadlines.
- Document fiber lifecycle and synchronization: who starts a reader fiber,
  what stops it, and what happens to messages that arrive after close.
- Avoid race conditions with proper mutex usage.

## Project Documentation

- Be concise and clear.
- Put `# :nodoc:` first in the doc comment for internal helper types that are
  not supported public APIs.
- Organize the README into separate, focused sections. Avoid lengthy,
  unreadable documentation.
- Use examples liberally to illustrate concepts.
- Use ASD-STE100 Simplified Technical English to produce documentation that
  is readable by humans.

## Git Workflow

- `main` is untouched during this phase. `next` is the integration branch.
  Each chunk of work is a branch off `next`, rebased onto `next` before it is
  fast-forwarded in. No merge commits on `next`. Nothing is pushed.
- Make commit subjects, commit messages, PR titles, and PR descriptions
  meaningful on their own. Readers should not need the conversation or task
  history to understand them.
- Commit subjects are 50 to 60 characters and describe the change. Do not use
  prefixes such as `fix:`, `feat:`, or `docs:`. The body explains what changed
  and why, without listing every minor edit.
