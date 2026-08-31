# Update assessment: JustBash, SwiftCodexCore, and Cowork

Assessed August 31, 2026, using Xcode 27.0 beta (27A5237l) and Apple Swift 6.4.
This is an assessment, not an implementation. Application and library sources
were left unchanged. Test/build evidence is under
`/tmp/cowork-update-audit.OUrXjI`.

## Bottom line

This is a coordinated compatibility update, not three dependency bumps.
JustBash and SwiftCodexCore already match their live GitHub `main` branches.
Cowork's local package resolution already selects both current library commits,
but its application code has not caught up with SwiftCodexCore's API.

The consumption order is **JustBash → SwiftCodexCore → Cowork**. Cowork also
directly consumes JustBashJavaScript. JustBash's optional phone example consumes
SwiftCodexCore, so include that example in integration validation too.

## Verified baseline

| Project | Checkout | Result |
| --- | --- | --- |
| just-bash-swift | `a750ab6`, May 4 | `swift test` exits 1: 362 test cases pass, 3 fail, 36 skip. All failing cases concern primary-runtime skill helpers. |
| SwiftCodexCore | `6652728`, July 17 | Isolated macOS code-mode helper builds; 117 test cases pass with the helper enabled. |
| Cowork | `4aea71d`, June 7 | Clean unsigned iOS Simulator build fails on a nonexhaustive reasoning-effort switch. |

All three source checkouts were initially clean on `main`. GitHub heads for
JustBash and SwiftCodexCore were verified. Cowork's remote-head check failed
authentication; its remote synchronization is **unverified**.

Cowork's local resolution selects JustBash `a750ab6`, SwiftCodexCore `6652728`,
GrabKit `55d115c`, and LucideIcons `1.37.0`. GrabKit matches its remote `main`,
and `1.37.0` is the latest available stable 1.x LucideIcons tag checked.
Cowork deliberately ignores `Package.resolved`; those pins are local state,
not a reproducible committed app dependency set. Both first-party libraries
are referenced by branch, and neither first-party remote exposed release tags.

## 1. Cowork: restore source compatibility first

### Confirmed build blocker

[SettingsView.swift](/Users/mweinbach/Projects/Cowork/Cowork/SettingsView.swift:123)
does not handle `ReasoningEffort.none`, `.max`, or `.ultra`. The clean Xcode
build reports all three missing cases.

Source inspection also found missing `AgentEvent.codeModeNotification` and
`.modelCatalogChanged` cases in:

- [CoworkTranscriptReducer](/Users/mweinbach/Projects/Cowork/Cowork/CoworkChatStore.swift:251).
- [CoworkCodexLogFormatter](/Users/mweinbach/Projects/Cowork/Cowork/CoworkCodexController.swift:566).

Handle these intentionally: show code-mode notifications/progress and refresh
catalog-driven state. A blanket default would hide useful new behavior.
The build stopped at the reasoning switch; the two event-switch issues are
source-confirmed follow-on work, not separately observed compiler diagnostics.

### Connect the newer core features

- Replace the fixed GPT-5.3/5.4/5.5 picker in
  [CoworkSettingsStore.swift](/Users/mweinbach/Projects/Cowork/Cowork/CoworkSettingsStore.swift:21)
  with `OpenAIModelsManager`, including cached/offline fallback.
- Pass the same manager to `OpenAIResponsesClient`; currently
  [makeModelProvider](/Users/mweinbach/Projects/Cowork/Cowork/CoworkCodexController.swift:178)
  supplies only auth and endpoint options.
- Apply selected-model defaults before starting a turn. This enables the
  advertised code mode, Responses Lite, context/compaction defaults, and related
  capabilities; simply adding GPT-5.6 names to the picker is insufficient.
- Filter reasoning choices by model capabilities, preserve deliberate user
  overrides, and provide a migration/fallback for saved obsolete model IDs.
- Render and persist typed tool outputs and code-mode notifications; the
  current transcript reduces tool results to `result.content` strings.

### Existing incomplete app behaviors

- **Approvals:** runtime creation does not supply an `approvalHandler`.
  Disabling Yolo mode selects `.onRequest`, while shell/write/edit/patch tools
  require approval. The core throws `approvalRequired` when no handler exists.
  Wire the request/decision UI and cancellation lifecycle.
- **Background access:** the setting is stored and displayed, but its core
  configuration field has no execution consumer. Cowork has no background-task
  or scene-lifecycle integration. Implement checkpoint/resume and bounded iOS
  background handling, or stop presenting this toggle as operational.
- Add a simulator build/unit-test CI lane. Cowork currently has no checked-in
  GitHub Actions workflow, so an updated dependency can break the app unnoticed.

## 2. SwiftCodexCore: update the focused upstream contract

The pinned contract at `cbc83d9` validates successfully. The live upstream head
checked was `d58d0e5`, and all five watched source files differ. Evaluating the
existing contracts against those current files produces two failures:

| Contract | Current observation |
| --- | --- |
| Model catalog | GPT-5.6 context fields no longer match the pinned expectations. |
| Model schema/tool mode | The expected `ModelInfo.supports_parallel_tool_calls` declaration is absent. |
| Raw-response token usage | Existing focused contract still passes. |
| MCP encrypted content | Existing focused contract still passes. |

For Sol, Terra, and Luna, the checked Codex catalog now specifies
`context_window: 272000`, `max_context_window: 872000`, and
`shell_type: unified_exec`. Swift's fallback records still specify
372000/372000 and `shell_command`. The old `reasoning_summary_format` field is
also absent from those current catalog records. These are Codex catalog values,
not a claim about universal public API model limits.

Sources:
[current upstream catalog](https://raw.githubusercontent.com/openai/codex/d58d0e5841e0de08e251673db2d5af8cf3a1ad51/codex-rs/models-manager/models.json),
[current model schema](https://raw.githubusercontent.com/openai/codex/d58d0e5841e0de08e251673db2d5af8cf3a1ad51/codex-rs/protocol/src/openai_models.rs).

Required work:

1. Review the semantic changes, including new reasoning-summary capability
   handling and unified-exec expectations. Decide the intentional iOS tool
   mapping rather than promising a desktop PTY implementation.
2. Update fallback metadata, behavior and regression tests together with
   `UpstreamParity/codex.json`; do not merely replace its hashes.
3. Retain unknown-field tolerance and dynamic discovery.
4. Run the existing iPhoneOS and WebKit worker tests after implementation.
5. Keep the scheduled drift detector, but distinguish a moving upstream commit
   from a genuinely incompatible watched contract.

The parity script initially hit the local Python trust-store issue; using
`SSL_CERT_FILE=/etc/ssl/cert.pem` allowed normal certificate verification and
completed the check. No TLS verification was disabled.

## 3. JustBash: refresh skill compatibility and make it reproducible

### Three failing tests and two hidden coverage gaps

Failing cases in `PrimaryRuntimeSkillsIOSCheckerTests`:

- `testCheckerAcceptsExplicitSkillFamilyRoots`
- `testCheckerReportsConcreteIOSBlockersForCachedPrimaryRuntimeSkills`
- `testStagedCompatibilityCanRunRepresentativeCachedHelpers`

The first two assert findings tied to the old presentation helper layout. The
third raises `FileNotFoundError` for a hard-coded `26.430.10722` cache directory.
The installed documents/presentations/spreadsheets bundles are `26.826.12353`.

The two JavaScriptCore artifact integration tests also skip because they point
at the missing April cache. The other 34 skips are opt-in performance tests.
Therefore the passing shell tests do not establish current artifact support.

Updating the version string alone is insufficient: the August presentation
bundle no longer contains `scripts/build_artifact_deck.mjs` or
`scripts/render_lucide_icon.mjs`.

Required work:

- Select one explicit supported skill snapshot shared by JustBash tests,
  helper probes, documentation, and Cowork's bundle generator.
- Replace personal absolute cache paths with configurable roots and a
  version/hash manifest; keep core regression tests independent of a personal
  Codex installation. Use intentional fixtures and a separate real-bundle
  integration lane.
- Rewrite probes for the current helper/API layout, then verify actual
  DOCX/PPTX/XLSX output and supported previews in the iOS runtime.
- Regenerate Cowork's embedded skills only after the corresponding runtime
  paths work. Its generator also points at `26.430.10722`.
- Update stale roadmap/test-count claims and add package plus iOS CI.

### Runtime work beyond the immediate failures

- `JustBashPython` remains a planned package product. BeeWare embedding exists
  only in the phone sample; Cowork deliberately has no Python runtime. Full
  document workflows require a deliberate supported runtime/package choice,
  not just newer skill text.
- Artifact rendering/formula/import compatibility remains a bounded shim,
  not the complete desktop artifact-tool runtime. Define and test the supported
  subset before exposing newer skill expectations.
- `js-exec` calls synchronous JavaScriptCore evaluation before checking its
  polling deadline. It cannot preempt non-yielding JavaScript. SwiftCodexCore's
  separate WebKit code-mode isolation does not automatically fix this shell
  command. Implement a terminable execution boundary or accurately constrain
  its advertised guarantees.

### Selective upstream shell parity

The upstream TypeScript package is now `3.4.2`; this Swift project is a rewrite,
so it cannot be upgraded with a package-version bump. Concrete candidate gaps
include jq external-argument flags/`$ARGS`, real file descriptors above 2, and
the custom-command original-command hook. Local `jq` rejects those flags;
`read -u` is ignored and higher descriptor redirection is explicitly stubbed.
Prioritize these according to agent workloads and attach parity fixtures.

Source: [upstream changelog](https://github.com/vercel-labs/just-bash/blob/main/packages/just-bash/CHANGELOG.md).

## Recommended implementation order and exit criteria

1. **Restore the baseline:** Cowork enum/event compatibility; JustBash skill
   fixture/probe repair. Exit: Cowork simulator build and existing suites pass,
   with artifact skips explicit rather than silently accepted as coverage.
2. **Update SwiftCodexCore contracts:** metadata/schema behavior and focused
   regressions, then its macOS/iOS CI lanes.
3. **Integrate Cowork:** dynamic models, capability defaults, notification and
   typed-output rendering, approval handling, and saved-chat migration.
4. **Refresh artifacts as one vertical slice:** supported skill snapshot →
   JustBash runtime checks → Cowork bundle → real device/simulator artifact
   import/export/preview checks. Include JustBashPhone in this compatibility lane.
5. **Stabilize releases:** add the missing cross-project CI, choose immutable
   compatible revisions or release tags, and deliberately revisit Cowork's
   ignored app lockfile policy. Resolve private-repository access before
   claiming Cowork remote synchronization or publishing changes.

Not verified in this assessment: live ChatGPT/OAuth/model requests, device
background execution, full artifact fidelity, or the iOS WebKit test suite.
Cowork's failed build prevented app-level runtime tests. The upstream review
covered the five existing watched contracts, not complete Codex parity.
