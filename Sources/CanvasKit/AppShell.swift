import AppKit
import OneImport
import OneStore
import PageModel
import Store
import UniformTypeIdentifiers

public final class AppShell: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var package: NotebookPackage?
    private var controller: PageController?
    private var pages: [PageRef] = []
    private var lastSaveError: Error?
    private var saveFailureReported = false     // one alert per run of failed saves; a successful save resets it
    private var isFlushing = false              // flush callers explain a failure themselves
    private var revertingSelection = false
    private var currentSection = 0
    private let sectionPopup = NSPopUpButton()
    private var importCancel: ImportCancelFlag?
    private var progressSheet: NSPanel?

    private let table = NSTableView()
    private let canvasScroll = NSScrollView()
    private let titleField = NSTextField()
    private let headingPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let colorWell = NSColorWell()

    public override init() { super.init() }

    // MARK: lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        promptForNotebook()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveOrDiscard("Quit") ? .terminateNow : .terminateCancel
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { saveOrDiscard("Close") }
    public func applicationWillTerminate(_ notification: Notification) { commitEditing(); _ = flushController() }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: notebook open / create

    private func promptForNotebook() {
        let alert = NSAlert()
        alert.messageText = "Open or create a notebook"
        alert.addButton(withTitle: "New Notebook…")
        alert.addButton(withTitle: "Open Notebook…")
        alert.addButton(withTitle: "Quit")
        switch alert.runModal() {
        case .alertFirstButtonReturn: newNotebook(nil)
        case .alertSecondButtonReturn: openNotebook(nil)
        default: NSApp.terminate(nil)
        }
    }

    @objc func newNotebook(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.notebook"
        guard panel.runModal() == .OK, let url = panel.url else { if package == nil { promptForNotebook() }; return }
        let fm = FileManager.default
        // NSSavePanel already asked about replacing, but only ever replace a notebook, never an arbitrary folder or file.
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: url.appendingPathComponent("notebook.json").path) {
            inform("“\(url.lastPathComponent)” is not a notebook",
                   "NoteCanvas only replaces an existing notebook. Choose another name or location.")
            if package == nil { promptForNotebook() }
            return
        }
        // Save and close the open page first, so no pending write can land in the folder being replaced.
        guard saveOrDiscard("Continue") else { return }
        if let open = package, open.url.standardizedFileURL == url.standardizedFileURL { closeNotebook() }
        do {
            // The store itself refuses to clobber, so clear first.
            if fm.fileExists(atPath: url.path) { try fm.trashItem(at: url, resultingItemURL: nil) }
            var pkg = try NotebookPackage.create(at: url, name: url.deletingPathExtension().lastPathComponent)
            _ = try pkg.addPage(title: "Untitled Page")
            use(pkg)
        } catch { show(error); if package == nil { promptForNotebook() } }
    }

    @objc func openNotebook(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { if package == nil { promptForNotebook() }; return }
        do {
            let pkg = try NotebookPackage.open(at: url)
            guard saveOrDiscard("Continue") else { return }
            use(pkg)
        } catch { show(error); if package == nil { promptForNotebook() } }
    }

    private func closeNotebook() {
        dropPage()
        package = nil
        currentSection = 0
        rebuildSectionPopup()
        table.deselectAll(nil)
        reloadPages()
        window.title = "NoteCanvas"
    }

    private func use(_ pkg: NotebookPackage) {
        commitEditing()
        _ = flushController()
        // Drop the old page's controller/view and selection so the selection change below always fires and loads once.
        dropPage()
        table.deselectAll(nil)
        package = pkg
        currentSection = 0
        rebuildSectionPopup()
        window.title = pkg.notebook.name
        reloadPages()
        if pages.isEmpty, var p = package {
            _ = try? p.addPage(title: "Untitled Page"); package = p; reloadPages()
        }
        if !pages.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func reloadPages() {
        let sections = package?.notebook.sections ?? []
        if !sections.indices.contains(currentSection) { currentSection = 0 }
        pages = sections.indices.contains(currentSection) ? sections[currentSection].pages : []
        table.reloadData()
    }

    /// The popup lists section names; duplicate names are allowed, so items are added to the menu directly.
    private func rebuildSectionPopup() {
        sectionPopup.removeAllItems()
        let names = package?.notebook.sections.map(\.name) ?? []
        for name in names { sectionPopup.menu?.addItem(NSMenuItem(title: name, action: nil, keyEquivalent: "")) }
        if names.indices.contains(currentSection) { sectionPopup.selectItem(at: currentSection) }
        sectionPopup.isEnabled = !names.isEmpty
    }

    @objc func pickSection(_ sender: Any?) {
        let index = sectionPopup.indexOfSelectedItem
        guard index >= 0, index != currentSection, saveOrDiscard("Continue") else { rebuildSectionPopup(); return }
        currentSection = index
        dropPage()
        table.deselectAll(nil)
        reloadPages()
        if !pages.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func showPage(_ id: UUID) {
        guard !revertingSelection, controller?.page.id != id else { return }
        commitEditing()
        if let current = controller, !flushController() {
            // Keep the unsaved page on screen (and its row selected) rather than dropping its edits.
            if let row = pages.firstIndex(where: { $0.id == current.page.id }) {
                revertingSelection = true
                table.selectRowIndexes([row], byExtendingSelection: false)
                revertingSelection = false
            }
            inform("This page could not be saved", "\(describe(lastSaveError))\n\nIt stays open so your changes are not lost. "
                   + "Fix the problem (for example, move the notebook back or free some disk space) and try again.")
            return
        }
        dropPage()                                   // a failed load must not leave the previous page on screen
        guard let pkg = package else { return }
        do {
            let page = try pkg.loadPage(id)
            let c = PageController(page: page, assets: { [weak self] name in self?.package?.loadAsset(name) })
            c.onPersist = { [weak self] page in self?.save(page) ?? false }
            c.storeAsset = { [weak self] data, ext in
                guard let self, let pkg = self.package else { return nil }
                do { return try pkg.addAsset(data: data, ext: ext) } catch { self.show(error); return nil }
            }
            controller = c
            canvasScroll.documentView = c.view
            c.view.frame.size = canvasScroll.contentSize
            titleField.stringValue = page.title
        } catch { show(error) }
    }

    private func dropPage() {
        controller = nil
        canvasScroll.documentView = nil
        titleField.stringValue = ""
    }

    /// Ends text or title editing so the change reaches the controller before anything is flushed or replaced.
    private func commitEditing() {
        guard let window else { return }
        if !window.makeFirstResponder(nil) { window.endEditing(for: nil) }
    }

    private func flushController() -> Bool {
        guard let c = controller else { return true }
        isFlushing = true
        defer { isFlushing = false }
        return c.flush()
    }

    /// Saves the open page before it goes away. If that fails the user chooses: cancel (keep the edits on screen)
    /// or go ahead and lose them. Returns true when it is safe to proceed.
    private func saveOrDiscard(_ verb: String) -> Bool {
        commitEditing()
        if flushController() { return true }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "This page could not be saved"
        a.informativeText = "\(describe(lastSaveError))\n\nIf you continue, your recent changes to this page will be lost."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "\(verb) and Lose Changes").hasDestructiveAction = true
        guard a.runModal() == .alertSecondButtonReturn else { return false }
        dropPage()
        return true
    }

    private func save(_ page: Page) -> Bool {
        do {
            try package?.savePage(page)
            lastSaveError = nil
            saveFailureReported = false
            window.title = package?.notebook.name ?? ""
            if let i = pages.firstIndex(where: { $0.id == page.id }), pages[i].title != page.title {
                pages[i].title = page.title
                table.reloadData(forRowIndexes: [i], columnIndexes: [0])
            }
            return true
        } catch {
            lastSaveError = error
            window.title = "⚠︎ SAVE FAILED: \(error)"
            if !isFlushing && !saveFailureReported {
                saveFailureReported = true
                inform("NoteCanvas could not save this page", "\(error)\n\nYour changes stay on screen and NoteCanvas keeps "
                       + "trying to save. Until a save succeeds, further failures are shown only in the window title.")
            }
            return false
        }
    }

    private func describe(_ error: Error?) -> String { error.map { "\($0)" } ?? "Unknown error." }

    private func inform(_ message: String, _ info: String) {
        let a = NSAlert(); a.alertStyle = .warning; a.messageText = message; a.informativeText = info; a.runModal()
    }

    private func show(_ error: Error) {
        let a = NSAlert(); a.messageText = "Something went wrong"; a.informativeText = "\(error)"; a.runModal()
    }

    // MARK: pages sidebar

    public func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: pages[row].title)
        cell.lineBreakMode = .byTruncatingTail
        cell.font = .systemFont(ofSize: 13)
        cell.textColor = .labelColor
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if pages.indices.contains(row) { showPage(pages[row].id) }
    }

    @objc func addPage(_ sender: Any?) {
        commitEditing()
        guard var pkg = package else { return }
        do { _ = try pkg.addPage(title: "Untitled Page", section: currentSection); package = pkg; reloadPages()
             table.selectRowIndexes([pages.count - 1], byExtendingSelection: false)
        } catch { show(error) }
    }

    @objc func removePage(_ sender: Any?) {
        commitEditing()
        guard var pkg = package, pages.indices.contains(table.selectedRow) else { return }
        let ref = pages[table.selectedRow]
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Delete “\(controller?.page.id == ref.id ? controller!.page.title : ref.title)”?"
        a.informativeText = "The page will be moved to the Trash."
        a.addButton(withTitle: "Cancel")                 // first button: the default, so Return does not delete
        a.addButton(withTitle: "Delete").hasDestructiveAction = true
        guard a.runModal() == .alertSecondButtonReturn else { return }
        do { try pkg.deletePage(id: ref.id) } catch { show(error); return }
        package = pkg
        if controller?.page.id == ref.id { dropPage() }   // no flush: the page is gone
        table.deselectAll(nil)
        reloadPages()
        if !pages.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    public func controlTextDidEndEditing(_ obj: Notification) { controller?.setTitle(titleField.stringValue) }

    // MARK: import

    @objc func importOne(_ sender: Any?) {
        guard package != nil else {
            inform("Open a notebook first", "Create or open a notebook, then choose File > Import .one…")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a OneNote section file (.one) to import as a new section"
        if let type = UTType(filenameExtension: "one") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard saveOrDiscard("Import") else { return }
        // Snapshot only after the flush. A title edit writes notebook.json, and the open panel's
        // run loop can land that autosave too. The importer later commits this snapshot plus the
        // new section; a copy taken before the flush would put the old title back.
        guard let pkg = package else { return }
        let cancel = ImportCancelFlag()
        importCancel = cancel
        beginProgressSheet(fileName: url.lastPathComponent)
        ImportRunner.run(file: url, into: pkg, cancel: cancel) { [weak self] outcome in
            self?.endProgressSheet()
            self?.finishImport(outcome)
        }
    }

    @objc func cancelImport(_ sender: Any?) { importCancel?.cancel() }

    private func beginProgressSheet(fileName: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Importing"
        let label = NSTextField(labelWithString: "Importing “\(fileName)”…")
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelImport(_:)))
        let stack = NSStackView(views: [label, bar, cancelButton])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        bar.widthAnchor.constraint(equalToConstant: 328).isActive = true
        panel.contentView = stack
        progressSheet = panel
        window.beginSheet(panel, completionHandler: nil)
    }

    private func endProgressSheet() {
        if let panel = progressSheet { window.endSheet(panel); panel.orderOut(nil) }
        progressSheet = nil
        importCancel = nil
    }

    private func finishImport(_ outcome: ImportOutcome) {
        if let error = outcome.error {
            inform("The file could not be imported", importMessage(error))
            return
        }
        if outcome.cancelled {
            inform("Import cancelled", "Nothing was added to the notebook.")
            return
        }
        guard let pkg = outcome.package, let section = outcome.section, let result = outcome.result else { return }
        package = pkg
        currentSection = pkg.notebook.sections.firstIndex { $0.id == section.id } ?? 0
        rebuildSectionPopup()
        dropPage()
        table.deselectAll(nil)
        reloadPages()
        if !pages.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        let a = NSAlert()
        a.messageText = "Imported “\(section.name)”"
        a.informativeText = importSummary(result.report)
        a.runModal()
    }

    private func importMessage(_ error: Error) -> String {
        switch error as? OneStoreError {
        case .some(.notAOneFile): return "This is not a OneNote section file (.one)."
        case .some(.unsupportedFileType): return "This kind of OneNote file (a notebook table of contents) is not supported."
        case .some(.unsupportedVersion): return "This file was written by a newer version of OneNote than this app can read."
        case .some(.truncated), .some(.corrupt): return "The file is damaged or incomplete, so nothing was imported.\n\n\(error)"
        case .none: return "\(error)"
        }
    }

    private func importSummary(_ r: ImportReport) -> String {
        var lines = ["Pages imported: \(r.pagesImported) of \(r.pagesTotal)" + (r.pagesFailed > 0 ? " (\(r.pagesFailed) could not be read)" : "")]
        for (key, label) in [("text", "text boxes"), ("image", "images"), ("table", "tables"), ("attachment", "attachments")] {
            if let n = r.objectsImported[key], n > 0 { lines.append("\(n) \(label)") }
        }
        let skipped = r.skippedObjectTypes.values.reduce(0, +)
        if skipped > 0 { lines.append("\(skipped) objects of types this version does not support were skipped.") }
        let simplified = r.approximations.values.reduce(0, +)
        if simplified > 0 { lines.append("\(simplified) details were simplified.") }
        lines.append("A report with these counts (no note content) is saved inside the notebook, in its imports folder.")
        return lines.joined(separator: "\n")
    }

    // MARK: format bar actions

    @objc func bold(_ s: Any?) { controller?.applyRun(.bold) }
    @objc func italic(_ s: Any?) { controller?.applyRun(.italic) }
    @objc func underline(_ s: Any?) { controller?.applyRun(.underline) }
    @objc func strike(_ s: Any?) { controller?.applyRun(.strike) }
    @objc func pickSize(_ s: Any?) { if let v = Double(sizePopup.titleOfSelectedItem ?? "") { controller?.applyRun(.size(v)) } }
    /// Converted to sRGB so a picked system swatch is never a catalog colour (the bridge ignores those as "default").
    @objc func pickColor(_ s: Any?) { controller?.applyRun(.color(colorWell.color.usingColorSpace(.sRGB) ?? colorWell.color)) }
    @objc func pickHeading(_ s: Any?) { let h = headingPopup.indexOfSelectedItem; controller?.applyParagraph { $0.heading = h } }
    @objc func bullet(_ s: Any?) { controller?.insertList(.bullet) }
    @objc func numbered(_ s: Any?) { controller?.insertList(.numbered) }
    @objc func insertImage(_ sender: Any?) {
        guard controller != nil else {
            inform("Open a page first", "Open a notebook page, then insert an image.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose an image to place on the page"
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        var images: [(data: Data, ext: String, pointSize: NSSize)] = []
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { continue }
            images.append((data, url.pathExtension, image.size))
        }
        controller?.addImages(images)
    }
    @objc func alignLeft(_ s: Any?) { controller?.applyParagraph { $0.alignment = .left } }
    @objc func alignCenter(_ s: Any?) { controller?.applyParagraph { $0.alignment = .center } }
    @objc func alignRight(_ s: Any?) { controller?.applyParagraph { $0.alignment = .right } }
    @objc func indentMore(_ s: Any?) { controller?.applyParagraph { $0.indent += 1 } }
    @objc func indentLess(_ s: Any?) { controller?.applyParagraph { $0.indent -= 1 } }

    // MARK: menu actions (object-level when no text is being edited)

    private var editingText: Bool { window?.firstResponder is NSTextView }

    @objc func undoAction(_ s: Any?) { controller?.undo() }
    @objc func redoAction(_ s: Any?) { controller?.redo() }
    @objc func copyAction(_ s: Any?) {
        if editingText { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: s) } else { controller?.copySelected() }
    }
    @objc func pasteAction(_ s: Any?) {
        let pasteboard = NSPasteboard.general
        if editingText, !PageController.clipboardHasCanvasContent(pasteboard) {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: s)
        } else {
            if PageController.clipboardHasCanvasContent(pasteboard) { commitEditing() }
            controller?.paste()
        }
    }
    @objc func deleteObject(_ s: Any?) { controller?.deleteSelected() }

    /// Backspace is Delete Object's key equivalent; never let it fire while a text view has focus (it would eat the keystroke).
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if importCancel != nil { return false }     // an import is running: no menu action may replace the notebook under it
        guard item.action == #selector(deleteObject(_:)) else { return true }
        guard controller?.hasSelectedObject == true else { return false }
        if NSApp.currentEvent?.type == .keyDown {
            let r = window?.firstResponder
            return !(r is NSTextView) && !(r is NSTableView)
        }
        return true
    }
    @objc func bringToFront(_ s: Any?) { controller?.bringToFront() }
    @objc func sendToBack(_ s: Any?) { controller?.sendToBack() }

    // MARK: UI construction

    /// Warm stationery colours. The sheet stays cream so typed text and images stay easy to read.
    private enum Palette {
        static let stone = NSColor(srgbRed: 0.90, green: 0.87, blue: 0.82, alpha: 1)
        static let paper = NSColor(srgbRed: 0.99, green: 0.975, blue: 0.955, alpha: 1)
        static let ink = NSColor(srgbRed: 0.24, green: 0.21, blue: 0.18, alpha: 1)
        static let bar = NSColor(srgbRed: 1, green: 0.99, blue: 0.97, alpha: 1)
        static let hairline = NSColor(srgbRed: 0.62, green: 0.55, blue: 0.46, alpha: 0.35)
    }

    /// A quiet symbol button. It must not take keyboard focus away from the text being edited.
    private func symbolButton(_ symbol: String, _ action: Selector, title: String = "", tip: String) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .recessed
        b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        b.title = title
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.contentTintColor = Palette.ink
        b.target = self
        b.action = action
        b.refusesFirstResponder = true
        b.toolTip = tip
        return b
    }

    private func barSeparator() -> NSView {
        let rule = NSBox()
        rule.boxType = .separator
        rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        rule.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return rule
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "NoteCanvas"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        window.backgroundColor = Palette.stone
        window.isReleasedWhenClosed = false          // the shell owns the window; closing it must not free it
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.delegate = self
        window.center()

        let glass = NSView()
        glass.wantsLayer = true
        glass.layer?.backgroundColor = Palette.stone.cgColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        let sideScroll = NSScrollView()
        sideScroll.documentView = table
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false
        sideScroll.borderType = .noBorder
        sideScroll.scrollerStyle = .overlay
        let add = symbolButton("plus", #selector(addPage(_:)), tip: "Add page")
        let remove = symbolButton("minus", #selector(removePage(_:)), tip: "Delete page")
        sectionPopup.target = self
        sectionPopup.action = #selector(pickSection(_:))
        sectionPopup.refusesFirstResponder = true
        sectionPopup.bezelStyle = .recessed
        sectionPopup.font = .systemFont(ofSize: 13, weight: .medium)
        let sideButtons = NSStackView(views: [add, remove])
        sideButtons.spacing = 2
        let side = NSStackView(views: [sectionPopup, sideScroll, sideButtons])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 6
        sectionPopup.widthAnchor.constraint(equalTo: side.widthAnchor).isActive = true
        side.widthAnchor.constraint(equalToConstant: 220).isActive = true

        headingPopup.addItems(withTitles: ["Body", "Heading 1", "Heading 2", "Heading 3"])
        headingPopup.target = self; headingPopup.action = #selector(pickHeading(_:)); headingPopup.refusesFirstResponder = true
        headingPopup.controlSize = .small
        headingPopup.font = .systemFont(ofSize: 12)
        sizePopup.addItems(withTitles: ["10", "12", "14", "18", "24", "32"])
        sizePopup.selectItem(withTitle: "14")
        sizePopup.target = self; sizePopup.action = #selector(pickSize(_:)); sizePopup.refusesFirstResponder = true
        sizePopup.controlSize = .small
        colorWell.color = Palette.ink
        colorWell.controlSize = .small
        colorWell.target = self; colorWell.action = #selector(pickColor(_:))

        let bar = NSStackView(views: [
            symbolButton("list.bullet", #selector(bullet(_:)), title: "Bullets", tip: "Insert a bullet list"),
            symbolButton("list.number", #selector(numbered(_:)), title: "Numbered", tip: "Insert a numbered list"),
            symbolButton("photo", #selector(insertImage(_:)), title: "Image", tip: "Insert an image"),
            barSeparator(),
            symbolButton("bold", #selector(bold(_:)), tip: "Bold"),
            symbolButton("italic", #selector(italic(_:)), tip: "Italic"),
            symbolButton("underline", #selector(underline(_:)), tip: "Underline"),
            symbolButton("strikethrough", #selector(strike(_:)), tip: "Strikethrough"),
            sizePopup, colorWell, headingPopup,
            barSeparator(),
            symbolButton("text.alignleft", #selector(alignLeft(_:)), tip: "Align left"),
            symbolButton("text.aligncenter", #selector(alignCenter(_:)), tip: "Center"),
            symbolButton("text.alignright", #selector(alignRight(_:)), tip: "Align right"),
            symbolButton("increase.indent", #selector(indentMore(_:)), tip: "Indent"),
            symbolButton("decrease.indent", #selector(indentLess(_:)), tip: "Outdent"),
        ])
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let barWell = NSView()
        barWell.wantsLayer = true
        barWell.layer?.backgroundColor = Palette.bar.cgColor
        barWell.layer?.cornerRadius = 12
        barWell.layer?.borderWidth = 1
        barWell.layer?.borderColor = Palette.hairline.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        barWell.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: barWell.topAnchor),
            bar.leadingAnchor.constraint(equalTo: barWell.leadingAnchor),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: barWell.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: barWell.bottomAnchor),
        ])

        titleField.placeholderString = "Page title"
        titleField.font = .systemFont(ofSize: 22, weight: .semibold)
        titleField.isBezeled = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.delegate = self
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.drawsBackground = false
        canvasScroll.borderType = .noBorder
        canvasScroll.scrollerStyle = .overlay

        let paperStack = NSStackView(views: [titleField, canvasScroll])
        paperStack.orientation = .vertical
        paperStack.alignment = .leading
        paperStack.spacing = 6
        paperStack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 12)
        let titleWidth = titleField.widthAnchor.constraint(equalTo: paperStack.widthAnchor, constant: -30)
        let canvasWidth = canvasScroll.widthAnchor.constraint(equalTo: paperStack.widthAnchor, constant: -30)
        titleWidth.priority = NSLayoutConstraint.Priority(999)
        canvasWidth.priority = NSLayoutConstraint.Priority(999)
        titleWidth.isActive = true
        canvasWidth.isActive = true
        canvasScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        canvasScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        canvasScroll.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        canvasScroll.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)

        let paper = NSView()
        paper.wantsLayer = true
        paper.appearance = NSAppearance(named: .aqua)   // the sheet stays light so text and images stay readable
        paper.layer?.backgroundColor = Palette.paper.cgColor
        paper.layer?.cornerRadius = 16
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.35, green: 0.28, blue: 0.20, alpha: 0.18)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 18
        paper.shadow = shadow
        paperStack.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(paperStack)
        NSLayoutConstraint.activate([
            paperStack.topAnchor.constraint(equalTo: paper.topAnchor),
            paperStack.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            paperStack.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            paperStack.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
        ])

        let right = NSStackView(views: [barWell, paper])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        paper.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        paper.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        paper.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let paperWidth = paper.widthAnchor.constraint(equalTo: right.widthAnchor)
        paperWidth.priority = NSLayoutConstraint.Priority(999)
        paperWidth.isActive = true
        let barWidth = barWell.widthAnchor.constraint(equalTo: right.widthAnchor)
        barWidth.priority = NSLayoutConstraint.Priority(999)
        barWidth.isActive = true

        let root = NSStackView(views: [side, right])
        root.orientation = .horizontal
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        side.setContentHuggingPriority(.required, for: .horizontal)
        side.setContentCompressionResistancePriority(.required, for: .horizontal)
        right.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        right.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        side.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        // Sidebar is 220 wide and the gap is 14; the sheet takes every remaining point as the window changes size.
        let rightWidth = right.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -234)
        rightWidth.priority = NSLayoutConstraint.Priority(999)
        rightWidth.isActive = true
        glass.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: glass.safeAreaLayoutGuide.topAnchor, constant: 6),
            root.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -12),
            root.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -12),
        ])
        window.contentView = glass
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        /// `firstResponder` items have no target, so the focused view (e.g. a text view) handles them.
        func item(_ title: String, _ action: Selector?, _ key: String = "", mods: NSEvent.ModifierFlags = .command,
                  firstResponder: Bool = false, in menu: NSMenu) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if action != nil, action != #selector(NSApplication.terminate(_:)), !firstResponder { i.target = self }
            menu.addItem(i)
        }
        func submenu(_ title: String) -> NSMenu {
            let holder = NSMenuItem(); main.addItem(holder)
            let m = NSMenu(title: title); holder.submenu = m; return m
        }
        let app = submenu("NoteCanvas")
        item("Quit NoteCanvas", #selector(NSApplication.terminate(_:)), "q", in: app)
        let file = submenu("File")
        item("New Notebook…", #selector(newNotebook(_:)), "n", in: file)
        item("Open Notebook…", #selector(openNotebook(_:)), "o", in: file)
        item("New Page", #selector(addPage(_:)), "t", in: file)
        item("Import .one…", #selector(importOne(_:)), "i", in: file)
        let insert = submenu("Insert")
        item("Bullet List", #selector(bullet(_:)), in: insert)
        item("Numbered List", #selector(numbered(_:)), in: insert)
        item("Image…", #selector(insertImage(_:)), in: insert)
        let edit = submenu("Edit")
        item("Undo", #selector(undoAction(_:)), "z", in: edit)
        item("Redo", #selector(redoAction(_:)), "z", mods: [.command, .shift], in: edit)
        edit.addItem(.separator())
        item("Cut", #selector(NSText.cut(_:)), "x", firstResponder: true, in: edit)
        item("Copy", #selector(copyAction(_:)), "c", in: edit)
        item("Paste", #selector(pasteAction(_:)), "v", in: edit)
        item("Select All", #selector(NSText.selectAll(_:)), "a", firstResponder: true, in: edit)
        item("Delete Object", #selector(deleteObject(_:)), "\u{7f}", mods: [], in: edit)
        let arrange = submenu("Arrange")
        item("Bring to Front", #selector(bringToFront(_:)), "]", in: arrange)
        item("Send to Back", #selector(sendToBack(_:)), "[", in: arrange)
        NSApp.mainMenu = main
    }
}
