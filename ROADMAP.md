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
- Current verification baseline: `swift test` with 116 passing tests

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
- brace expansion now supports comma form, numeric and alpha sequences, step values, nesting, and preamble/postscript composition for literal word segments
- the gzip family now exists in the Swift port: `gzip`, `gunzip`, and `zcat`
- the indexed-array subset now works in the Swift port: `arr=(...)`, `arr[n]=...`, `${arr[n]}`, `${arr[@]}`, `${arr[*]}`, `${#arr[@]}`, `unset arr[n]`, `local arr=(...)`, and `declare -a arr=(...)`
- a larger shell-builtin parity block now exists in the Swift port: `mapfile`/`readarray`, `pushd`, `popd`, `dirs`, `builtin`, `hash`, and sandbox-friendly `exec`
- a native `sqlite3` command now exists in the Swift port for `:memory:`, stdin-driven SQL, file-backed databases, and `-json` output
- a tar subset now exists in the Swift port: create/list/extract, `-f`, `-C`, `--strip-components`, and gzip-compressed `.tar.gz` archives
- readonly variables and `shopt` alias toggling now exist in the Swift port
- the first associative-array slice now exists in the Swift port: `declare -A`, keyed assignment, keyed expansion, length, and keyed unset
- basic `curl` and `html-to-markdown` commands now exist in the Swift port with local-only verification coverage
- a larger native `jq` slice now exists in the Swift port: identity, recursive descent, key access, nested access, quoted and bracketed string-key access, keyword-named field access, array indexing/iteration, slices, simple pipes, comma output, compact/raw modes, array constructors, shorthand object construction, `map`, `select`, `has`, `contains`, `any`, `all`, simple conditionals, variable binding, object construction, path helpers like `getpath` and `setpath`, generators like `range` and `limit`, numeric filtering via `numbers`, string helpers like `split`, `join`, `test`, `startswith`, `endswith`, `ltrimstr`, `rtrimstr`, `ascii_downcase`, `ascii_upcase`, `sub`, `gsub`, `index`, and `indices`, comparison and logical operators including `==`, `!=`, `<`, `>`, `<=`, `>=`, `and`, `or`, `not`, and `//`, type conversion via `tostring` and `tonumber`, and builtin functions like `length`, `keys`, `add`, `type`, `first`, `last`, `reverse`, `sort`, `unique`, `min`, `max`, `flatten`, `transpose`, `pow`, `atan2`, `floor`, `ceil`, `round`, `sqrt`, and `abs`
- a first `yq` slice now exists in the Swift port: YAML field access, nested access, array traversal, select-on-array, JSON output modes, JSON input mode, stdin input, null-input object construction, document slurp mode, join-output and exit-status modes, custom JSON indentation, format-string operators like `@base64`, `@base64d`, `@uri`, `@csv`, `@tsv`, `@json`, `@html`, `@sh`, and `@text`, and shared jq-backed advanced filters in JSON mode

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
- deepen shell builtin parity beyond the new baseline (`readonly`/`shopt` edge cases, fuller `exec` behavior, and directory-stack corner cases)
- expand parity fixtures around the newly completed runtime behavior so regressions do not slip back in

### 3. Keep The Docs Honest

- Update `README.md` only when behavior is implemented and tested
- Keep this roadmap aligned with the active milestone instead of appending new parallel phases

## Next: Remaining High-Value Command Gaps

The next command wave is the part of upstream parity that still materially changes capability.

- `xan`

Rationale:

- These are the biggest remaining upstream command families still absent from the Swift port or only partially implemented
- They also represent the point where parity work starts colliding with larger dependency and security decisions

jq follow-on still remains:
- try/catch, broader functions, and broader operator coverage
- broader parser/evaluator compatibility

yq follow-on still remains:
- richer YAML parsing features and multi-document/slurp behavior
- XML/INI/CSV/TOML conversion modes
- broader jq-backed filter parity on non-JSON input

Tar follow-on still remains:
- verbose tar listing/output parity
- security checks and path sanitization hardening
- binary-heavy/archive-metadata edge cases

## Later: Data Model And Shell Completeness

- richer associative-array semantics remain one of the largest shell-core gaps still open in the Swift runtime
- sparse-array/bash edge cases
- higher-fidelity quoted `${arr[@]}` behavior
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
