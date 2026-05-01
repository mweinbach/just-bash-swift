# Primary Runtime Skills On iOS

This note records the compatibility contract for evaluating the OpenAI primary
runtime file-artifact skills against this repository's iOS runtime. It is about
whether the cached skills could run if registered later; it does not install or
register the skills.

Evaluated skill bundles:

- `/Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/documents/26.430.10722`
- `/Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/presentations/26.430.10722`
- `/Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/spreadsheets/26.430.10722`

## Current iOS Runtime Surface

`just-bash-swift` can run scripts in-process on iOS through Swift, the virtual
filesystem, and optional embedded runtimes.

- JavaScript is available through the `JustBashJavaScript` product. It is backed
  by JavaScriptCore and exposes `js-exec`, CommonJS-style `require`, selected
  Node-compatible shims, sandbox filesystem access, `fetch`, and host-provided
  addon modules.
- Python is available only in the generated iPhone host app when built with
  BeeWare's `Python.xcframework`. The app registers `py-exec`, `python`, and
  `python3` custom commands, stages the Python home into the app bundle, and
  adds `Apps/JustBashPhone/PythonApp/site-packages` to `sys.path`.
- iOS does not provide a general `Process`/`NSTask` execution model for these
  skills. Anything that shells out to `node`, `python3`, `soffice`, Poppler, or
  other host binaries must be replaced with an in-process iOS implementation or
  bridged to an app-bundled, signed framework.

## Compatibility Findings

### Documents

The Documents skill is not iOS-runnable unchanged.

Required pieces found in the skill:

- Python helper scripts using `python-docx`, `lxml`, `openpyxl`, `Pillow`, and
  `pdf2image`.
- `render_docx.py`, which invokes `soffice`/LibreOffice through `subprocess` for
  DOCX-to-PDF conversion and render QA.
- PDF-to-image conversion assumptions that typically require Poppler binaries
  behind `pdf2image`.

iOS blockers:

- `soffice`/LibreOffice is not available as an app-bundled iOS renderer.
- `subprocess` calls to external renderers are not compatible with the iOS host
  execution model.
- Several Python dependencies are native-extension or external-binary heavy
  (`lxml`, `Pillow`, `pdf2image`/Poppler). They are not part of the current
  BeeWare iPhone package set.

Minimum path to support:

- Add an iOS DOCX authoring and OOXML patching layer that uses only bundled
  Swift/Python code and signed native extensions.
- Replace LibreOffice/Poppler render QA with an iOS-compatible renderer, or mark
  render QA as unavailable with a product-level fallback.
- Stage all Python dependencies as iOS-compatible wheels/frameworks at build
  time; do not rely on runtime `pip install`.

### Presentations

The Presentations skill is not iOS-runnable unchanged.

Required pieces found in the skill:

- Node `.mjs` scripts that import `node:fs`, `node:path`, `node:url`,
  `node:module`, `node:child_process`, and other Node-only APIs.
- `@oai/artifact-tool` version `2.7.3` or newer with
  `@oai/artifact-tool/presentation-jsx`.
- Optional graphics helpers that depend on Node packages such as `sharp` or
  `skia-canvas`.
- Some helper paths spawn Python for contact-sheet generation.

iOS blockers:

- JavaScriptCore is not Node. The current `js-exec` bridge has useful shims but
  does not provide ESM loading, npm package resolution, native Node packages,
  `node:*` modules, or child process execution.
- `@oai/artifact-tool` is not currently bundled as an iOS-compatible
  JavaScriptCore addon module or Swift framework in this repository.
- Native rendering dependencies such as `sharp`/`skia-canvas` are not staged for
  iOS.

Minimum path to support:

- Provide an iOS-compatible artifact-tool runtime surface, either as a
  JavaScriptCore bundle that avoids Node-only APIs or as a native Swift layer.
- Replace Node script entrypoints with Swift/JavaScriptCore command wrappers
  that use `BashFilesystem` and app-local temporary storage.
- Replace or remove child-process and native Node rendering dependencies.

### Spreadsheets

The Spreadsheets skill is not iOS-runnable unchanged.

Required pieces found in the skill:

- `@oai/artifact-tool` for workbook creation, inspection, render, and `.xlsx`
  export.
- A Node-style workspace dependency loader and normal Node module resolution.
- Optional Python source-processing libraries such as `pandas`, `numpy`,
  `pypdf`, `python-docx`, and `reportlab`.

iOS blockers:

- The required artifact-tool package is not exposed as an iOS runtime module.
- Node module resolution is not available inside the current JavaScriptCore
  runtime.
- The optional Python analysis stack includes packages that are not currently
  bundled for BeeWare iOS (`pandas`, `pypdf`, `python-docx`, `reportlab`; only
  `numpy` is tracked as an optional native iOS probe today).

Minimum path to support:

- Bundle an iOS-compatible spreadsheet authoring/export engine.
- Add a runtime dependency resolver that returns iOS-backed JS/Python runtimes
  and package locations, matching the skill contract without using system
  runtimes.
- Stage any Python analysis dependencies at build time for every device and
  simulator slice.

## Guardrail

Use `scripts/check_primary_runtime_skills_ios.py` before attempting to register
these skills in an iOS build. The checker verifies the cached skill bundles and
reports the iOS blockers above from the actual files in the cache and this repo.

The Python-linked iPhone host also exposes an on-device command:

```bash
primary-runtime-skills-check
cat /workspace/primary-runtime-skills-ios-report.json
```

That command does not install or register the skills. It writes a JSON readiness
report from inside the iOS host by probing BeeWare Python imports and
JavaScriptCore module resolution for the runtime pieces these skills expect. It
exits nonzero while the report is blocked so an on-device agent can use it as a
readiness gate.

The current expected result is `blocked`: the skill bundles are present and
parseable, but they require desktop/container runtime capabilities that this iOS
runtime does not yet provide.
