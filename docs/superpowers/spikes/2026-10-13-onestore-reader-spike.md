# Spike: can we read `.one` files? (milestone 2 feasibility)

Date: 2026-10-13. Output of a throwaway probe; the probe code was Python in a scratch folder and is not part of this repo.

**Question.** Can the MS-ONESTORE / MS-ONE formats be parsed well enough to recover each page's objects with their positions, text runs and formatting?

**Answer.** Yes for text containers, paragraphs, indentation, lists and (structurally) images. Unknown for tables and ink, which none of the three sampled files contain. Writing is a separate and harder problem, not tested here.

## Method

- Specs: MS-ONESTORE (rev 13.3) and MS-ONE (2022-11-15), from the official Open Specifications download host and learn.microsoft.com. The `msopenspecs.microsoft.com` host has a broken TLS certificate; the current host is `officeprotocoldocs-f5hpbjgea6b8gneq.b02.azurefd.net`. Microsoft's notice on the spec pages says implementers may copy and use the documentation to build implementations, and that a given document might be covered by the Open Specifications Promise; check the promise's scope before shipping.
- Samples: three section files copied read-only from the user's OneNote backups (smallest, median, largest by size: 5 KB, 30 KB, 41 MB). Only structure and numbers were printed. No note text, titles or file names were read into output, logs or this repo. The copies were deleted afterwards.
- Probe: parse header, file node lists, object declarations, property sets; resolve CompactIDs through each revision's global ID table; overlay revisions; walk page → outline → outline element → rich text → paragraph style.

## Results

| Check | Result |
|---|---|
| File header: type GUID `{7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}`, format GUID, ffv `0x2A`, root list at header offset 172 | Matches spec in all 3 files |
| File node lists, fragments, all node types met (`0x04`…`0xC5`) | Parsed with **0 errors** in all 3 files (41 MB file: 2,734 objects) |
| Property sets (all property types, nested sets, arrays) | Parsed; byte layout matches the spec |
| Global ID table and CompactID resolution | Works; revisions overlay correctly |
| Pages recovered | 1 of 1 (median file), **11 of 11** (large file) |
| Outline (our "text container") position and width | Present: `OffsetFromParentHoriz/Vert` and `LayoutMaxWidth`, as floats in **half-inch units**; 1 unit = 36 pt. Real example: x=36 pt, y=86 pt, w=432 pt |
| Outline height | Not authoritative: `LayoutMaxHeight` is a cached maximum, so height is derived from content. This matches our model |
| Paragraphs | One `OutlineElement` per paragraph, each with one `RichText` node; blank lines are real empty paragraphs |
| Indentation and nesting | Nested outline elements (child levels), plus `OutlineElementChildLevel` and `RgOutlineIndentDistance` |
| Lists | `NumberListNode` objects (`NumberListFormat`, font, size), 145 in the large file |
| Run formatting | Rich text has `TextRunIndex` (character offsets) and `TextRunFormatting` (references to style objects); most paragraphs have one run, some have several (`runs=3`) |
| Style properties | Bold, Italic, Underline, Strikethrough, Superscript, Subscript, Font, FontSize (half-points), FontColor, Highlight are in `ParagraphStyleObject`s |
| Text storage | `TextExtendedAscii` (8-bit) for plain text, `RichEditTextUnicode` (UTF-16) when needed; both are present in real files |
| Images | `ImageNode` with `PictureContainer`, `LayoutMaxWidth/Height`, and offsets only when the image sits directly on the page (3 of 98); most images live inside outlines |

## Corrections to the milestone-1 design assumptions

1. **Units.** Layout values are half-inch floats, not points. Convert with 36 pt per unit.
2. **Page root.** The role-1 root of a page's revision is a `PageManifestNode`, whose children contain the `PageNode`; it is not the page itself.
3. **Revisions.** An object space holds several revisions in different roles (full page snapshots and a version-history context). A reader must pick the newest revision whose role-1 root is a `PageManifestNode`, not simply the last revision. Files in this sample contain 4–5 revisions per page.
4. **Text encoding.** Both 8-bit and UTF-16 text exist; the 8-bit code page is not named by the property itself (character set is carried elsewhere, e.g. `Charset` in style objects), so the reader needs a defined fallback.
5. **Titles.** The page title is a separate `TitleNode` outline at offset (0,0); our model has only a title string and containers, so import must map it.

## Risks and unknowns

- **Ink is undocumented.** MS-ONE has no mention of ink, and a public Microsoft forum thread reports real files use property IDs the spec omits. The sample files had 15–27 distinct undocumented property IDs (none among layout or formatting properties); none of the sampled files contain ink or tables. **Not tested:** tables, ink, embedded files, audio.
- **Transaction log not used.** The probe read all file node lists to their end markers. A real reader should honour the transaction log so it reads only committed nodes; this was not tested.
- **Writing is untested and harder.** A writer must produce a valid transaction log, hashed chunk list, free chunk list, global ID table and CRCs, and must be accepted by real OneNote. Nothing here shows OneNote accepts a generated file. Validation needs throwaway notebooks created by the user.
- **Fidelity.** The 15–27 distinct undocumented property IDs seen in the larger files were ignored. Under architecture B (own model) they are dropped on import and on export, which is lossy by design.

## Recommendation

Proceed with the reader (milestone 2). Effort estimate: moderate. The container layer is about 500–800 lines of Swift; the object-graph and model mapping about as much again; tests are easy because the probe gives structural assertions per file.

Before specifying ink and tables, either scan the whole backup set for their object types (counts only), or have the user create a few throwaway notebooks containing a table, ink, an image and an embedded file. Treat the `.one` writer (milestone 4) as a separate spike: generate a minimal valid file and see whether OneNote opens it.
