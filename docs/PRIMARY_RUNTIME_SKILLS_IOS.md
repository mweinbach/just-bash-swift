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
  Node-compatible shims including `node:*` builtin aliases, sandbox filesystem
  access, `fetch`, host-provided addon modules, and a small ESM compatibility
  layer for `.mjs` entrypoints, relative imports, dynamic `import()`, and
  sandboxed `node_modules` packages with `package.json` exports. The loader also
  handles bundled/minified ESM package shapes where imports and `export{...}`
  lists appear mid-line without whitespace, plus nested export conditions such as
  `exports.node.import`.
- The iPhone host stages a limited pure-JS `@oai/artifact-tool` compatibility
  package under both `/node_modules/@oai/artifact-tool` and the Codex primary
  runtime cache-shaped path. It supports direct imports, `presentation-jsx`, and
  basic `.xlsx`/`.pptx` export smoke checks. It is not the full upstream
  artifact-tool renderer/importer.
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
- The current iOS package set stages `openpyxl`, `Pillow`, and `pdf2image`, but
  `lxml` has no matching CPython 3.14 iOS wheel through PyPI plus BeeWare's
  wheel index, and `python-docx` depends on `lxml`.
- The Documents helpers require real `lxml`/`python-docx` OOXML behavior,
  including namespace-aware XPath, XML parser options, parent/sibling mutation,
  and low-level Word XML constructors. A shallow import shim is not sufficient.
- `pdf2image` is importable when staged, but its normal rendering path expects
  Poppler binaries that are not provided by the iOS app.

Minimum path to support:

- Add an iOS DOCX authoring and OOXML patching layer that uses only bundled
  Swift/Python code and signed native extensions.
- Replace LibreOffice/Poppler render QA with an iOS-compatible renderer, or mark
  render QA as unavailable with a product-level fallback.
- Stage all Python dependencies as iOS-compatible wheels/frameworks at build
  time; do not rely on runtime `pip install`.
- If `lxml`/`python-docx` remain unavailable as iOS wheels, replace the helper
  calls with a native Swift or pure bundled OOXML adapter that implements the
  same document-mutation behavior.

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

- JavaScriptCore is not Node. The current `js-exec` bridge has useful shims,
  `node:*` builtin aliases, ESM compatibility for minified package output, and
  sandboxed package resolution, but it does not provide native Node packages.
- The staged `@oai/artifact-tool` compatibility package covers direct imports,
  `presentation-jsx`, and basic Office export smoke checks, but it intentionally
  does not provide full upstream rendering or Office import behavior.
- The local Codex runtime cache has the full Node package, but that cache is not
  part of the iOS app bundle and includes bundled runtime assets such as
  `skia-canvas` and `@oai/walnut` WASM that need an explicit iOS packaging and
  execution path.
- `skia-canvas` includes a native Node addon (`lib/skia.node`), and the browser
  fallback assumes DOM canvas APIs that are not available in this JavaScriptCore
  runtime.
- `@oai/walnut` uses a .NET WASM payload plus `dotnet.js`/`blazor.boot.json`
  resource loading for Office import/export paths; those resources are not
  packaged or bridged for iOS JavaScriptCore today.
- Native rendering dependencies such as `sharp`/`skia-canvas` are not staged for
  iOS.

Minimum path to support:

- Provide an iOS-compatible artifact-tool runtime surface, either as a
  JavaScriptCore bundle that avoids Node-only APIs or as a native Swift layer.
- Replace Node script entrypoints with Swift/JavaScriptCore command wrappers
  that use `BashFilesystem` and app-local temporary storage.
- Audit child-process calls so they target sandbox-provided commands only, and
  replace native Node rendering dependencies.

### Spreadsheets

The Spreadsheets skill is not iOS-runnable unchanged.

Required pieces found in the skill:

- `@oai/artifact-tool` for workbook creation, inspection, render, and `.xlsx`
  export.
- A Node-style workspace dependency loader, package exports, and normal Node
  module resolution.
- Optional Python source-processing libraries such as `pandas`, `numpy`,
  `pypdf`, `python-docx`, and `reportlab`.

iOS blockers:

- The iPhone host exposes a limited pure-JS artifact-tool compatibility package
  for workbook creation and basic `.xlsx` export smoke checks.
- Sandboxed `node_modules` package resolution is available inside the current
  JavaScriptCore runtime, but only for package sources and assets that are
  actually staged into the app-visible filesystem.
- The JavaScript loader can parse the package's minified ESM import/export shape,
  so the remaining blocker is not syntax loading; it is the unported
  full-fidelity artifact-tool runtime dependencies, especially `skia-canvas`
  native rendering and `@oai/walnut` WASM resources.
- The optional Python analysis stack is partially staged: `numpy`, `pypdf`, and
  `reportlab` are available in the current package lane, while `pandas` and
  `python-docx` remain unavailable for this iOS target because of unresolved
  native dependencies.

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
It accepts the primary-runtime cache root by default, or explicit family/version
paths matching the three skill directories:

```bash
scripts/check_primary_runtime_skills_ios.py --strict \
  --documents-root /Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/documents \
  --presentations-root /Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/presentations \
  --spreadsheets-root /Users/mweinbach/.codex/plugins/cache/openai-primary-runtime/spreadsheets
```

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
parseable, and the iPhone host can import a limited pure-JS artifact-tool
compatibility package, but full Documents rendering plus high-fidelity
artifact-tool render/import behavior still require desktop/container runtime
capabilities that this iOS runtime does not yet provide.
