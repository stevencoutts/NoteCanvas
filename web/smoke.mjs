// Model checks, a Swift JSON compatibility check, and a fetch of the page.
import { spawnSync } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  History, addFolder, addPage, clearOrigin, decodeNotebook, decodePage, dissolveFolder,
  encodeNotebook, encodePage, flattenPages, linkifyParagraphs, moveItem, moveSection,
  removePage, scaledImageFrame, assetName,
} from "./model.js";

let failed = 0;
function check(cond, message) {
  if (!cond) { failed += 1; console.error("FAIL", message); }
  else console.log("ok", message);
}

const sectionID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
const pageID = "11111111-2222-3333-4444-555555555555";
const old = JSON.parse(`{"version":1,"name":"n","sections":[{"id":"${sectionID}","name":"S","pages":[{"id":"${pageID}","title":"Kept"}]}]}`);
const decoded = decodeNotebook(old);
check(decoded.sections[0].items[0].title === "Kept", "a notebook saved before folders still lists its pages");
check(decoded.revision === 0, "a missing revision is zero");

const notebook = decodeNotebook(JSON.parse(encodeNotebook(decoded)));
check(notebook.sections[0].items[0].id === pageID, "notebook json round-trips");
check(!encodeNotebook(notebook).includes("revision"), "revision 0 is left out of the file");
check(encodeNotebook(notebook).includes('"_0"'), "sidebar items use Swift's _0 payload");

let section = notebook.sections[0];
const work = addFolder(section, "Work", null);
const later = addFolder(section, "Later", work);
const moved = "22222222-2222-2222-2222-222222222222";
addPage(section, { id: moved, title: "Inside" }, work);
check(flattenPages(section.items).map((page) => page.title).join(",") === "Kept,Inside", "pages inside folders stay in the flat list");
check(moveItem(section, moved, later, 0) === true, "a page can move into a subfolder");
check(moveItem(section, work, later, 0) === false, "a folder cannot move into its own subfolder");
check(moveItem(section, later, null, 0) === true, "a subfolder can move to the top");
check(section.items[0].id === later, "it is now the first item");
check(dissolveFolder(section, work) === true, "removing a folder keeps what was inside it");
check(flattenPages(section.items).some((page) => page.id === moved), "the page is still in the section");

const spot = clearOrigin(100, 40, 10, 10, [{ x: 10, y: 10, width: 80, height: 30 }]);
check(spot.y === 56, `clear origin steps below a blocker (${spot.y})`);
const grown = scaledImageFrame({ x: 0, y: 0, width: 100, height: 50 }, "bottomRight", 50, 0);
check(grown.width === 150 && grown.height === 75, "a corner resize keeps the aspect ratio");
const shrunk = scaledImageFrame({ x: 0, y: 0, width: 100, height: 50 }, "topLeft", 10, 10);
check(shrunk.width >= 32 && shrunk.height >= 16, "a corner resize does not pass the minimum");

const history = new History(2);
history.record({ n: 1 });
history.record({ n: 2 });
history.record({ n: 3 });
check(history.undo({ n: 4 })?.n === 3, "undo returns the previous snapshot");
check(history.undo({ n: 3 })?.n === 2, "undo walks back");
check(history.undo({ n: 2 }) == null, "the history limit drops the oldest snapshot");
history.record({ n: 5 });
history.discardLast();
check(history.undo({ n: 9 }) == null, "discardLast drops the newest snapshot");

check(assetName("PNG").endsWith(".png"), "an asset extension is lower-case");
check(assetName("!!!").endsWith(".bin"), "an empty extension becomes bin");
const linked = linkifyParagraphs([{ runs: [{ text: "see https://example.com/a now", style: { bold: false, script: "normal" } }], indent: 0, heading: 0, list: "none", alignment: "left" }]);
check(linked[0].runs[1].style.link === "https://example.com/a", "a web address becomes a link");

const page = {
  id: pageID,
  title: "Kept",
  objects: [
    {
      type: "text", id: "33333333-3333-3333-3333-333333333333",
      frame: { x: 12, y: -4, width: 240, height: 48.5 },
      paragraphs: [{
        runs: [
          { text: "Hi/", style: { bold: true, italic: false, underline: false, strike: false, script: "normal", colorHex: "#A33B32", link: "https://example.com/x" } },
          { text: " there", style: { bold: false, italic: true, underline: true, strike: true, script: "sup", fontSize: 18 } },
        ],
        indent: 1, heading: 2, list: "bullet", alignment: "center",
      }],
    },
    { type: "image", id: "44444444-4444-4444-4444-444444444444", frame: { x: 0, y: 80, width: 480, height: 200 }, asset: "55555555-5555-5555-5555-555555555555.png", altText: null },
    {
      type: "table", id: "66666666-6666-6666-6666-666666666666",
      frame: { x: 8, y: 300, width: 200, height: 40 },
      columnWidths: [120, 80], bordersVisible: true,
      rows: [[{ paragraphs: [{ runs: [{ text: "A", style: { bold: false, italic: false, underline: false, strike: false, script: "normal" } }], indent: 0, heading: 0, list: "none", alignment: "left" }] }, { paragraphs: [] }]],
    },
    { type: "attachment", id: "77777777-7777-7777-7777-777777777777", frame: { x: 8, y: 360, width: 160, height: 64 }, asset: "88888888-8888-8888-8888-888888888888.pdf", displayName: "Notes.pdf" },
  ],
};
const pageJSON = encodePage(page);
const pageBack = decodePage(JSON.parse(pageJSON));
check(pageBack.objects.length === 4, "a page round-trips its objects");
check(pageBack.objects[0].paragraphs[0].runs[0].style.bold === true, "bold survives a round-trip");
check(pageBack.objects[0].frame.y === -4, "a negative position survives");
check(pageBack.objects[1].type === "image" && pageBack.objects[2].type === "table" && pageBack.objects[3].type === "attachment", "image, table, and attachment keep their kinds");

section = {
  id: sectionID, name: "Section 1", locked: false,
  items: [
    { kind: "folder", id: "99999999-9999-9999-9999-999999999999", name: "Work", colorHex: "#3D7048", children: [
      { kind: "page", id: pageID, title: "Kept", colorHex: "#34547E" },
    ] },
  ],
};
const book = { version: 1, name: "Notes", revision: 0, sections: [section, { id: "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB", name: "Locked", locked: true, items: [{ kind: "page", id: "00000000-0000-0000-0000-000000000001", title: "Hidden" }] }] };
const bookJSON = encodeNotebook(book);
const bookBack = decodeNotebook(JSON.parse(bookJSON));
check(bookBack.sections[1].locked === true && bookBack.sections[1].items.length === 0, "a locked section stays a stand-in");
check(bookBack.sections[0].items[0].colorHex === "#3D7048", "a folder colour round-trips");
check(flattenPages(bookBack.sections[0].items)[0].colorHex === "#34547E", "a page colour round-trips");
check(removePage(bookBack, pageID) === true, "deleting a page drops it from the tree");

const dir = mkdtempSync(join(tmpdir(), "notecanvas-"));
writeFileSync(join(dir, "page.json"), pageJSON);
writeFileSync(join(dir, "notebook.json"), bookJSON);
const swift = `
import Foundation
enum Script: String, Codable { case normal, sup, sub }
struct RunStyle: Codable { var bold: Bool; var italic: Bool; var underline: Bool; var strike: Bool; var fontName: String?; var fontSize: Double?; var colorHex: String?; var highlightHex: String?; var script: Script; var link: String? }
struct Run: Codable { var text: String; var style: RunStyle }
enum ListStyle: String, Codable { case none, bullet, numbered }
enum Alignment: String, Codable { case left, center, right }
struct Paragraph: Codable { var runs: [Run]; var indent: Int; var heading: Int; var list: ListStyle; var alignment: Alignment }
struct Frame: Codable { var x: Double; var y: Double; var width: Double; var height: Double }
struct TextContainer: Codable { var id: String; var frame: Frame; var paragraphs: [Paragraph] }
struct ImageObject: Codable { var id: String; var frame: Frame; var asset: String; var altText: String? }
struct TableCell: Codable { var paragraphs: [Paragraph] }
struct TableObject: Codable { var id: String; var frame: Frame; var columnWidths: [Double]; var rows: [[TableCell]]; var bordersVisible: Bool }
struct AttachmentObject: Codable { var id: String; var frame: Frame; var asset: String; var displayName: String }
enum PageObject: Codable { case text(TextContainer); case image(ImageObject); case table(TableObject); case attachment(AttachmentObject) }
struct Page: Codable { var id: String; var title: String; var objects: [PageObject] }
struct PageRef: Codable, Equatable { var id: String; var title: String; var colorHex: String? }
struct Folder: Codable, Equatable { var id: String; var name: String; var children: [NotebookItem]; var colorHex: String? }
enum NotebookItem: Codable, Equatable { case page(PageRef); case folder(Folder) }
struct Section: Codable, Equatable {
  var id: String; var name: String; var items: [NotebookItem]; var locked: Bool = false
  var pages: [PageRef] { Self.flatten(items) }
  static func flatten(_ items: [NotebookItem]) -> [PageRef] {
    items.flatMap { item in switch item { case .page(let page): return [page]; case .folder(let folder): return flatten(folder.children) } }
  }
  enum CodingKeys: String, CodingKey { case id, name, pages, items, locked }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
    if try c.decodeIfPresent(Bool.self, forKey: .locked) == true { locked = true; items = []; return }
    if let items = try c.decodeIfPresent([NotebookItem].self, forKey: .items) { self.items = items }
    else { items = (try c.decodeIfPresent([PageRef].self, forKey: .pages) ?? []).map { .page($0) } }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
    if locked { try c.encode(true, forKey: .locked); return }
    try c.encode(items, forKey: .items); try c.encode(pages, forKey: .pages)
  }
}
struct Notebook: Codable, Equatable {
  var version: Int; var name: String; var sections: [Section]; var revision: Int
  enum CodingKeys: String, CodingKey { case version, name, sections, revision }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(Int.self, forKey: .version); name = try c.decode(String.self, forKey: .name)
    sections = try c.decode([Section].self, forKey: .sections)
    revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(version, forKey: .version); try c.encode(name, forKey: .name); try c.encode(sections, forKey: .sections)
    if revision != 0 { try c.encode(revision, forKey: .revision) }
  }
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let pageURL = URL(fileURLWithPath: CommandLine.arguments[1])
let bookURL = URL(fileURLWithPath: CommandLine.arguments[2])
let page = try JSONDecoder().decode(Page.self, from: Data(contentsOf: pageURL))
let book = try JSONDecoder().decode(Notebook.self, from: Data(contentsOf: bookURL))
try encoder.encode(page).write(to: pageURL.appendingPathExtension("swift"))
try encoder.encode(book).write(to: bookURL.appendingPathExtension("swift"))
print("decoded \\(page.objects.count) objects and \\(book.sections.count) sections")
`;
writeFileSync(join(dir, "roundtrip.swift"), swift);
const compiled = spawnSync("swiftc", ["-swift-version", "5", "-o", join(dir, "roundtrip"), join(dir, "roundtrip.swift")], { encoding: "utf8" });
if (compiled.status !== 0) {
  check(false, `swiftc failed: ${compiled.stderr}`);
} else {
  const ran = spawnSync(join(dir, "roundtrip"), [join(dir, "page.json"), join(dir, "notebook.json")], { encoding: "utf8" });
  check(ran.status === 0, `Swift decoded the web JSON (${ran.stderr || ran.stdout})`);
  const pageSwift = await (await import("node:fs")).promises.readFile(join(dir, "page.json.swift"), "utf8");
  const bookSwift = await (await import("node:fs")).promises.readFile(join(dir, "notebook.json.swift"), "utf8");
  check(pageSwift === pageJSON, "page JSON matches Swift's encoder");
  check(bookSwift === bookJSON, "notebook JSON matches Swift's encoder");
  if (pageSwift !== pageJSON) console.error(pageSwift.split("\n").slice(0, 40).join("\n"));
  if (bookSwift !== bookJSON) console.error("--- notebook diff head ---\n" + bookSwift.slice(0, 500));
}

const base = process.argv[2];
if (base) {
  const response = await fetch(base);
  const html = await response.text();
  check(response.ok && html.includes("section-popup") && html.includes("Open Notebook"), "the page HTML is served");
  for (const file of ["styles.css", "app.js", "model.js", "canvas.js", "store.js"]) {
    const part = await fetch(new URL(file, base));
    check(part.ok, `${file} is served (${part.status})`);
  }
}

check(moveSection({ sections: [{ id: "a" }, { id: "b" }, { id: "c" }] }, "a", 2) === true, "a section can move down");
if (failed) { console.error(`${failed} failed`); process.exit(1); }
console.log("all checks passed");
