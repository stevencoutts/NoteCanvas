# NoteCanvas

A native macOS app for free-form notes. Pages are a canvas of positioned text boxes, images, tables, and attachments. Notebooks are ordinary folders on disk, and can be encrypted as a whole or section by section. OneNote section files (`.one`) can be imported, one at a time or from OneNote's own backups. The app does not sync, and it does not write `.one` files.

Requires macOS 14 or later. The interface is AppKit. There are no third-party dependencies.

## What you can do

- Place, move, resize, and format text boxes. Undo and redo cover those edits.
- Organise notes as sections, folders and pages in a sidebar tree. Every section and folder folds away. Add, rename and delete sections from the sidebar buttons, the File menu, or a right-click.
- Encrypt a notebook with a passphrase and a recovery key, when creating it or later from **File > Encrypt Notebook…**. Pages, images and the section structure are stored encrypted. The format is written down in `docs/encryption-spec.md`. There is no cloud sync yet.
- Lock a single section inside an encrypted notebook with its own passphrase and recovery key (right-click a section, **Lock Section…**). Someone who can open the notebook still cannot read a locked section. The format is in `docs/encryption-locked-sections.md`.
- Insert bullet and numbered lists, and insert images from disk or the clipboard.
- Draw imported images, tables, and attachments. Move, copy, and delete them. Editing tools for tables and ink are not in this version.
- Import a `.one` section with **File > Import .one…**. The import runs in the background and can be cancelled. The source file is only read. A failed or cancelled import does not add a section.
- Import every OneNote backup on the laptop with **File > Import OneNote Backups…**. It scans a backup folder (it starts at OneNote for Mac's own backup location), keeps the newest dated copy of each section, and creates one notebook per OneNote notebook in a folder you choose. Section groups become `Group / Section` names. Sections that cannot be read are listed and skipped. The backup files are only read.

Import is lossy by design. The app keeps its own page model. Anything it cannot represent is counted in a report saved inside the notebook (`imports/<section-id>.json`). That report is counts and ids only, not note text.

## Notebook layout

A notebook is a folder:

```
My Notes.notebook/
  notebook.json
  pages/<uuid>.json
  assets/
  imports/
```

`notebook.json` is written after the page and asset files, so a failed save does not leave the manifest pointing at a missing page.

An encrypted notebook keeps the same layout, with `keys.json` added and every other file stored as an encrypted `.nce` object. A locked section adds `sections/<id>.keys.json` and `sections/<id>.nce`, and its pages and images are encrypted under the section's own key. Only `keys.json` is readable without a passphrase.

## Build and run

Swift Package Manager is enough. Xcode is not required.

```bash
swift run CanvasApp
```

On first launch, create or open a notebook folder.

## Tests

`swift test` is not used. The checks are an executable:

```bash
swift run Checks
```

GitHub Actions runs these checks on every push and pull request to `main`.

To publish a build, tag a version and push the tag. The version must have three parts, such as `v1.2.0`. The release workflow rejects anything else.

```bash
git tag -a v1.2.0 -m "NoteCanvas v1.2.0" && git push origin v1.2.0
```

To try the app on invented notes, build a demo notebook and open it:

```bash
swift run DemoNotebook ~/Desktop/Demo
```

A real-file check runs only when `ONE_CORPUS_DIR` is set, and it prints aggregate counts only. Do not commit `.one` files, note text, or notebook backups. Those patterns are listed in `.gitignore`.

## Layout

| Target | Role |
|---|---|
| `PageModel` | Pages, objects, text operations, undo. No UI and no files. |
| `Store` | The notebook folder, including encryption and locked sections. |
| `OneStore` | Reader for the MS-ONESTORE container format. |
| `OneImport` | Maps a section file onto `PageModel` and writes the loss report. |
| `CanvasKit` | The AppKit canvas, sidebar, encryption prompts, and import flows. |
| `CanvasApp` | The app entry point. |
| `Checks` | The test harness (`swift run Checks`). |
| `DemoNotebook` | Writes a notebook of invented notes, for screenshots and trying the app. |

The container format follows Microsoft's [MS-ONESTORE](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-onestore/) and [MS-ONE](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-one/) specifications. OneNote may still display an imported page differently where the specification does not define a property.

## License

[MIT](LICENSE).
