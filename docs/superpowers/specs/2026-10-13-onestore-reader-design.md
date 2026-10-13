# Milestone 2: `.one` reader and importer: design

Date: 2026-10-13. Status: draft for review.
Parent spec: `2026-10-13-onenote-clone-design.md` (milestone 2 of 4). Evidence: `docs/superpowers/spikes/2026-10-13-onestore-reader-spike.md`.

## 1. Intent

Let a user bring a OneNote section file into the app: `File > Import .one…` copies the file's pages into a new section of the open notebook, as editable content in our own page model. Importing never modifies the source file and never writes to the notebook on failure. Writing `.one` files is out of scope (milestone 4).

Decisions made with the user:
- Images and tables are added to the model now and are read-only on the canvas (editing tools come in milestone 3).
- Import creates a **new section** in the open notebook; the sidebar gains a section picker.
- Images and tables that sit inside an outline are **flattened** into separate stacked objects, not kept inline.
- Architecture: two layers, pure Swift, no external dependency.
- Test data stays private: no real `.one` files or note content in the repo, tests or logs. A real-file check is opt-in.

Evidence already gathered (spike plus a scan of 613 of the user's backup files, counts only): all files parse; 98% contain pages; images are in 29% of files, tables in 10%, lists in 26%, embedded files in 6%; of the 939 embedded data objects 84% are PNG, 9% JPEG and 3% TIFF (no EMF/WMF), and the rest are attachments (zip/Office, PDF, legacy Office); ink-like undocumented object types appear in at most 1.5% of files.

## 2. Non-goals

Writing `.one`; ink; inline images/tables inside text boxes; editing tables or images; page templates, tags, version history, audio, maths; importing a whole folder or notebook tree; `.onetoc2` files; password-protected or encrypted files; cleaning up unused assets after deletion.

## 3. Architecture

New targets and dependencies (one way only):

| Target | Purpose | Depends on |
|---|---|---|
| `OneStore` | Faithful reader for the MS-ONESTORE revision-store format: header, transaction log, file node lists, revisions, global ID tables, objects with raw properties, file data. Keeps unknown object types and properties. | Foundation |
| `OneImport` | Maps a `OneStore` object graph to `PageModel`: picks revisions, converts units, flattens, maps styles; produces an `ImportResult` and loss report. | `OneStore`, `PageModel` |
| `PageModel`, `Store`, `CanvasKit` | Extended as in section 4. | existing |

`OneStore` knows nothing about our model. `OneImport` knows nothing about bytes or AppKit (a `TextMeasuring` is passed in).

### 3.1 `OneStore`

- Public entry: `OneFile(data: Data) throws`; read-only value types for object spaces, revisions and objects.
- Header: `guidFileType` must be the `.one` GUID `{7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}`; format GUID `{109ADD3F-911B-49F5-A5D0-1791EDC8AED8}`; `.onetoc2` and unknown types give typed errors. The root file node list is at header offset 172 (a 12-byte `FileChunkReference64x32`).
- File node lists: fragments with magic `0xA4567AB1F5F7F4C4`, footer `0x8BC215C38233BA4B`, terminator `0xFF`. File node header packs `FileNodeID` (10 bits), `Size` (13), `StpFormat` (2), `CbFormat` (2), `BaseType` (4), reserved (1). Stp formats: 8 bytes, 4 bytes, 2 bytes compressed (×8), 4 bytes compressed (×8). Cb formats: 4 bytes, 8 bytes, 1 byte compressed (×8), 2 bytes compressed (×8).
- **Transaction log is honoured:** for each list, only the committed node count (from the last transaction entry that modified it) is read. Where the log is absent or invalid the reader falls back to reading to the terminator and records a warning.
- Revisions: object spaces contain revision manifests (`0x1E`/`0x1F`), each with its own global ID table (`0x22`/`0x24`/`0x28`), root references (`0x5A`) and object groups (`0xB0`/`0xB4`/`0xB8`). Objects are declared by `0xA4`/`0xA5` and read-only `0xC4`/`0xC5`; each declaration references an `ObjectSpaceObjectPropSet`. A revision's visible objects are its own declarations overlaid on its dependent revision's.
- Property sets: `PropertyID` = 26-bit id + 5-bit type + 1 bool bit; all types (`NoData`, `Bool`, 1/2/4/8 bytes, length-prefixed data, object ID and array, object-space and context IDs, arrays of property sets, nested property sets). Object references resolve through the declaring revision's global ID table. Property values are held as typed raw values; unknown property IDs are kept.
- File data: `FileDataStoreObject` payloads are exposed as `Data` slices of the original buffer, not copies.
- Failure behaviour: every read is bounds-checked; malformed input yields `OneStoreError` (`notAOneFile`, `unsupportedFileType`, `unsupportedVersion`, `truncated`, `corrupt(offset:, reason:)`). It never traps, loops forever, or allocates unbounded memory for a claimed size larger than the file.

### 3.2 `OneImport`

Public: `OneImporter(measurer: TextMeasuring).importSection(from: OneFile, name: String) -> ImportResult` where `ImportResult` holds the `Section` content (pages), asset files (`name`, `Data`), and `ImportReport`.

Rules (units: layout values are half-inch floats; **1 unit = 36 pt**):

- **Pages:** per object space, the newest revision whose role-1 root is a PageManifest; the PageNode is among that manifest's content children. A page that cannot be resolved is skipped and counted; other pages still import.
- **Title:** the TitleNode outline's text paragraphs become `Page.title` (joined with a space); empty gives "Untitled Page". `PageDateTime` lines are dropped and counted.
- **Z-order:** the order of the page's element children.
- **Outline → container(s):** x, y from `OffsetFromParentHoriz/Vert`; width from `LayoutMaxWidth`, falling back to `LayoutOutlineReservedWidth`, then 432 pt. Height is derived by relayout, never copied.
- **Paragraphs:** each outline element is a paragraph, depth-first; indent = nesting depth, clamped to 0…8. Empty paragraphs are kept.
- **Flattening:** consecutive paragraphs form one `TextContainer`; an image, table or attachment inside the outline becomes its own object. Pieces are stacked downward from the outline's y; each piece's height comes from the measurer (text, tables), `LayoutMaxHeight` (images) or a fixed icon size (attachments); gap 0.
- **Text:** `RichEditTextUnicode` (UTF-16LE) wins when both encodings exist; else `TextExtendedAscii` decoded by the style's `Charset` (0/1 → Windows-1252; the other charsets in MS-ONE §2.3 map to their code pages; unknown → Windows-1252, counted). Runs split at `TextRunIndex` positions (count + 1 runs); run *n* takes `TextRunFormatting[n]` (one element when no index).
- **Run style:** bold, italic, underline, strikethrough, superscript, subscript and font name map directly; `FontSize` is half-points ÷ 2, always stored explicitly; `FontColor` and `Highlight` are `COLORREF` `0x00BBGGRR` (`0xFF000000` = automatic → none); `Hyperlink` plus `WzHyperlinkUrl` → link.
- **Paragraph style:** the named style `ParagraphStyleId` `h1`/`h2`/`h3` → heading 1/2/3. Other names (`p`, `h4`–`h6`, `cite`, `blockquote`, `code`, `PageTitle`, `PageDateTime`) contribute only their explicit properties and are counted as flattened. `ParagraphAlignment` 0/1/2 → left/center/right; any other value → left, counted.
- **Lists:** a `NumberListNode` whose `NumberListFormat` contains U+FFFD is numbered; otherwise bullet. `ListRestart` is ignored and counted.
- **Images:** `ImageNode` → `ImageObject` with the picture container's bytes (extension from sniffed magic bytes: png, jpg, tif, gif, bmp, pdf; unknown → `bin`), `ImageAltText`, size `LayoutMaxWidth/Height` × 36.
- **Tables:** `TableNode` → `TableObject`: column widths from `TableColumnWidths` × 36; rows and cells; each cell's paragraphs use the paragraph rules; `TableBordersVisible` → `bordersVisible`. Images or tables nested in cells are dropped and counted.
- **Attachments:** `EmbeddedFileNode` → `AttachmentObject`; data from its container; display name from `EmbeddedFileName`.
- **Skipped, never fatal:** unknown object types, undocumented properties, version history, note tags, ink-like objects. Each skipped JCID and each ignored property ID is counted.

## 4. Model, store and app changes

- `PageObject` gains `.image(ImageObject)`, `.table(TableObject)`, `.attachment(AttachmentObject)`, each with `id` and `frame`; z-order is array order; move, delete, copy/paste and z-order operations apply to them; `relayout` derives table height.
- `ImageObject`: `asset: String`, `altText: String?`. `TableObject`: `columnWidths: [Double]`, `rows: [[TableCell]]`, `bordersVisible: Bool`; `TableCell`: `paragraphs: [Paragraph]`. `AttachmentObject`: `asset: String`, `displayName: String`.
- The new cases are additive; existing pages still decode; the notebook version stays 1.
- `NotebookPackage`: `addAsset(data:, ext:) -> String` (atomic write to `assets/<uuid>.<ext>`); `addSection(name:, pages:)` and the import report at `imports/<section-id>.json`; write order is assets, pages, report, then the manifest entry last.
- `CanvasKit`: read-only drawing for images (`NSImage`), tables (bordered grid with cell text), attachments (icon box with name); selection, move, delete, copy/paste and z-order work as for other objects. Sidebar: section picker. `File > Import .one…` runs off the main thread, supports cancel, and ends with a summary sheet showing the report.

## 5. Loss report

Counts only (no note content): pages total/imported/failed; objects imported by kind; skipped JCIDs and ignored property IDs with counts; approximation counters (named styles flattened, unknown alignment, unknown charset, title date dropped, list restart ignored, table-cell contents dropped); transaction-log warnings.

## 6. Testing

- **OneStore, hand-built byte fixtures:** header; packed file-node fields and compressed references; CompactID; every property type including nested sets; transaction-log truncation; revision overlay. **Hardening:** each fixture truncated at every length and with single-byte flips must yield a typed error or a result, never a trap or hang.
- **OneStore corpus check (opt-in):** only when `ONE_CORPUS_DIR` is set; asserts every file parses and reports aggregate counts only. Not part of the default `swift run Checks`.
- **OneImport:** synthetic in-memory object graphs; one check per mapping rule above (units, flatten stacking, run split, colour, charset, lists, headings, alignment, title, counters).
- **Model and Store:** new object cases round-trip through JSON; assets written atomically; `addSection` ordering and failure behaviour; report written.
- **Manual acceptance (user):** import one of your own section files and compare with OneNote: layout, text formatting, lists, images, a table, cancel, a failure case (a damaged copy).
- No real `.one` files, note text or filenames in the repo, test output or logs.

## 7. Plan tasks (for the implementation plan)

1. Model and Store additions (objects, assets, sections, report) with checks.
2. `OneStore` primitives: header, node lists, transaction log, hardened reads, byte-fixture checks.
3. `OneStore` objects: property sets, global ID tables, revisions, object graph, file data, corpus check.
4. `OneImport` text mapping: runs, styles, charsets, lists, headings.
5. `OneImport` layout: outlines, flattening, images, tables, attachments, loss report.
6. App: Import menu, background import with cancel, section picker, summary sheet, read-only drawing of images/tables/attachments, manual acceptance.

## 8. Risks and open points

- Undocumented paragraph-style properties (for example `0x80034AA`, `0xC003452`) may carry formatting the spec omits; some imported text may look different from OneNote. Unknown until compared by eye.
- Flattening can drift vertically and turns one outline into several objects.
- Large files (the largest sampled is 41 MB) take noticeable time to import; progress and cancel are required.
- Charset tables beyond Windows-1252 are specified but untested against real files (the sample set may not contain them).
- Alignment value 3 and some list restarts have no documented meaning; counted, not mapped.
- Everything here is derived from MS-ONE rev 2022-11-15 and MS-ONESTORE rev 13.3 plus the user's own files; other OneNote versions may differ.
