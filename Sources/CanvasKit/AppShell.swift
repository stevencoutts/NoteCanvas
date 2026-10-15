import AppKit
import CryptoKit
import OneImport
import OneStore
import PageModel
import Store
import UniformTypeIdentifiers

private final class SidebarRow: NSObject {
    let id: UUID
    init(id: UUID) { self.id = id; super.init() }
}

/// One sidebar row. A folder draws a mark and its title in the folder colour; a page title uses its own colour, or ink when it has none.
private final class NavCell: NSTableCellView {
    let mark = NSImageView()
    let title = NSTextField(labelWithString: "")
    private let titleLead: NSLayoutConstraint
    var titleColor: NSColor = .labelColor { didSet { title.textColor = titleColor } }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { title.textColor = titleColor }
    }

    init() {
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.imageScaling = .scaleProportionallyDown
        mark.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.drawsBackground = false
        title.isBordered = false
        title.isBezeled = false
        title.focusRingType = .none
        (title.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        titleLead = title.leadingAnchor.constraint(equalTo: mark.leadingAnchor)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("nav")
        addSubview(mark)
        addSubview(title)
        textField = title
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 18),
            mark.heightAnchor.constraint(equalToConstant: 18),
            titleLead,
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showMark(_ show: Bool, tint: NSColor, symbol: String = "folder.fill") {
        mark.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        mark.isHidden = !show
        mark.contentTintColor = tint
        titleLead.constant = show ? 22 : 0
    }
}

/// Escape closes the panel. A panel does not become main, so dismissing it leaves the notebook window in place.
private final class AboutPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

/// First responder for the About panel so Escape is handled when the content view is key.
private final class AboutKeyView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { window?.close() }
}

public final class AppShell: NSObject, NSApplicationDelegate, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var window: NSWindow!
    private var aboutWindow: NSPanel?
    private var package: NotebookPackage?
    private var controller: PageController?
    private var pages: [PageRef] = []
    private var lastSaveError: Error?
    private var saveFailureReported = false     // one alert per run of failed saves; a successful save resets it
    private var isFlushing = false              // flush callers explain a failure themselves
    private var revertingSelection = false
    private var currentSection = 0
    private var notebookBookmark: Data?        // follows the notebook folder if it is moved while open
    private var collapsed = Set<UUID>()         // sections and folders the user has folded away
    private var importCancel: ImportCancelFlag?
    private var progressSheet: NSPanel?

    private let outline = NSOutlineView()
    private var navRows: [UUID: SidebarRow] = [:]
    private let navType = NSPasteboard.PasteboardType("com.notecanvas.nav")
    private let canvasScroll = NSScrollView()
    private let titleField = NSTextField()
    private let headingPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let colorWell = NSColorWell()

    /// Stationery colours for a folder or a page. Default clears the colour so the title stays ink.
    private struct FolderSwatch { var name: String; var hex: String? }
    private static let folderSwatches: [FolderSwatch] = [
        FolderSwatch(name: "Red", hex: "#A33B32"),
        FolderSwatch(name: "Orange", hex: "#C4622D"),
        FolderSwatch(name: "Gold", hex: "#8F7020"),
        FolderSwatch(name: "Green", hex: "#3D7048"),
        FolderSwatch(name: "Teal", hex: "#2A6E68"),
        FolderSwatch(name: "Blue", hex: "#34547E"),
        FolderSwatch(name: "Purple", hex: "#684674"),
        FolderSwatch(name: "Default", hex: nil),
    ]

    public override init() { super.init() }

    // MARK: lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        if let pkg = LastNotebook.reopen() {
            use(pkg)
        } else if let url = LastNotebook.rememberedURL(), NotebookPackage.isEncrypted(at: url), let pkg = unlockNotebook(at: url) {
            use(pkg)
        } else {
            promptForNotebook()
        }
        // The window is up. The check itself waits on the network off the main thread.
        DispatchQueue.main.async { AppUpdate.check(interactive: false) }
    }

    @objc func checkForUpdates(_ sender: Any?) { AppUpdate.check(interactive: true) }

    /// A small stationery panel. `orderFrontStandardAboutPanel` is empty under `swift run`, which has no bundle credits.
    @objc func showAbout(_ sender: Any?) {
        let panel = aboutWindow ?? makeAboutWindow()
        aboutWindow = panel
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveOrDiscard("Quit") ? .terminateNow : .terminateCancel
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard saveOrDiscard("Close") else { return false }
        aboutWindow?.close()
        return true
    }
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
        let encryptBox = NSButton(checkboxWithTitle: "Encrypt this notebook with a passphrase", target: nil, action: nil)
        encryptBox.state = .on
        panel.accessoryView = encryptBox
        guard panel.runModal() == .OK, let url = panel.url else { if package == nil { promptForNotebook() }; return }
        let fm = FileManager.default
        // NSSavePanel already asked about replacing, but only ever replace a notebook, never an arbitrary folder or file.
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: url.appendingPathComponent("notebook.json").path),
           !fm.fileExists(atPath: url.appendingPathComponent("keys.json").path) {
            inform("“\(url.lastPathComponent)” is not a notebook",
                   "NoteCanvas only replaces an existing notebook. Choose another name or location.")
            if package == nil { promptForNotebook() }
            return
        }
        var secret: (passphrase: String, remember: Bool)?
        if encryptBox.state == .on {
            secret = askNewPassphrase(title: "Choose a passphrase",
                                      message: "Everything in the notebook is encrypted with it. If you forget it, the recovery key shown next is the only way back in.",
                                      offerRemember: true)
            if secret == nil { if package == nil { promptForNotebook() }; return }
        }
        // Save and close the open page first, so no pending write can land in the folder being replaced.
        guard saveOrDiscard("Continue") else { return }
        if let open = package, open.url.standardizedFileURL == url.standardizedFileURL { closeNotebook() }
        do {
            // The store itself refuses to clobber, so clear first.
            if fm.fileExists(atPath: url.path) { try fm.trashItem(at: url, resultingItemURL: nil) }
            let name = url.deletingPathExtension().lastPathComponent
            var recovery: String?
            var pkg: NotebookPackage
            if let secret {
                let made = try NotebookPackage.createEncrypted(at: url, name: name, passphrase: secret.passphrase)
                pkg = made.package
                recovery = made.recoveryKey
                if secret.remember, let cipher = pkg.cipher { NotebookKeychain.save(cipher.key, notebookID: cipher.notebookID.uuidString) }
            } else {
                pkg = try NotebookPackage.create(at: url, name: name)
            }
            _ = try pkg.addPage(title: "Untitled Page")
            use(pkg)
            if let recovery { showRecoveryKey(recovery) }
        } catch { show(error); if package == nil { promptForNotebook() } }
    }

    @objc func openNotebook(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { if package == nil { promptForNotebook() }; return }
        do {
            let pkg: NotebookPackage
            if NotebookPackage.isEncrypted(at: url) {
                guard let unlocked = unlockNotebook(at: url) else { if package == nil { promptForNotebook() }; return }
                pkg = unlocked
            } else {
                pkg = try NotebookPackage.open(at: url)
            }
            guard saveOrDiscard("Continue") else { return }
            use(pkg)
        } catch { show(error); if package == nil { promptForNotebook() } }
    }

    private func closeNotebook() {
        LastNotebook.forget()
        notebookBookmark = nil
        dropPage()
        package = nil
        currentSection = 0
        outline.deselectAll(nil)
        reloadPages()
        window.title = "NoteCanvas"
    }

    private func use(_ pkg: NotebookPackage) {
        commitEditing()
        _ = flushController()
        // Drop the old page's controller/view and selection so the selection change below always fires and loads once.
        dropPage()
        outline.deselectAll(nil)
        package = pkg
        LastNotebook.remember(pkg.url)
        notebookBookmark = try? pkg.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        currentSection = 0
        collapsed = []
        window.title = pkg.notebook.name
        reloadPages()
        if pages.isEmpty, var p = package {
            _ = try? p.addPage(title: "Untitled Page"); package = p; reloadPages()
        }
        if let first = pages.first { selectNav(first.id) }
        if pkg.isEncrypted, !pkg.plaintextLeftovers().isEmpty {
            DispatchQueue.main.async { [weak self] in self?.offerToTrashPlaintext(pkg) }
        }
    }

    private func reloadPages() {
        let sections = package?.notebook.sections ?? []
        if !sections.indices.contains(currentSection) { currentSection = 0 }
        pages = sections.indices.contains(currentSection) ? sections[currentSection].pages : []
        let live = Set(sections.flatMap { [$0.id] + $0.items.flatMap { Self.itemIDs($0) } })
        navRows = navRows.filter { live.contains($0.key) }
        collapsed = collapsed.filter { live.contains($0) }
        outline.reloadData()
        for section in sections {
            expandUnlessCollapsed(section.id)
            expandFolders(in: section.items)
        }
    }

    private func expandUnlessCollapsed(_ id: UUID) {
        if !collapsed.contains(id) { outline.expandItem(navRow(id)) }
    }

    private func expandFolders(in items: [NotebookItem]) {
        for item in items {
            if case .folder(let folder) = item {
                expandUnlessCollapsed(folder.id)
                expandFolders(in: folder.children)
            }
        }
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? SidebarRow { collapsed.insert(row.id) }
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? SidebarRow { collapsed.remove(row.id) }
    }

    /// The index of the section that is, or holds, the row with this id.
    private func sectionIndex(of id: UUID) -> Int? {
        (package?.notebook.sections ?? []).firstIndex {
            $0.id == id || $0.folder(id) != nil || $0.pages.contains { $0.id == id }
        }
    }

    private func isSectionRow(_ id: UUID) -> Bool {
        package?.notebook.sections.contains { $0.id == id } ?? false
    }

    /// Makes the section at `index` the one new pages and folders go into.
    private func focusSection(_ index: Int) {
        guard let sections = package?.notebook.sections, sections.indices.contains(index) else { return }
        currentSection = index
        pages = sections[index].pages
    }

    private func showPage(_ id: UUID) {
        guard !revertingSelection, controller?.page.id != id else { return }
        commitEditing()
        if let current = controller, !flushController() {
            // Keep the unsaved page on screen (and its row selected) rather than dropping its edits.
            revertingSelection = true
            selectNav(current.page.id)
            revertingSelection = false
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

    /// If the notebook folder was moved or renamed while it was open (in Finder, or by a sync client), follow it.
    /// Uses the bookmark taken when the notebook was opened, which tracks a move on the same volume.
    private func relocateIfMoved() {
        guard let pkg = package, !FileManager.default.fileExists(atPath: pkg.url.path), let data = notebookBookmark else { return }
        var stale = false
        guard let moved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                   relativeTo: nil, bookmarkDataIsStale: &stale),
              moved.standardizedFileURL != pkg.url.standardizedFileURL,
              FileManager.default.fileExists(atPath: moved.path) else { return }
        package?.relocate(to: moved)
        LastNotebook.remember(moved)
        notebookBookmark = try? moved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func applicationDidBecomeActive(_ notification: Notification) { relocateIfMoved() }

    private func save(_ page: Page) -> Bool {
        relocateIfMoved()
        do {
            try package?.savePage(page)
            lastSaveError = nil
            saveFailureReported = false
            window.title = package?.notebook.name ?? ""
            if let i = pages.firstIndex(where: { $0.id == page.id }), pages[i].title != page.title {
                pages[i].title = page.title
                if let row = navRows[page.id] { outline.reloadItem(row) }
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

    // MARK: encryption

    private func secureField(_ placeholder: String, plain: Bool = false) -> NSTextField {
        let field: NSTextField = plain ? NSTextField() : NSSecureTextField()
        field.placeholderString = placeholder
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return field
    }

    private func accessory(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(stack.fittingSize)
        return stack
    }

    /// Opens an encrypted notebook: a key remembered in the keychain first, then the passphrase or recovery key.
    private func unlockNotebook(at url: URL) -> NotebookPackage? {
        guard let keys = try? NotebookPackage.keysFile(at: url) else { show(StoreError.notAPackage); return nil }
        if let cached = NotebookKeychain.load(notebookID: keys.notebookId),
           let pkg = try? NotebookPackage.open(at: url, notebookKey: cached) { return pkg }
        var message = "Enter the passphrase for “\(url.deletingPathExtension().lastPathComponent)”."
        var useRecovery = false
        while true {
            let alert = NSAlert()
            alert.messageText = useRecovery ? "Enter the recovery key" : "Unlock notebook"
            alert.informativeText = message
            let field = secureField(useRecovery ? "Recovery key" : "Passphrase", plain: useRecovery)
            let remember = NSButton(checkboxWithTitle: "Remember on this Mac", target: nil, action: nil)
            remember.state = .on
            alert.accessoryView = accessory([field, remember])
            alert.addButton(withTitle: "Unlock")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: useRecovery ? "Use Passphrase" : "Use Recovery Key…")
            alert.window.initialFirstResponder = field
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    let key: SymmetricKey
                    if useRecovery {
                        key = try NotebookCrypto.unlock(keys, recoveryKey: field.stringValue)
                    } else {
                        key = try NotebookCrypto.unlock(keys, passphrase: field.stringValue)
                    }
                    let pkg = try NotebookPackage.open(at: url, notebookKey: key)
                    if remember.state == .on { NotebookKeychain.save(key, notebookID: keys.notebookId) }
                    return pkg
                } catch CryptoError.noMatchingSlot {
                    message = useRecovery ? "That recovery key did not unlock the notebook." : "That passphrase did not unlock the notebook. Try again."
                } catch CryptoError.badRecoveryKey {
                    message = "That recovery key is not valid. Check it for typing mistakes."
                } catch {
                    show(error)
                    return nil
                }
            case .alertThirdButtonReturn:
                useRecovery.toggle()
                message = useRecovery ? "Type the recovery key you saved when the notebook was created." : "Enter the passphrase for “\(url.deletingPathExtension().lastPathComponent)”."
            default:
                return nil
            }
        }
    }

    private func askNewPassphrase(title: String, message: String, offerRemember: Bool) -> (passphrase: String, remember: Bool)? {
        var note = message
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = note
            let first = secureField("Passphrase")
            let second = secureField("Repeat passphrase")
            let remember = NSButton(checkboxWithTitle: "Remember on this Mac", target: nil, action: nil)
            remember.state = .on
            alert.accessoryView = accessory(offerRemember ? [first, second, remember] : [first, second])
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = first
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if first.stringValue != second.stringValue { note = "The two passphrases do not match. Try again."; continue }
            if first.stringValue.count < NotebookCrypto.minimumPassphraseLength {
                note = "Use at least \(NotebookCrypto.minimumPassphraseLength) characters. Several random words work well."
                continue
            }
            return (first.stringValue, offerRemember && remember.state == .on)
        }
    }

    private func showRecoveryKey(_ key: String) {
        while true {
            let alert = NSAlert()
            alert.messageText = "Save your recovery key"
            alert.informativeText = "If you forget the passphrase, this key is the only way to open the notebook. NoteCanvas cannot recover it for you, and it will not be shown again. Keep it somewhere safe, such as a password manager."
            let field = NSTextField(wrappingLabelWithString: key)
            field.isSelectable = true
            field.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            field.preferredMaxLayoutWidth = 320
            alert.accessoryView = accessory([field])
            alert.addButton(withTitle: "I Have Saved It")
            alert.addButton(withTitle: "Copy Key")
            if alert.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
                continue
            }
            return
        }
    }

    private func offerToTrashPlaintext(_ pkg: NotebookPackage) {
        guard !pkg.plaintextLeftovers().isEmpty else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Move the unencrypted copies to the Trash?"
        a.informativeText = "The encrypted notebook is in use. The old unencrypted files are still on disk until you remove them. "
            + "Emptying the Trash does not reach copies in Time Machine backups or in your cloud storage's version history."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Keep Them")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try pkg.trashPlaintextLeftovers() } catch { show(error) }
    }

    @objc func encryptNotebook(_ sender: Any?) {
        guard let current = package, !current.isEncrypted else { return }
        commitEditing()
        guard flushController() else {
            inform("This page could not be saved", "Fix the problem, then try encrypting again.")
            return
        }
        guard let secret = askNewPassphrase(
            title: "Encrypt this notebook",
            message: "Everything in “\(current.notebook.name)” is encrypted with this passphrase. If you forget it, the recovery key shown next is the only way back in.",
            offerRemember: true) else { return }
        guard var pkg = package else { return }
        do {
            let recovery = try pkg.encrypt(passphrase: secret.passphrase)
            package = pkg
            if secret.remember, let cipher = pkg.cipher { NotebookKeychain.save(cipher.key, notebookID: cipher.notebookID.uuidString) }
            showRecoveryKey(recovery)
            offerToTrashPlaintext(pkg)
        } catch { show(error) }
    }

    @objc func changePassphrase(_ sender: Any?) {
        guard let pkg = package, pkg.isEncrypted else { return }
        guard let secret = askNewPassphrase(
            title: "Change passphrase",
            message: "The notebook is not re-encrypted. The recovery key stays the same.",
            offerRemember: false) else { return }
        do { try pkg.changePassphrase(to: secret.passphrase) } catch { show(error) }
    }

    // MARK: pages sidebar

    private func currentSectionModel() -> Section? {
        guard let sections = package?.notebook.sections, sections.indices.contains(currentSection) else { return nil }
        return sections[currentSection]
    }

    private func currentItems() -> [NotebookItem] { currentSectionModel()?.items ?? [] }

    private func navRow(_ id: UUID) -> SidebarRow {
        if let row = navRows[id] { return row }
        let row = SidebarRow(id: id)
        navRows[id] = row
        return row
    }

    private func children(of item: Any?) -> [NotebookItem] {
        guard let row = item as? SidebarRow, let sections = package?.notebook.sections else { return [] }
        if let section = sections.first(where: { $0.id == row.id }) { return section.items }
        for section in sections { if let folder = section.folder(row.id) { return folder.children } }
        return []
    }

    private func selectedID() -> UUID? { (outline.item(atRow: outline.selectedRow) as? SidebarRow)?.id }

    /// A selected folder, or the folder that holds the selected page.
    private func destinationFolder() -> UUID? {
        guard let id = selectedID(), let section = currentSectionModel() else { return nil }
        if section.folder(id) != nil { return id }
        return section.parent(of: id)
    }

    private func selectNav(_ id: UUID) {
        revealNav(id)
        let row = outline.row(forItem: navRow(id))
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
    }

    /// Unfolds the section and folders above a row so it can be selected.
    private func revealNav(_ id: UUID) {
        guard let index = sectionIndex(of: id), let sections = package?.notebook.sections else { return }
        let section = sections[index]
        var chain: [UUID] = []
        var cursor = section.parent(of: id)
        while let current = cursor { chain.insert(current, at: 0); cursor = section.parent(of: current) }
        for ancestor in [section.id] + chain where ancestor != id { outline.expandItem(navRow(ancestor)) }
    }

    private static func itemIDs(_ item: NotebookItem) -> [UUID] {
        switch item {
        case .page: return [item.id]
        case .folder(let folder): return [folder.id] + folder.children.flatMap { itemIDs($0) }
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return package?.notebook.sections.count ?? 0 }
        return children(of: item).count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil, let sections = package?.notebook.sections { return navRow(sections[index].id) }
        return navRow(children(of: item)[index].id)
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let row = item as? SidebarRow else { return false }
        if isSectionRow(row.id) { return true }
        return (package?.notebook.sections ?? []).contains { $0.folder(row.id) != nil }
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? SidebarRow,
              let owner = sectionIndex(of: row.id), let sections = package?.notebook.sections else { return nil }
        let section = sections[owner]
        let isSection = section.id == row.id
        let folder = isSection ? nil : section.folder(row.id)
        let page = (isSection || folder != nil) ? nil : section.pages.first { $0.id == row.id }
        let isGroup = isSection || folder != nil
        let title = isSection ? section.name : (folder?.name ?? page?.title ?? "")
        let cell = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("nav"), owner: self) as? NavCell) ?? NavCell()
        let color = isSection ? Palette.ink : Self.sidebarColor(folder?.colorHex ?? page?.colorHex)
        cell.showMark(isGroup, tint: color, symbol: isSection ? "books.vertical.fill" : "folder.fill")
        cell.title.stringValue = title
        cell.title.font = .systemFont(ofSize: 16, weight: isSection ? .bold : (folder == nil ? .medium : .semibold))
        cell.titleColor = color
        cell.title.isEditable = isGroup
        cell.title.target = isGroup ? self : nil
        cell.title.action = isGroup ? #selector(commitFolderName(_:)) : nil
        cell.title.identifier = NSUserInterfaceItemIdentifier(row.id.uuidString)
        return cell
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !revertingSelection, let id = selectedID() else { return }
        if let index = sectionIndex(of: id) { focusSection(index) }
        if isSectionRow(id) || currentSectionModel()?.folder(id) != nil { return }
        showPage(id)
    }

    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let row = item as? SidebarRow, !isSectionRow(row.id) else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(row.id.uuidString, forType: navType)
        return writer
    }

    public func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Rows move only inside their own section; the top level is the list of sections.
        guard let moving = draggedNavID(info), let owner = sectionIndex(of: moving),
              let sections = package?.notebook.sections,
              let row = item as? SidebarRow, sectionIndex(of: row.id) == owner else { return [] }
        let section = sections[owner]
        if row.id == section.id { return .move }
        if section.folder(row.id) == nil {
            let parent = section.parent(of: row.id)
            let siblings = parent.flatMap { section.folder($0)?.children } ?? section.items
            let at = (siblings.firstIndex { $0.id == row.id } ?? siblings.count - 1) + 1
            outlineView.setDropItem(navRow(parent ?? section.id), dropChildIndex: at)
            return .move
        }
        if nests(moving, inside: row.id, section: section) { return [] }
        return .move
    }

    public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard var pkg = package, let id = draggedNavID(info), let owner = sectionIndex(of: id),
              let row = item as? SidebarRow, sectionIndex(of: row.id) == owner else { return false }
        let parent: UUID? = row.id == pkg.notebook.sections[owner].id ? nil : row.id
        let at = index == NSOutlineViewDropOnItemIndex ? Int.max : index
        do {
            guard try pkg.moveItem(id, section: owner, into: parent, at: at) else { return false }
            package = pkg
            reloadPages()
            selectNav(id)
            return true
        } catch { show(error); return false }
    }

    private func draggedNavID(_ info: NSDraggingInfo) -> UUID? {
        guard let raw = info.draggingPasteboard.string(forType: navType) else { return nil }
        return UUID(uuidString: raw)
    }

    private func nests(_ id: UUID, inside parent: UUID, section: Section) -> Bool {
        if parent == id { return true }
        var cursor: UUID? = parent
        while let current = cursor {
            if current == id { return true }
            cursor = section.parent(of: current)
        }
        return false
    }

    @objc func addPage(_ sender: Any?) {
        commitEditing()
        guard var pkg = package else { return }
        do {
            let page = try pkg.addPage(title: "Untitled Page", section: currentSection, inFolder: destinationFolder())
            package = pkg
            reloadPages()
            selectNav(page.id)
        } catch { show(error) }
    }

    @objc func addFolder(_ sender: Any?) {
        commitEditing()
        guard var pkg = package else { return }
        do {
            let id = try pkg.addFolder(named: "New Folder", section: currentSection, inFolder: destinationFolder())
            package = pkg
            reloadPages()
            selectNav(id)
            outline.editColumn(0, row: outline.selectedRow, with: nil, select: true)
        } catch { show(error) }
    }

    @objc func addSection(_ sender: Any?) {
        commitEditing()
        guard var pkg = package else { return }
        do {
            let section = try pkg.addEmptySection(name: "New Section")
            package = pkg
            focusSection(pkg.notebook.sections.count - 1)
            reloadPages()
            selectNav(section.id)
            outline.editColumn(0, row: outline.selectedRow, with: nil, select: true)
        } catch { show(error) }
    }

    @objc func renameFolder(_ sender: Any?) {
        guard let id = selectedID(), outline.selectedRow >= 0,
              isSectionRow(id) || currentSectionModel()?.folder(id) != nil else { return }
        outline.editColumn(0, row: outline.selectedRow, with: nil, select: true)
    }

    private func menuTargetID(_ sender: NSMenuItem) -> UUID? {
        (sender.representedObject as? String).flatMap { UUID(uuidString: $0) }
    }

    @objc func renameFromMenu(_ sender: NSMenuItem) {
        guard let id = menuTargetID(sender) else { return }
        selectNav(id)
        renameFolder(nil)
    }

    @objc func deleteFromMenu(_ sender: NSMenuItem) {
        guard let id = menuTargetID(sender) else { return }
        selectNav(id)
        removePage(nil)
    }

    @objc func commitFolderName(_ sender: NSTextField) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw), var pkg = package else { return }
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSectionRow(id) {
            do {
                try pkg.renameSection(id, to: trimmed.isEmpty ? "Section" : trimmed)
                package = pkg
                if let row = navRows[id] { outline.reloadItem(row) }
            } catch { show(error) }
            return
        }
        guard let owner = sectionIndex(of: id) else { return }
        let name = trimmed.isEmpty ? "Folder" : trimmed
        do {
            try pkg.renameFolder(id, section: owner, to: name)
            package = pkg
            if let row = navRows[id] { outline.reloadItem(row) }
        } catch { show(error) }
    }

    /// The folder or page under the pointer, when the context menu is opening.
    private func clickedNavID() -> UUID? {
        var row = outline.clickedRow
        if row < 0, let event = NSApp.currentEvent {
            row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
        }
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarRow else { return nil }
        return item.id
    }

    private static func sidebarColor(_ hex: String?) -> NSColor {
        if let hex, let color = AttributedBridge.color(hex: hex) { return color }
        return Palette.ink
    }

    /// The sidebar colour of a folder or page, or nil when that item stays ink.
    private func sidebarColorHex(of id: UUID) -> String? {
        guard let owner = sectionIndex(of: id), let section = package?.notebook.sections[owner] else { return nil }
        if let folder = section.folder(id) { return folder.colorHex }
        return section.pages.first { $0.id == id }?.colorHex
    }

    private static func swatchImage(_ hex: String) -> NSImage? {
        guard let color = AttributedBridge.color(hex: hex) else { return nil }
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func folderColorItems(id: UUID, current: String?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (index, swatch) in Self.folderSwatches.enumerated() {
            if swatch.hex == nil { items.append(.separator()) }
            let item = NSMenuItem(title: swatch.name, action: #selector(pickFolderColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = id.uuidString
            item.state = swatch.hex == current ? .on : .off
            if let hex = swatch.hex { item.image = Self.swatchImage(hex) }
            items.append(item)
        }
        return items
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == outline.menu {
            menu.removeAllItems()
            guard let id = clickedNavID() else {
                menu.addItem(NSMenuItem(title: "New Section", action: #selector(addSection(_:)), keyEquivalent: ""))
                menu.items.forEach { $0.target = self }
                return
            }
            let isSection = isSectionRow(id)
            let isFolder = (package?.notebook.sections ?? []).contains { $0.folder(id) != nil }
            if isSection || isFolder {
                let rename = NSMenuItem(title: isSection ? "Rename Section" : "Rename Folder",
                                        action: #selector(renameFromMenu(_:)), keyEquivalent: "")
                rename.target = self
                rename.representedObject = id.uuidString
                menu.addItem(rename)
            }
            if isSection {
                let delete = NSMenuItem(title: "Delete Section…", action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = id.uuidString
                menu.addItem(delete)
                return
            }
            if isFolder { menu.addItem(.separator()) }
            for item in folderColorItems(id: id, current: sidebarColorHex(of: id)) { menu.addItem(item) }
            return
        }
        let current = selectedID().map { sidebarColorHex(of: $0) }
        for item in menu.items where item.action == #selector(pickFolderColor(_:)) && Self.folderSwatches.indices.contains(item.tag) {
            let matches = current.map { Self.folderSwatches[item.tag].hex == $0 } ?? false
            item.state = matches ? .on : .off
        }
    }

    @objc func pickFolderColor(_ sender: NSMenuItem) {
        guard Self.folderSwatches.indices.contains(sender.tag) else { return }
        let hex = Self.folderSwatches[sender.tag].hex
        let id: UUID
        if let raw = sender.representedObject as? String, let parsed = UUID(uuidString: raw) {
            id = parsed
        } else if let selected = selectedID() {
            id = selected
        } else { return }
        guard var pkg = package, !isSectionRow(id), let owner = sectionIndex(of: id) else { return }
        let section = pkg.notebook.sections[owner]
        do {
            if section.folder(id) != nil {
                try pkg.setFolderColor(id, section: owner, to: hex)
            } else {
                try pkg.setPageColor(id, section: owner, to: hex)
            }
            package = pkg
            if let i = pages.firstIndex(where: { $0.id == id }),
               let ref = pkg.notebook.sections[owner].pages.first(where: { $0.id == id }) {
                pages[i] = ref
            }
            if let row = navRows[id] { outline.reloadItem(row) }
        } catch { show(error) }
    }

    @objc func removePage(_ sender: Any?) {
        commitEditing()
        guard var pkg = package, let id = selectedID(), let section = currentSectionModel() else { return }
        if isSectionRow(id) {
            guard pkg.notebook.sections.count > 1 else {
                inform("This is the only section", "A notebook needs at least one section. Add another before deleting this one.")
                return
            }
            let count = section.pages.count
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Delete the section “\(section.name)”?"
            a.informativeText = count == 0 ? "The section is empty."
                : "Its \(count) \(count == 1 ? "page" : "pages") will be moved to the Trash."
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Delete Section").hasDestructiveAction = true
            guard a.runModal() == .alertSecondButtonReturn else { return }
            let openPageGoes = controller.map { c in section.pages.contains { $0.id == c.page.id } } ?? false
            do { _ = try pkg.deleteSection(id) } catch { show(error); return }
            package = pkg
            if openPageGoes { dropPage() }
            outline.deselectAll(nil)
            currentSection = 0
            reloadPages()
            if openPageGoes, let first = pages.first { selectNav(first.id) }
            return
        }
        if section.folder(id) != nil {
            let name = section.folder(id)?.name ?? "Folder"
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Remove “\(name)”?"
            a.informativeText = "Pages and folders inside it stay in this section."
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Remove Folder").hasDestructiveAction = true
            guard a.runModal() == .alertSecondButtonReturn else { return }
            do { try pkg.dissolveFolder(id, section: currentSection) } catch { show(error); return }
            package = pkg
            reloadPages()
            return
        }
        guard let ref = section.pages.first(where: { $0.id == id }) else { return }
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
        outline.deselectAll(nil)
        reloadPages()
        if let first = pages.first { selectNav(first.id) }
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleField else { return }
        controller?.setTitle(titleField.stringValue)
    }

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
        LastNotebook.remember(pkg.url)
        currentSection = pkg.notebook.sections.firstIndex { $0.id == section.id } ?? 0
        dropPage()
        outline.deselectAll(nil)
        reloadPages()
        if let first = pages.first { selectNav(first.id) }
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
        if item.action == #selector(pickFolderColor(_:)) {
            if item.representedObject != nil { return true }   // right-click already targeted a folder or page
            return selectedID() != nil
        }
        if item.action == #selector(encryptNotebook(_:)) { return package != nil && package?.isEncrypted == false }
        if item.action == #selector(changePassphrase(_:)) { return package?.isEncrypted == true }
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
        window.miniwindowImage = NSApp.applicationIconImage
        window.isReleasedWhenClosed = false          // the shell owns the window; closing it must not free it
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.delegate = self
        window.center()

        let glass = NSView()
        glass.wantsLayer = true
        glass.layer?.backgroundColor = Palette.stone.cgColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowHeight = 36
        outline.indentationPerLevel = 16
        outline.autoresizesOutlineColumn = true
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.doubleAction = #selector(renameFolder(_:))
        outline.registerForDraggedTypes([navType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        let outlineMenu = NSMenu()
        outlineMenu.delegate = self
        outline.menu = outlineMenu
        let sideScroll = NSScrollView()
        sideScroll.documentView = outline
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false
        sideScroll.borderType = .noBorder
        sideScroll.scrollerStyle = .overlay
        let add = symbolButton("plus", #selector(addPage(_:)), tip: "Add page")
        let folder = symbolButton("folder.badge.plus", #selector(addFolder(_:)), tip: "New folder")
        let newSection = symbolButton("rectangle.stack.badge.plus", #selector(addSection(_:)), tip: "New section")
        let remove = symbolButton("minus", #selector(removePage(_:)), tip: "Delete page or section, or remove folder")
        let sideButtons = NSStackView(views: [add, folder, newSection, remove])
        sideButtons.spacing = 2
        let side = NSStackView(views: [sideScroll, sideButtons])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 6
        sideScroll.widthAnchor.constraint(equalTo: side.widthAnchor).isActive = true
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

    /// `CFBundleShortVersionString` once this process is a bundled .app. `swift run` has no version.
    private static func aboutVersionLabel() -> String {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app",
              let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Development"
        }
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? "Development" : "Version \(version)"
    }

    private func aboutLine(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = Palette.ink.withAlphaComponent(alpha)
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.refusesFirstResponder = true
        return label
    }

    /// Icon is `NSApp.applicationIconImage`, which `main.swift` sets from `AppIcon.image()`.
    private func makeAboutWindow() -> NSPanel {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageFrameStyle = .none
        icon.image = NSApp.applicationIconImage ?? NSImage(named: "AppIcon")
        icon.setAccessibilityLabel("NoteCanvas")
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72),
        ])

        let name = aboutLine("NoteCanvas", size: 18, weight: .semibold, alpha: 1)
        let version = aboutLine(Self.aboutVersionLabel(), size: 12, weight: .medium, alpha: 0.72)
        let blurb = aboutLine("A free-form note canvas", size: 13, weight: .regular, alpha: 1)
        let copyright = aboutLine("Copyright © 2026 Steven Coutts", size: 11, weight: .regular, alpha: 0.62)

        let stack = NSStackView(views: [icon, name, version, blurb, copyright])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(10, after: version)
        stack.setCustomSpacing(8, after: blurb)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 16, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.appearance = NSAppearance(named: .aqua)
        card.layer?.backgroundColor = Palette.paper.cgColor
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Palette.hairline.cgColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.35, green: 0.28, blue: 0.20, alpha: 0.18)
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowBlurRadius = 12
        card.shadow = shadow
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        // fittingSize drops the stack's horizontal insets, so width is the text plus that padding.
        let textWidth = [name, version, blurb, copyright].map(\.intrinsicContentSize.width).max() ?? 0
        let cardSize = NSSize(
            width: ceil(max(textWidth, 72) + stack.edgeInsets.left + stack.edgeInsets.right),
            height: ceil(stack.fittingSize.height))
        let margin: CGFloat = 16

        let root = AboutKeyView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: .aqua)
        root.layer?.backgroundColor = Palette.stone.cgColor
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),
        ])

        let panel = AboutPanel(
            contentRect: NSRect(x: 0, y: 0, width: cardSize.width + margin * 2, height: cardSize.height + margin * 2),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        panel.title = "About NoteCanvas"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isOpaque = true
        panel.backgroundColor = Palette.stone
        panel.appearance = NSAppearance(named: .aqua)
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = root
        panel.initialFirstResponder = root
        panel.setContentSize(NSSize(width: cardSize.width + margin * 2, height: cardSize.height + margin * 2))

        if let parent = window, parent.isVisible {
            var frame = panel.frame
            frame.origin = NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2)
            if let screen = parent.screen ?? NSScreen.main {
                frame = panel.constrainFrameRect(frame, to: screen)
            }
            panel.setFrame(frame, display: false)
        } else {
            panel.center()
        }
        return panel
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
        item("About NoteCanvas", #selector(showAbout(_:)), in: app)
        app.addItem(.separator())
        item("Check for Updates…", #selector(checkForUpdates(_:)), in: app)
        item("Quit NoteCanvas", #selector(NSApplication.terminate(_:)), "q", in: app)
        let file = submenu("File")
        item("New Notebook…", #selector(newNotebook(_:)), "n", in: file)
        item("Open Notebook…", #selector(openNotebook(_:)), "o", in: file)
        item("New Page", #selector(addPage(_:)), "t", in: file)
        item("New Folder", #selector(addFolder(_:)), "n", mods: [.command, .shift], in: file)
        item("New Section", #selector(addSection(_:)), "n", mods: [.command, .option], in: file)
        let colorMenu = NSMenu(title: "Color")
        colorMenu.delegate = self
        let colorItem = NSMenuItem(title: "Color", action: #selector(pickFolderColor(_:)), keyEquivalent: "")
        colorItem.target = self
        colorItem.tag = -1
        colorItem.submenu = colorMenu
        file.addItem(colorItem)
        for (index, swatch) in Self.folderSwatches.enumerated() {
            if swatch.hex == nil { colorMenu.addItem(.separator()) }
            let choice = NSMenuItem(title: swatch.name, action: #selector(pickFolderColor(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = index
            if let hex = swatch.hex { choice.image = Self.swatchImage(hex) }
            colorMenu.addItem(choice)
        }
        item("Import .one…", #selector(importOne(_:)), "i", in: file)
        file.addItem(.separator())
        item("Encrypt Notebook…", #selector(encryptNotebook(_:)), in: file)
        item("Change Passphrase…", #selector(changePassphrase(_:)), in: file)
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
