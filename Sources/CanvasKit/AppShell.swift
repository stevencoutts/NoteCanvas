import AppKit
import PageModel
import Store

public final class AppShell: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var package: NotebookPackage?
    private var controller: PageController?
    private var pages: [PageRef] = []

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

    public func applicationWillTerminate(_ notification: Notification) { controller?.flush() }
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
        do {
            // NSSavePanel already asked about replacing; the store itself refuses to clobber, so clear first.
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
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
        do { use(try NotebookPackage.open(at: url)) } catch { show(error); if package == nil { promptForNotebook() } }
    }

    private func use(_ pkg: NotebookPackage) {
        controller?.flush()
        // Drop the old page's controller/view and selection so the selection change below always fires and loads once.
        controller = nil
        canvasScroll.documentView = nil
        table.deselectAll(nil)
        package = pkg
        window.title = pkg.notebook.name
        reloadPages()
        if pages.isEmpty, var p = package {
            _ = try? p.addPage(title: "Untitled Page"); package = p; reloadPages()
        }
        if !pages.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func reloadPages() {
        pages = package?.notebook.sections.first?.pages ?? []
        table.reloadData()
    }

    private func showPage(_ id: UUID) {
        controller?.flush()
        guard let pkg = package else { return }
        do {
            let page = try pkg.loadPage(id)
            let c = PageController(page: page)
            c.onPersist = { [weak self] page in self?.save(page) }
            controller = c
            canvasScroll.documentView = c.view
            c.view.frame.size = canvasScroll.contentSize
            titleField.stringValue = page.title
        } catch { show(error) }
    }

    private func save(_ page: Page) {
        do {
            try package?.savePage(page)
            window.title = package?.notebook.name ?? ""
            if let i = pages.firstIndex(where: { $0.id == page.id }), pages[i].title != page.title {
                pages[i].title = page.title
                table.reloadData(forRowIndexes: [i], columnIndexes: [0])
            }
        } catch { window.title = "⚠︎ SAVE FAILED: \(error)" }
    }

    private func show(_ error: Error) {
        let a = NSAlert(); a.messageText = "Something went wrong"; a.informativeText = "\(error)"; a.runModal()
    }

    // MARK: pages sidebar

    public func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: pages[row].title)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if pages.indices.contains(row) { showPage(pages[row].id) }
    }

    @objc func addPage(_ sender: Any?) {
        guard var pkg = package else { return }
        do { _ = try pkg.addPage(title: "Untitled Page"); package = pkg; reloadPages()
             table.selectRowIndexes([pages.count - 1], byExtendingSelection: false)
        } catch { show(error) }
    }

    @objc func removePage(_ sender: Any?) {
        guard var pkg = package, pages.indices.contains(table.selectedRow) else { return }
        let id = pages[table.selectedRow].id
        controller = nil
        canvasScroll.documentView = nil
        titleField.stringValue = ""
        table.deselectAll(nil)
        do { try pkg.deletePage(id: id); package = pkg; reloadPages()
             if !pages.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) } else { canvasScroll.documentView = nil }
        } catch { show(error) }
    }

    public func controlTextDidEndEditing(_ obj: Notification) { controller?.setTitle(titleField.stringValue) }

    // MARK: format bar actions

    @objc func bold(_ s: Any?) { controller?.applyRun(.bold) }
    @objc func italic(_ s: Any?) { controller?.applyRun(.italic) }
    @objc func underline(_ s: Any?) { controller?.applyRun(.underline) }
    @objc func strike(_ s: Any?) { controller?.applyRun(.strike) }
    @objc func pickSize(_ s: Any?) { if let v = Double(sizePopup.titleOfSelectedItem ?? "") { controller?.applyRun(.size(v)) } }
    @objc func pickColor(_ s: Any?) { controller?.applyRun(.color(colorWell.color)) }
    @objc func pickHeading(_ s: Any?) { let h = headingPopup.indexOfSelectedItem; controller?.applyParagraph { $0.heading = h } }
    @objc func bullet(_ s: Any?) { controller?.applyParagraph { $0.list = ($0.list == .bullet ? .none : .bullet) } }
    @objc func numbered(_ s: Any?) { controller?.applyParagraph { $0.list = ($0.list == .numbered ? .none : .numbered) } }
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
        if editingText { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: s) } else { controller?.paste() }
    }
    @objc func deleteObject(_ s: Any?) { controller?.deleteSelected() }

    /// Backspace is Delete Object's key equivalent; never let it fire while a text view has focus (it would eat the keystroke).
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
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

    private func button(_ title: String, _ action: Selector, tip: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.refusesFirstResponder = true         // clicking must not steal focus from the text view
        b.toolTip = tip
        return b
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "NoteCanvas"
        window.center()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        let sideScroll = NSScrollView()
        sideScroll.documentView = table
        sideScroll.hasVerticalScroller = true
        let add = button("+", #selector(addPage(_:)), tip: "Add page")
        let remove = button("−", #selector(removePage(_:)), tip: "Delete page")
        let sideButtons = NSStackView(views: [add, remove])
        let side = NSStackView(views: [sideScroll, sideButtons])
        side.orientation = .vertical
        side.alignment = .leading
        side.widthAnchor.constraint(equalToConstant: 200).isActive = true

        headingPopup.addItems(withTitles: ["Body", "Heading 1", "Heading 2", "Heading 3"])
        headingPopup.target = self; headingPopup.action = #selector(pickHeading(_:)); headingPopup.refusesFirstResponder = true
        sizePopup.addItems(withTitles: ["10", "12", "14", "18", "24", "32"])
        sizePopup.selectItem(withTitle: "14")
        sizePopup.target = self; sizePopup.action = #selector(pickSize(_:)); sizePopup.refusesFirstResponder = true
        colorWell.color = .black
        colorWell.target = self; colorWell.action = #selector(pickColor(_:))

        let bar = NSStackView(views: [
            button("B", #selector(bold(_:)), tip: "Bold"), button("I", #selector(italic(_:)), tip: "Italic"),
            button("U", #selector(underline(_:)), tip: "Underline"), button("S", #selector(strike(_:)), tip: "Strikethrough"),
            sizePopup, colorWell, headingPopup,
            button("•", #selector(bullet(_:)), tip: "Bullets"), button("1.", #selector(numbered(_:)), tip: "Numbering"),
            button("⇤", #selector(alignLeft(_:)), tip: "Align left"), button("↔︎", #selector(alignCenter(_:)), tip: "Center"),
            button("⇥", #selector(alignRight(_:)), tip: "Align right"),
            button("→", #selector(indentMore(_:)), tip: "Indent"), button("←", #selector(indentLess(_:)), tip: "Outdent"),
        ])
        bar.spacing = 6

        titleField.placeholderString = "Page title"
        titleField.font = .systemFont(ofSize: 20, weight: .semibold)
        titleField.delegate = self
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true

        let right = NSStackView(views: [bar, titleField, canvasScroll])
        right.orientation = .vertical
        right.alignment = .leading
        titleField.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        canvasScroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        canvasScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let root = NSStackView(views: [side, right])
        root.orientation = .horizontal
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", mods: NSEvent.ModifierFlags = .command, in menu: NSMenu) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if action != nil, action != #selector(NSApplication.terminate(_:)) { i.target = self }
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
        let edit = submenu("Edit")
        item("Undo", #selector(undoAction(_:)), "z", in: edit)
        item("Redo", #selector(redoAction(_:)), "z", mods: [.command, .shift], in: edit)
        edit.addItem(.separator())
        item("Copy", #selector(copyAction(_:)), "c", in: edit)
        item("Paste", #selector(pasteAction(_:)), "v", in: edit)
        item("Delete Object", #selector(deleteObject(_:)), "\u{7f}", mods: [], in: edit)
        let arrange = submenu("Arrange")
        item("Bring to Front", #selector(bringToFront(_:)), "]", in: arrange)
        item("Send to Back", #selector(sendToBack(_:)), "[", in: arrange)
        NSApp.mainMenu = main
    }
}
