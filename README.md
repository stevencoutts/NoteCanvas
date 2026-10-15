# NoteCanvas

A native macOS app for free-form notes. Pages are a canvas of positioned text boxes, images, tables, and attachments. Notebooks are ordinary folders on disk. A OneNote section file (`.one`) can be imported into a new section. The app does not sync, and it does not write `.one` files.

Requires macOS 14 or later. The interface is AppKit. There are no third-party dependencies.

## What you can do

- Place, move, resize, and format text boxes. Undo and redo cover those edits.
- Organise notes as sections, folders and pages in a sidebar tree. Every section and folder folds away. Add, rename and delete sections from the sidebar buttons, the File menu, or a right-click.
- Insert bullet and numbered lists, and insert images from disk or the clipboard.
- Draw imported images, tables, and attachments. Move, copy, and delete them. Editing tools for tables and ink are not in this version.
- Import a `.one` section with **File > Import .one…**. The import runs in the background and can be cancelled. The source file is only read. A failed or cancelled import does not add a section.

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

To publish a build, tag a version and push the tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

A real-file check runs only when `ONE_CORPUS_DIR` is set, and it prints aggregate counts only. Do not commit `.one` files, note text, or notebook backups. Those patterns are listed in `.gitignore`.

## Layout

| Target | Role |
|---|---|
| `PageModel` | Pages, objects, text operations, undo. No UI and no files. |
| `Store` | The notebook folder. |
| `OneStore` | Reader for the MS-ONESTORE container format. |
| `OneImport` | Maps a section file onto `PageModel` and writes the loss report. |
| `CanvasKit` | The AppKit canvas, section list, and import flow. |
| `CanvasApp` | The app entry point. |

The container format follows Microsoft's [MS-ONESTORE](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-onestore/) and [MS-ONE](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-one/) specifications. OneNote may still display an imported page differently where the specification does not define a property.

## License

[MIT](LICENSE).
