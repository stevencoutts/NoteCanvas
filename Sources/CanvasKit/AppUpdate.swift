import AppKit

/// Learns the latest version tag from GitHub Releases and installs a newer NoteCanvas.app.
///
/// The zip is always `https://stevec.couttsnet.com/downloads/notecanvas/macos/NoteCanvas-<version>.zip`
/// (version without a leading v). GitHub asset URLs are ignored, and a failed download is not
/// retried from GitHub.
///
/// The packaged app's version is `CFBundleShortVersionString` (see `.github/package-app.sh`).
/// `swift run` has no bundle version and is treated as 0.0.0. It can download an update and
/// reveal it in Finder; only a running `NoteCanvas.app` is replaced.
public enum AppUpdate {
    /// Seconds since 1970 of the last completed check. Not a note, and not read back to skip a launch check.
    static let lastCheckKey = "lastUpdateCheck"
    private static let latestURL = URL(string: "https://api.github.com/repos/stevencoutts/NoteCanvas/releases/latest")!

    public struct Version: Comparable, Sendable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(major: Int, minor: Int, patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        /// `v1.2.3` or `1.2.3`. Prerelease and build suffixes are rejected.
        public static func parse(_ raw: String) -> Version? {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.first == "v" || text.first == "V" { text.removeFirst() }
            if text.isEmpty || text.contains("-") || text.contains("+") { return nil }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let major = component(parts[0]),
                  let minor = component(parts[1]),
                  let patch = component(parts[2]) else { return nil }
            return Version(major: major, minor: minor, patch: patch)
        }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }

        public var description: String { "\(major).\(minor).\(patch)" }

        private static func component(_ part: Substring) -> Int? {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int(part)
        }
    }

    public struct Release: Equatable {
        public var version: Version
        public var zipURL: URL
    }

    /// A stable release from a `/releases/latest` body, if the tag is major.minor.patch.
    /// Only the tag is read. The zip URL is `downloadURL(for:)`, never a GitHub asset.
    public static func release(from data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let version = Version.parse(tag),
              let zipURL = downloadURL(for: version) else { return nil }
        return Release(version: version, zipURL: zipURL)
    }

    /// `https://stevec.couttsnet.com/downloads/notecanvas/macos/NoteCanvas-<version>.zip`, with no leading v.
    static func downloadURL(for version: Version) -> URL? {
        URL(string: "https://stevec.couttsnet.com/downloads/notecanvas/macos/NoteCanvas-\(version).zip")
    }

    public static func isUpdate(_ remote: Version, replacing current: Version) -> Bool {
        remote > current
    }

    public static func currentVersion() -> Version {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return Version.parse(raw) ?? Version(major: 0, minor: 0, patch: 0)
    }

    /// The running bundle when this process is `NoteCanvas.app`. `swift run` returns nil.
    public static func installedAppURL() -> URL? {
        let url = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard url.lastPathComponent == "NoteCanvas.app" else { return nil }
        return url
    }

    private static var busy = false
    private static var interactivePending = false
    private static var helper: Process?

    /// `interactive` shows an alert when there is nothing to install. A silent launch check only speaks when a newer version exists.
    public static func check(interactive: Bool) {
        onMain {
            if busy {
                if interactive { interactivePending = true }
                return
            }
            busy = true
            interactivePending = interactive
            DispatchQueue.global(qos: .utility).async {
                let outcome = fetchLatest()
                onMain {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                    let talk = interactivePending
                    interactivePending = false
                    finish(outcome, interactive: talk)
                }
            }
        }
    }

    private enum Outcome {
        case update(Release)
        case current(Version)
        case failed(String)
    }

    private static func finish(_ outcome: Outcome, interactive: Bool) {
        switch outcome {
        case .update(let release):
            let installed = installedAppURL()
            let agreed = installed == nil
                ? ask("NoteCanvas \(release.version) is available",
                      "Replacing the running copy only works for the installed app. The new app can be downloaded and shown in Finder.",
                      ok: "Download")
                : ask("Update NoteCanvas to \(release.version)?",
                      "The new app will replace this copy. NoteCanvas will quit and open again.",
                      ok: "Install and Relaunch")
            guard agreed else { busy = false; return }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let app = try downloadApp(from: release.zipURL)
                    onMain {
                        busy = false
                        if let installed {
                            replaceRunningApp(with: app, at: installed)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([app])
                        }
                    }
                } catch let error as UpdateError {
                    onMain {
                        busy = false
                        tell("Could not download the update", error.message)
                    }
                } catch {
                    onMain {
                        busy = false
                        tell("Could not download the update", "NoteCanvas could not download or open the new app.")
                    }
                }
            }
        case .current(let version):
            busy = false
            if interactive { tell("NoteCanvas is up to date", upToDateMessage(version)) }
        case .failed(let message):
            busy = false
            if interactive { tell("Could not check for updates", message) }
        }
    }

    private static func upToDateMessage(_ version: Version) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if Version.parse(raw) == nil {
            return "This copy has no version number, so it is treated as 0.0.0."
        }
        return "You are running \(version)."
    }

    private static func fetchLatest() -> Outcome {
        let current = currentVersion()
        do {
            var request = URLRequest(url: latestURL, timeoutInterval: 20)
            request.setValue("NoteCanvas", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, http) = try responseData(for: request, timeout: 20)
            if http.statusCode == 404 { return .failed("There is no release to install yet.") }
            guard (200..<300).contains(http.statusCode) else {
                return .failed("GitHub could not be checked (HTTP \(http.statusCode)).")
            }
            guard let release = release(from: data) else {
                return .failed("The latest release has no app to install.")
            }
            if isUpdate(release.version, replacing: current) { return .update(release) }
            return .current(current)
        } catch let error as UpdateError {
            return .failed(error.message)
        } catch {
            return .failed("NoteCanvas could not reach GitHub. Check the network and try again.")
        }
    }

    private static func responseData(for request: URLRequest, timeout: TimeInterval) throws -> (Data, HTTPURLResponse) {
        let session = makeSession(requestTimeout: timeout, resourceTimeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let sem = DispatchSemaphore(value: 0)
        var output: Result<(Data, HTTPURLResponse), UpdateError>?
        let task = session.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if error != nil {
                output = .failure(UpdateError(message: "NoteCanvas could not reach GitHub. Check the network and try again."))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                output = .failure(UpdateError(message: "NoteCanvas could not read GitHub's reply."))
                return
            }
            output = .success((data, http))
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw UpdateError(message: "Checking for updates timed out.")
        }
        switch output {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw UpdateError(message: "NoteCanvas could not reach GitHub. Check the network and try again.")
        }
    }

    /// Downloads the zip into a temporary folder and returns the `NoteCanvas.app` inside it.
    /// The folder is left in place: the replacer reads it after this process exits.
    private static func downloadApp(from zipURL: URL) throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCanvasUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("NoteCanvas.zip")
        let unpack = work.appendingPathComponent("unpack", isDirectory: true)
        try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
        try download(zipURL, to: zip)
        guard run("/usr/bin/ditto", ["-xk", zip.path, unpack.path]) == 0 else {
            throw UpdateError(message: "NoteCanvas could not open the downloaded update.")
        }
        guard let app = findApp(in: unpack) else {
            throw UpdateError(message: "The download did not contain NoteCanvas.app.")
        }
        return app
    }

    private static func download(_ remote: URL, to dest: URL) throws {
        guard remote.scheme == "https" else { throw UpdateError(message: "The download link was not secure.") }
        var request = URLRequest(url: remote, timeoutInterval: 60)
        request.setValue("NoteCanvas", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = makeSession(requestTimeout: 60, resourceTimeout: 300)
        defer { session.finishTasksAndInvalidate() }
        let sem = DispatchSemaphore(value: 0)
        var failure: UpdateError?
        let task = session.downloadTask(with: request) { temp, response, error in
            defer { sem.signal() }
            if error != nil {
                failure = UpdateError(message: "NoteCanvas could not download the update.")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let temp else {
                failure = UpdateError(message: status == 0
                    ? "NoteCanvas could not download the update."
                    : "The download failed (HTTP \(status)).")
                return
            }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: temp, to: dest)
            } catch {
                do { try FileManager.default.copyItem(at: temp, to: dest) }
                catch {
                    failure = UpdateError(message: "NoteCanvas could not save the download.")
                    return
                }
            }
            guard fileIsZip(dest) else {
                failure = UpdateError(message: "NoteCanvas could not open the downloaded update.")
                return
            }
        }
        task.resume()
        if sem.wait(timeout: .now() + 310) == .timedOut {
            task.cancel()
            throw UpdateError(message: "The download timed out.")
        }
        if let failure { throw failure }
    }

    /// ZIP local-file, empty-archive, or spanned-archive header. Anything else is not a zip.
    private static func fileIsZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 4)
        return header == Data([0x50, 0x4b, 0x03, 0x04])
            || header == Data([0x50, 0x4b, 0x05, 0x06])
            || header == Data([0x50, 0x4b, 0x07, 0x08])
    }

    private static func findApp(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for case let url as URL in enumerator {
            if url.pathExtension == "app" { enumerator.skipDescendants() }
            guard url.lastPathComponent == "NoteCanvas.app" else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if path == rootPath || path.hasPrefix(prefix) { return url.standardizedFileURL }
        }
        return nil
    }

    private static func replaceRunningApp(with newApp: URL, at destination: URL) {
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            tell("NoteCanvas could not replace itself",
                 "This copy is not in a folder NoteCanvas can write. The new app will be shown in Finder.")
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            return
        }
        do { try startReplacer(newApp: newApp, destination: destination) }
        catch {
            tell("Could not install the update", "NoteCanvas could not start the installer.")
            return
        }
        NSApp.terminate(nil)
        // Still here: the user cancelled quitting. Do not replace the app out from under them.
        helper?.terminate()
        helper = nil
    }

    /// Waits until this process exits, then copies the new app over `destination` and opens it.
    /// The release is ad-hoc signed, so the quarantine mark URLSession adds would make the replaced app fail to open.
    private static func startReplacer(newApp: URL, destination: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteCanvasUpdate-\(UUID().uuidString).sh")
        try replacerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        let proc = Process()
        let nohup = "/usr/bin/nohup"
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        if FileManager.default.isExecutableFile(atPath: nohup) {
            proc.executableURL = URL(fileURLWithPath: nohup)
            proc.arguments = ["/bin/sh", scriptURL.path, pid, newApp.path, destination.path]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = [scriptURL.path, pid, newApp.path, destination.path]
        }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        try proc.run()
        helper = proc
    }

    private static let replacerScript = """
    #!/bin/sh
    trap '' HUP
    pid="$1"
    src="$2"
    dest="$3"
    fail() {
      /usr/bin/osascript -e 'display alert "NoteCanvas could not install the update" message "The downloaded app is still in a temporary folder."'
      /usr/bin/open -R "$src"
      exit 1
    }
    while kill -0 "$pid" 2>/dev/null; do
      /bin/sleep 0.25
    done
    /bin/sleep 0.5
    stage="${dest}.updating"
    /bin/rm -rf "$stage"
    /usr/bin/ditto "$src" "$stage" || /bin/cp -R "$src" "$stage" || fail
    /bin/rm -rf "$dest" || { /bin/rm -rf "$stage"; fail; }
    /bin/mv "$stage" "$dest" || /usr/bin/ditto "$stage" "$dest" || /bin/cp -R "$stage" "$dest" || fail
    /bin/rm -rf "$stage"
    /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
    /bin/sleep 0.2
    /usr/bin/open "$dest"
    """

    private static func makeSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func ask(_ title: String, _ info: String, ok: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func tell(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}

private struct UpdateError: Error {
    var message: String
}
