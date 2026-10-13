# Native Mac note-canvas app with `.one` interop: design

Date: 2026-10-13. Status: draft for review.

## 1. Intent

Build a native macOS app that reproduces OneNote's free-form page canvas: objects placed at arbitrary positions on a page, with rich formatting. Storage is local files only for now, with no sync, accounts or network.

Supplied by the user:
- Object types in v1: text containers, images, tables, ink.
- The file "db" should be Microsoft `.one` files, read and written.
- One spec covers reader, editor and writer, delivered in staged milestones.
- Architecture B: our own page model and package format drive the editor, and `.one` is import/export only (lossy).
- Reader tests use read-only copies of the user's existing OneNote backups.

Assumptions (correct me):
- Swift, AppKit/SwiftUI, macOS 14 or later.
- The working format is a package folder (JSON per page plus asset files), not SQLite.
- The layout semantics in section 4 come from general knowledge of OneNote and are unverified until milestone 2.

Evidence from the earlier reverse-engineering (`findings.md`) that bears on this design:
- `.one` files begin with the MS-ONESTORE file-type GUID `{7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}`. Their internals have not been parsed.
- One `.one` file is one section. The notebook and section-group tree is a folder tree.
- Sync (Cobalt/FSSHTTP) is out of scope.

## 2. Non-goals (v1)

Sync of any kind; accounts; tags and checkboxes; page templates; audio and video; maths; snap guides and rulings; search; collaborative editing; reading or writing the OneNote cloud formats.

## 3. Architecture

Four units with one-way dependencies: `CanvasApp` → `Store` → `PageModel`, and `OneInterop` → `PageModel`. `CanvasApp` never touches `.one`.

| Unit | Purpose | Depends on |
|---|---|---|
| `PageModel` | Notebook, section, page and object types; layout maths; text/style operations; undo/redo commands. No UI, no I/O. | nothing |
| `Store` | Working format: a notebook package folder with one JSON file per page and separate asset files; autosave, crash-safe (write-then-rename). | `PageModel` |
| `OneInterop` | MS-ONESTORE reader (`.one` → `PageModel`) and writer (`PageModel` → `.one`), each producing a loss report. | `PageModel` |
| `CanvasApp` | AppKit canvas: place, drag, resize, z-order; formatting toolbar; table and ink tools; open, save, import and export. | `PageModel`, `Store`, `OneInterop` |

## 4. Page model and layout semantics

- **Page:** unbounded canvas, a title, and a flat list of objects. Every object has a frame (x, y, width, height in points) and a z-order index.
- **Text container:** the user resizes its width; its height is derived from content. It holds a tree of paragraphs, where indent level gives nesting. Containers do not reflow around each other. Overlap is allowed and z-order decides what is on top.
- **Paragraph:** runs plus paragraph style (heading level, bullet or numbered list, alignment). Runs carry bold, italic, underline, strikethrough, font, size, colour, highlight, superscript/subscript and an optional link.
- **Image:** asset reference plus frame. Resize keeps aspect ratio unless overridden.
- **Table:** grid of cells with per-column widths. Each cell holds paragraphs, and rows grow with content.
- **Ink:** strokes made of points with colour and width, positioned on the canvas like other objects.
- **Operations:** move, resize, delete, copy/paste, bring to front, send to back, and undo/redo over all of them.

## 5. `.one` interop

- **Import:** parse MS-ONESTORE, map it into `PageModel`, and write a loss report listing anything with no counterpart. Corrupt or truncated files give a typed error. Nothing is half-imported. The source file is never modified.
- **Export:** emit `.one` from `PageModel`, always to a new file and never over an existing one. Each export writes a loss report.
- **Fidelity:** the round trip through our model is lossy by design (architecture B).
- **Spec reference:** the Microsoft Open Specifications document for MS-ONESTORE is the authority for the container format. The property-set layer on top needs separate confirmation from the real files in milestone 2.

## 6. Testing

- `PageModel` and `Store`: unit tests for layout maths, text/style operations, undo/redo, and package save/load including crash-safe save.
- Reader: run against read-only copies of the user's backups in a scratch folder, asserting structural facts only (counts, positions, formatting flags). No note content may appear in tests, logs, fixtures or this repo.
- Writer: the app's own reader must re-read what it writes, plus golden-file checks against files the user creates. Opening the output in real OneNote is a manual check on throwaway notebooks the user creates, never on the backups.
- UI: a minimal set of canvas interaction tests.

## 7. Milestones

1. `PageModel`, `Store`, and a text-container canvas (move, resize, format, undo).
2. Reader, rendering the user's real pages. This milestone may force changes to section 4 if real files contradict the layout assumptions.
3. Images, tables and ink in the canvas.
4. Writer and export validation.

Each milestone gets its own implementation plan. Milestones 2 and 4 carry the main risk.

## 8. Risks and open questions

- The property-set layer and the exact structure of containers, text, tables and ink in `.one` files are unparsed and unverified. The reader milestone answers this.
- Writing files OneNote accepts without repair is the highest-risk item. No mature open-source writer has been checked.
- The user's backups contain private notes. They must stay read-only, in scratch locations only, and out of version control.
- Open: confirm the package-folder working format over SQLite.
