# just-bash-swift Roadmap

This roadmap is for execution order, not feature wish-listing. The goal is to keep work on one active milestone at a time so runtime correctness, parity work, and future embedding work do not get mixed together.

## Operating Rules

- Keep the project library-first until the runtime contract settles.
- One active milestone at a time.
- New runtime behavior must land with regression tests.
- New commands must land with command tests plus at least one end-to-end parity or fixture case.
- `README.md` describes verified current behavior only. Future work belongs here, not there.

## Verified Baseline

- Pure Swift package with four targets: `JustBashFS`, `JustBashCommands`, `JustBashCore`, `JustBash`
- In-process execution only: parser -> AST -> interpreter -> virtual commands/filesystem
- One filesystem backend today: in-memory `VirtualFileSystem`
- Filesystem persists across `exec()` calls; shell state resets per call
- Current verification baseline: `swift test` with 71 passing tests

## Recently Completed

- `> $path` and related output redirections now expand the target word before writing
- Quoted heredoc delimiters now suppress variable expansion
- `set -o pipefail` now affects pipeline exit status
- `maxOutputLength` is now enforced for visible shell output
- `set -C` / `noclobber` now prevents overwriting existing files via `>`
- `+=` assignments now survive parsing into runtime evaluation
- `|&` now pipes stderr into the next command instead of only parsing the token
- `set -u` now fails on unset variable expansion
- unquoted expansion now performs `IFS` field splitting
- glob character classes like `[ab]` and `[a-z]` now match in the virtual filesystem
- basic command-position alias expansion is now active
- `set -x` now emits xtrace lines to stderr
- a large utility-command block now exists in the Swift port: `base64`, hashes, `expr`, `whoami`, `rmdir`, `tree`, `file`, `strings`, `split`, `join`, `tac`, `od`, `egrep`/`fgrep`/`rg`, `clear`, `help`, `history`, `bash`/`sh`, `time`, and `timeout`

## Now: Parity Harness And Remaining Correctness Work

This is the only active milestone.

### 1. Expand The Parity Harness

- Grow `Tests/JustBashParityTests/` beyond the current curated cases and MVP fixture file
- Add small fixture categories for:
  - redirections
  - substitution
  - globbing
  - alias behavior
  - parse errors
- Keep fixture imports incremental; do not bulk-port upstream fixtures

### 2. Finish The Remaining High-Confidence Runtime Fixes

- decide whether alias expansion needs to grow beyond basic command-position replacement semantics
- tighten `nounset` / `xtrace` edge-case parity against bash-specific corners
- expand parity fixtures around the newly completed runtime behavior so regressions do not slip back in

### 3. Keep The Docs Honest

- Update `README.md` only when behavior is implemented and tested
- Keep this roadmap aligned with the active milestone instead of appending new parallel phases

## Next: Remaining High-Value Command Gaps

The next command wave is the part of upstream parity that still materially changes capability.

- `jq`
- `yq`
- `sqlite3`
- `xan`
- `gzip` / `gunzip` / `zcat`
- `tar`
- `curl` / `html-to-markdown`

Rationale:

- These are the biggest remaining upstream command families still absent from the Swift port
- They also represent the point where parity work starts colliding with larger dependency and security decisions

## Later: Data Model And Shell Completeness

- brace expansion
- indexed arrays
- `${arr[n]}`, `${arr[@]}`, `${arr[*]}`
- array length and indices
- highest-value missing special variables used by real scripts
- deeper alias/bash-parity edge cases once fixture coverage expands

## Later: Filesystem Abstraction For Embedding

- define a filesystem protocol
- make `VirtualFileSystem` conform to it
- allow custom filesystem injection through the public API

This stays later because it is an embedding concern, not a blocker for the current iOS sandbox goal.

## Explicitly Deferred

These are not current priorities and should not be pulled into unrelated milestones:

- embedded JS/Python runtimes
- overlay or mountable filesystem backends
- example iOS host app or demo app
- upstream-style sandbox compatibility layers

## Definition Of Done For A Milestone

- targeted regression tests added first or alongside the fix
- full `swift test` passes
- roadmap active milestone updated if scope changed
- `README.md` updated only if verified behavior changed
