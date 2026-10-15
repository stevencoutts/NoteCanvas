import Foundation
import CanvasKit

func updateChecks() {
    let v123 = AppUpdate.Version(major: 1, minor: 2, patch: 3)
    checkEqual(AppUpdate.Version.parse("v1.2.3"), Optional(v123), "tag v1.2.3")
    checkEqual(AppUpdate.Version.parse("1.2.3"), Optional(v123), "plist version 1.2.3")
    checkEqual(AppUpdate.Version.parse(" V1.2.3 "), Optional(v123), "trimmed tag")
    check(AppUpdate.Version.parse("v1.2.3-beta.1") == nil, "prerelease tag ignored")
    check(AppUpdate.Version.parse("v1.2.3+1") == nil, "build metadata ignored")
    check(AppUpdate.Version.parse("v1.2") == nil, "major.minor.patch required")
    check(AppUpdate.Version.parse("") == nil, "empty is not a version")

    let older = AppUpdate.Version(major: 1, minor: 9, patch: 0)
    let newer = AppUpdate.Version(major: 1, minor: 10, patch: 0)
    check(AppUpdate.isUpdate(newer, replacing: older), "1.10.0 is newer than 1.9.0")
    check(!AppUpdate.isUpdate(v123, replacing: v123), "same version is not an update")
    check(!AppUpdate.isUpdate(older, replacing: newer), "older version is not an update")

    let body = Data("""
    {"tag_name":"v1.4.0","name":"NoteCanvas v1.4.0","body":"release notes are not shown",
     "assets":[
       {"name":"NoteCanvas-sources.zip","browser_download_url":"https://github.com/stevencoutts/NoteCanvas/releases/download/v1.4.0/NoteCanvas-sources.zip"},
       {"name":"NoteCanvas-1.4.0.zip","browser_download_url":"https://github.com/stevencoutts/NoteCanvas/releases/download/v1.4.0/NoteCanvas-1.4.0.zip"}
     ]}
    """.utf8)
    let release = AppUpdate.release(from: body)
    checkEqual(release?.version, Optional(AppUpdate.Version(major: 1, minor: 4, patch: 0)), "release tag")
    checkEqual(release?.zipURL.lastPathComponent, Optional("NoteCanvas-1.4.0.zip"), "picks NoteCanvas-<version>.zip")

    let plain = Data("""
    {"tag_name":"v1.0.0","assets":[{"name":"NoteCanvas.zip","browser_download_url":"https://github.com/stevencoutts/NoteCanvas/releases/download/v1.0.0/NoteCanvas.zip"}]}
    """.utf8)
    checkEqual(AppUpdate.release(from: plain)?.zipURL.lastPathComponent, Optional("NoteCanvas.zip"), "NoteCanvas zip is accepted")

    let pre = Data("""
    {"tag_name":"v2.0.0-rc.1","assets":[{"name":"NoteCanvas-2.0.0-rc.1.zip","browser_download_url":"https://github.com/stevencoutts/NoteCanvas/releases/download/v2.0.0-rc.1/a.zip"}]}
    """.utf8)
    check(AppUpdate.release(from: pre) == nil, "prerelease release ignored")

    let insecure = Data("""
    {"tag_name":"v3.0.0","assets":[{"name":"NoteCanvas-3.0.0.zip","browser_download_url":"http://github.com/stevencoutts/NoteCanvas/releases/download/v3.0.0/NoteCanvas-3.0.0.zip"}]}
    """.utf8)
    check(AppUpdate.release(from: insecure) == nil, "download must be https")

    let empty = Data(#"{"tag_name":"v3.0.0","assets":[]}"#.utf8)
    check(AppUpdate.release(from: empty) == nil, "release without a zip")

    checkEqual(AppUpdate.currentVersion(), AppUpdate.Version(major: 0, minor: 0, patch: 0), "missing bundle version is 0.0.0")
    check(AppUpdate.installedAppURL() == nil, "swift run is not NoteCanvas.app")
}
