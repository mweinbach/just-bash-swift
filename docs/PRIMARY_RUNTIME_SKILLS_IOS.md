# Primary runtime artifact support on iOS

The supported skill snapshot is pinned by version and SHA256 in
`Compatibility/primary-runtime.json`. The bundle generator must verify that
manifest and adapt the skills to the mobile API below. Installing a newer skill
bundle does not change the supported runtime. Unmodified desktop skill helpers
are not a supported mobile execution contract.

The optional `JustBashJavaScript` product runs the bundled
`Sources/JustBash/Resources/artifact-tool.mjs` module in JavaScriptCore. Enable it
through `BashOptions.enableOAIPrimaryRuntime()`. No Python runtime is required for
the supported JavaScript document, presentation, and spreadsheet workflows.
BeeWare Python remains an optional phone-host integration, not a package product.

## Supported API

| Workflow | Supported | Explicitly outside the mobile contract |
| --- | --- | --- |
| DOCX | Styled text paragraphs, rectangular tables, literal `replaceText`, preserved original ZIP parts and XML structure during targeted edits | Pagination/rendering, desktop Python helpers, replacing all imported document paragraphs |
| PPTX | Slide sizes, positioned rectangle/ellipse shapes, uniform font/style/color/alignment, embedded PNG/JPEG/SVG, import/export of that subset | Tables, custom masters/layouts, animations, groups, mixed text-run styles, cropped images, speaker notes |
| XLSX | Values, formulas listed below, font/fill/border/alignment/number formats, merges, tables, freeze panes, literal-list validation, comments, line/bar/column charts | Pivots, macros, external links, conditional formatting, sparklines, what-if tables, images/shapes, R1C1 formulas |
| PNG | Native CoreGraphics/CoreText/ImageIO rendering of slide shapes/text/PNG/JPEG and styled worksheet cells | SVG rasterization, document pagination, native chart preview, arbitrary Excel number-format syntax |

The exported Office files contain native OOXML for supported features; they are
not screenshots in Office containers. Import rejects detected unsupported
structures rather than flattening them into a misleading successful result.
The formula engine is intentionally a subset, not the Excel calculation engine.

### Spreadsheets

```js
import { Workbook, SpreadsheetFile } from '@oai/artifact-tool';
const workbook = Workbook.create();
const sheet = workbook.worksheets.add('Summary');
sheet.getRange('A1:B3').values = [['Item', 'Amount'], ['One', 4], ['Two', 6]];
sheet.getRange('B4').formulas = [['=IF(SUM(B2:B3)=10,10,0)']];
sheet.getRange('A1:B1').format.font.bold = true;
sheet.getRange('A1:B1').format.fill.color = '#e8eef8';
sheet.getRange('B2:B4').setNumberFormat('$#,##0.00');
sheet.freezePanes.freezeRows(1);
sheet.tables.add('A1:B3', true, 'SummaryTable');
await (await SpreadsheetFile.exportXlsx(workbook)).save('/workspace/summary.xlsx');
await (await workbook.render({ sheetName: 'Summary', range: 'A1:B4' }))
  .save('/workspace/summary.png');
```

Formulas support numbers, text, A1 references, ranges, quoted worksheet names,
arithmetic, percentages, concatenation, comparisons and lazy IF/IFERROR.
Functions: SUM, AVERAGE, MIN, MAX, COUNT, COUNTA, ROUND, ROUNDDOWN, ROUNDUP, ABS,
POWER, SQRT, IF, IFERROR, AND, OR, NOT, CONCAT, CONCATENATE, LEN, LEFT, RIGHT, MID,
LOWER, UPPER, TRIM, TODAY and NOW. Errors are returned as Excel-style values and
included by `workbook.inspect({kind:'formula'})`. Unsupported syntax/functions
produce an error. Imported and exported cached formula values preserve errors.

Charts export as native line/bar/column OOXML. For cell-only native preview of a
worksheet containing charts, explicitly pass `chartPreview: 'omit'`; check the
chart in the exported workbook separately. Preview otherwise rejects unsupported
chart rendering. Select a range/scale that fits within 1800 pixels per axis.

### Presentations

Use `Presentation.create({slideSize:{width,height}})`, `slides.add()`, and
`slide.shapes.add({name,position:{left,top,width,height},geometry:'rect',fill,line})`.
Set `shape.text` to a string, then set `fontSize`, `bold`, `italic`, `color`,
`typeface`, `alignment`, and `insets` on its text frame. Positions use pixels;
font size uses points. `slide.images.add({dataUrl,position,alt})` accepts base64
PNG/JPEG/SVG; `path` can refer to an image already in the sandbox. Export with
`PresentationFile.exportPptx(deck)` and `deck.export({slide,format:'png'})`.

The native preview renders actual images and mixed-case text. Outside the
JavaScriptCore host, PNG requests fail unless the caller explicitly requests
`previewMode:'schematic'`. That legacy diagnostic is not visual-quality evidence.

### Documents

Use `DocumentModel.create()`, `addParagraph(text, {bold,italic,fontSize,color})`,
`addTable(rows)`, `DocumentFile.exportDocx`, and `DocumentFile.importDocx`.
For existing files use `replaceText('literal search','replacement')`; matches can
span text runs. Unchanged ZIP parts, tables, existing formatting and relationships
are retained. Appended paragraphs/tables are inserted before the final body
section properties. Rendering and pagination are unavailable; preview the
exported document through the host's Office-capable viewer.

## Validation

```bash
python3 scripts/verify_primary_runtime_snapshot.py --cache-root /path/to/openai-primary-runtime
python3 scripts/check_primary_runtime_skills_ios.py --strict --json
python3 scripts/smoke_primary_runtime_skill_helpers.py --json
swift test --filter 'ArtifactCorrectnessTests|PrimaryRuntime'
```

The first two checks validate the selected snapshot and declare capabilities;
their JSON explicitly sets `runtimeVerified: false`. They never install skills.
Unit tests use synthetic skill bundles and do not depend on a personal Codex
cache. The Node smoke exercises self-contained API fixtures and inspects native
OOXML. The JavaScriptCore suite additionally exercises native image previews,
base64 binary integrity, and the runtime readiness command without Python.

`primary-runtime-skills-check` runs representative JavaScript API operations and
writes its report to `/workspace/primary-runtime-skills-ios-report.json` by
default. Its `ready` result applies only to the supported mobile API above.

For manual visual QA, export the test artifacts:

```bash
JUSTBASH_ARTIFACT_OUTPUT_DIR=/tmp/justbash-artifact-qa \
  swift test --filter ArtifactCorrectnessTests
```

## Execution limits

JavaScriptCore's public API cannot interrupt arbitrary synchronous JavaScript.
`defaultTimeoutMs` and `defaultNetworkTimeoutMs` are cooperative deadlines:
the engine checks them after synchronous evaluation and while awaiting async
work. Cancellation stops pending async work and prevents subsequent shell
commands. A non-yielding synchronous script can still block this backend.

Hosts requiring a hard deadline must use
`BashJavaScriptOptions(executionPolicy: .requirePreemptible)`. This backend rejects
the request before execution, including infinite loops. A separately implemented
preemptible backend is still required; SwiftCodexCore's code-mode worker does not
isolate `js-exec` automatically. See [execution limits and prototype evidence](IOS_EXECUTION_LIMITS.md)
for the public WebKit/QuickJS options and their remaining constraints.

The package CI runs the full Swift suite (including hermetic pinned-snapshot and
hash-mismatch tests), the self-contained Node artifact fixtures, and iOS Simulator
library compilation. It uses GitHub's public preview
[`xcode-27` runner](https://github.blog/changelog/2026-07-16-xcode-27-runner-image-now-in-public-preview/)
with Node 22. The actual desktop skill cache is deliberately absent from CI;
verify it with the snapshot command above before regenerating a mobile bundle.
Adding the workflow does not imply that a hosted run has completed.
