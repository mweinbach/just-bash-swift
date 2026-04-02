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
- Current verification baseline: `swift test` with 215 passing tests

## Recently Completed

- `ShellInterpreter` refactored: builtins (830 lines) and arithmetic evaluator (256 lines) extracted into extension files, reducing the main Interpreter.swift from 2,285 to 1,211 lines
- `JustBashCommands` refactored from a single 5,481-line `Commands.swift` into 20 focused files (one per command or command group) with no behavior changes
- fixture-driven parity test suites now cover redirections (14 cases), substitution (22 cases), globbing (7 cases), alias behavior (6 cases), and parse errors (5 cases)
- `${var%%pattern}` greedy suffix removal now correctly finds the longest matching suffix instead of the shortest
- `VirtualFileSystem` init now auto-creates parent directories when seeding initial files, fixing glob expansion over pre-populated subdirectories
- brace expansion now limited to 10,000 elements to prevent memory explosion
- jq now supports `try`/`try-catch`, `empty`, `env`, `del()`, `path()`, `paths`, `leaf_paths`, `explode`/`implode`, `tojson`/`fromjson`, `recurse`/`recurse(f)`, and type filters (`strings`, `booleans`, `nulls`, `objects`, `arrays`, `iterables`, `scalars`, `values`)
- yq now supports XML output mode (`-o xml`)
- dynamic special variables now supported: `$RANDOM`, `$BASH_VERSION`, `$HOSTNAME`, `$SECONDS`, `$LINENO`
- `select` loop now executes with auto-selection of first option in sandbox mode
- `trap` builtin now registers, lists, and removes signal handlers (stored in session, cannot fire in sandbox)
- `declare -p` now prints variable declarations
- `printf -v` now stores output in a variable
- `read -a` now reads fields into an indexed array
- process substitution `<(cmd)` and `>(cmd)` now works by writing to VFS temp files
- extended glob patterns (`?(pat)`, `*(pat)`, `+(pat)`, `@(pat)`, `!(pat)`) supported via `shopt -s extglob`
- `declare -n` nameref variables now supported (transparent read/write through to target)
- variable transformation operators `${var@Q}`, `${var@E}`, `${var@A}` now supported
- `${!prefix*}` and `${!prefix@}` variable name expansion now supported
- advanced fd redirects (`exec 3>file` etc.) accepted without error
- `bc` calculator command with arithmetic, `scale`, `sqrt()`
- `mktemp` command for temp files and directories
- `wait` builtin (no-op in sandbox)
- `sed` expanded: address ranges, line addresses, regex addresses, `p`/`a`/`i`/`c`/`y`/`q` commands, `-n` suppress mode
- `awk` expanded: BEGIN/END blocks, multiple rules, NR/NF/FS/OFS/ORS, field arithmetic, conditionals, printf, variable accumulation
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
- a larger native `jq` slice now exists in the Swift port: identity, recursive descent, key access, nested access, quoted and bracketed string-key access, keyword-named field access, array indexing/iteration, slices, simple pipes, comma output, compact/raw modes, array constructors, shorthand object construction, `map`, `select`, `has`, `contains`, `any`, `all`, simple conditionals, variable binding, object construction, path helpers like `getpath`, `setpath`, `path()`, `paths`, `leaf_paths`, generators like `range` and `limit`, type filters (`numbers`, `strings`, `booleans`, `nulls`, `objects`, `arrays`, `iterables`, `scalars`, `values`), string helpers like `split`, `join`, `test`, `startswith`, `endswith`, `ltrimstr`, `rtrimstr`, `ascii_downcase`, `ascii_upcase`, `sub`, `gsub`, `index`, `indices`, `explode`, and `implode`, comparison and logical operators including `==`, `!=`, `<`, `>`, `<=`, `>=`, `and`, `or`, `not`, and `//`, type conversion via `tostring`, `tonumber`, `tojson`, and `fromjson`, error handling via `try` and `try-catch`, deletion via `del()`, recursion via `recurse`/`recurse(f)`, and builtin functions like `length`, `keys`, `add`, `type`, `first`, `last`, `reverse`, `sort`, `unique`, `min`, `max`, `flatten`, `transpose`, `pow`, `atan2`, `floor`, `ceil`, `round`, `sqrt`, `abs`, `empty`, and `env`
- a first `yq` slice now exists in the Swift port: YAML, JSON, CSV, INI, TOML, and XML output modes, stdin input, null-input object construction, extension-based input auto-detection for JSON/CSV/TSV/INI/TOML, document slurp mode, join-output and exit-status modes, custom JSON indentation, navigation operators like `parent`, `parents`, and `root` on simple path pipelines, format-string operators like `@base64`, `@base64d`, `@uri`, `@csv`, `@tsv`, `@json`, `@html`, `@sh`, and `@text`, custom CSV delimiters, dotted-table TOML parsing, and shared jq-backed advanced filters in JSON mode
- fixture categories now include: redirections (14), substitution (23), globbing (7), alias (6), parse_errors (6), shell_builtins (22), advanced_features (21) — 99 total fixture-driven test cases
- alias expansion decision: documented as intentionally limited to command-position only (see README.md)
- `xan` CSV processing command implemented with RFC 4180 compliant parser, TSV support, column selection by index/name, expression filtering, sorting, frequency tables, and statistics — 16 tests added

## Now: COMPLETED — Parity Harness And Remaining Correctness Work

~~This was the active milestone. It is now complete.~~

### Completed Work

**1. Expanded The Parity Harness**
- ✅ Grew `Tests/JustBashParityTests/` with 2 new fixture categories
- ✅ Added `shell_builtins.json` with 22 edge-case tests (readonly, shopt, exec, directory-stack)
- ✅ Added `advanced_features.json` with 21 regression tests (process substitution, nameref, transformations, prefix expansion)
- Total: 99 fixture cases across 7 JSON files plus 3 MVP cases

**2. Finished The Remaining High-Confidence Runtime Fixes**
- ✅ **Alias expansion**: Decision made to document intentional limitations (command-position only, no self-referential, no trailing-blank)
- ✅ **Shell builtin parity**: Edge-case fixtures added for readonly, shopt, exec, pushd/popd/dirs
- ✅ **Parity fixtures**: Expanded coverage for newly completed runtime behavior

**3. Kept The Docs Honest**
- ✅ Updated `README.md` with:
  - `$HOSTNAME`, `$SECONDS`, `$LINENO` added to special variables
  - New "Alias Expansion" section documenting intentional limitations
  - Test count updated to 215

## Next: Remaining High-Value Command Gaps (COMPLETED)

~~The next command wave is the part of upstream parity that still materially changes capability.~~

- ✅ `xan` — Phase 1 MVP implemented: view, count, headers, select, head, tail, filter, sort, freq, stats

**Implementation highlights:**
- RFC 4180 compliant CSV parser with proper quote handling
- TSV support via `-t` flag
- Column selection by index (1-based) or header name
- Expression-based filtering (`age > 30`, `name == 'John'`)
- Numeric and string sorting with auto-detection
- Frequency tables and descriptive statistics
- 16 new tests covering core functionality

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
