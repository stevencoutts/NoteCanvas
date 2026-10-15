import AppKit
import Foundation
import PageModel
import Store

// Builds a small notebook of invented notes, for README screenshots. Nothing here comes from real notes.
// Usage: swift run DemoNotebook [output folder]   (default: ./Demo)

func run(_ text: String, bold: Bool = false, italic: Bool = false, size: Double? = nil, color: String? = nil) -> Run {
    var style = RunStyle()
    style.bold = bold; style.italic = italic; style.fontSize = size; style.colorHex = color
    return Run(text: text, style: style)
}

func para(_ text: String, bold: Bool = false, size: Double? = nil, color: String? = nil,
          list: ListStyle = .none, heading: Int = 0) -> Paragraph {
    Paragraph(runs: [run(text, bold: bold, size: size, color: color)], heading: heading, list: list)
}

func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ paragraphs: [Paragraph]) -> PageObject {
    .text(TextContainer(id: UUID(), frame: Frame(x: x, y: y, width: w, height: h), paragraphs: paragraphs))
}

/// A simple coloured plan drawing, so a page can show an image.
func planImage() -> Data? {
    let size = NSSize(width: 480, height: 300)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(srgbRed: 0.93, green: 0.95, blue: 0.90, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    let beds: [(NSRect, NSColor)] = [
        (NSRect(x: 24, y: 160, width: 200, height: 110), NSColor(srgbRed: 0.45, green: 0.62, blue: 0.40, alpha: 1)),
        (NSRect(x: 250, y: 160, width: 200, height: 110), NSColor(srgbRed: 0.72, green: 0.55, blue: 0.33, alpha: 1)),
        (NSRect(x: 24, y: 24, width: 130, height: 110), NSColor(srgbRed: 0.55, green: 0.40, blue: 0.55, alpha: 1)),
        (NSRect(x: 180, y: 24, width: 270, height: 110), NSColor(srgbRed: 0.40, green: 0.58, blue: 0.62, alpha: 1)),
    ]
    for (rect, colour) in beds {
        colour.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Demo", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let url = out.appendingPathComponent("Demo Notebook.notebook", isDirectory: true)
if FileManager.default.fileExists(atPath: url.path) {
    FileHandle.standardError.write(Data("\(url.path) already exists. Remove it or choose another folder.\n".utf8))
    exit(1)
}

var pkg = try NotebookPackage.create(at: url, name: "Demo Notebook")
let placeholder = pkg.notebook.sections[0].id

func add(_ section: String, folders: [(String, String?, [(String, [PageObject])])], loose: [(String, [PageObject])] = []) throws {
    _ = try pkg.addSection(name: section, pages: [])
    let index = pkg.notebook.sections.count - 1
    for (name, colour, pages) in folders {
        let folder = try pkg.addFolder(named: name, section: index, inFolder: nil)
        if let colour { try pkg.setFolderColor(folder, section: index, to: colour) }
        for (title, objects) in pages {
            var page = try pkg.addPage(title: title, section: index, inFolder: folder)
            page.objects = objects
            try pkg.savePage(page)
        }
    }
    for (title, objects) in loose {
        var page = try pkg.addPage(title: title, section: index, inFolder: nil)
        page.objects = objects
        try pkg.savePage(page)
    }
}

let plan: String? = planImage().flatMap { try? pkg.addAsset(data: $0, ext: "png") }

var overview: [PageObject] = [
    box(40, 40, 380, 120, [
        para("Spring planting", bold: true, size: 24),
        para("Beds are marked out. Seeds ordered, soil test back next week.", color: "#5A5046"),
    ]),
    box(40, 190, 300, 150, [
        para("This weekend", bold: true),
        para("Turn the compost", list: .bullet),
        para("Mark out the four beds", list: .bullet),
        para("Order cane supports", list: .bullet),
        para("Check the water butt", list: .bullet),
    ]),
]
if let plan {
    overview.append(.image(ImageObject(id: UUID(), frame: Frame(x: 380, y: 190, width: 360, height: 225), asset: plan,
                                       altText: "Garden bed layout")))
}

let tableText: [[String]] = [
    ["Crop", "Sow", "Harvest"],
    ["Broad beans", "March", "June"],
    ["Courgettes", "May", "August"],
    ["Leeks", "April", "November"],
]
var tableRows: [[TableCell]] = []
for (r, row) in tableText.enumerated() {
    var cells: [TableCell] = []
    for text in row { cells.append(TableCell(paragraphs: [para(text, bold: r == 0)])) }
    tableRows.append(cells)
}
let table = PageObject.table(TableObject(
    id: UUID(), frame: Frame(x: 40, y: 150, width: 480, height: 120), columnWidths: [160, 160, 160],
    rows: tableRows, bordersVisible: true))

try add("Garden Project", folders: [
    ("Planning", "#3D7048", [
        ("Spring overview", overview),
        ("Sowing calendar", [box(40, 40, 400, 80, [para("Sowing calendar", bold: true, size: 22)]), table]),
    ]),
    ("Suppliers", "#C4622D", [
        ("Seed order", [box(40, 40, 420, 160, [
            para("Seed order", bold: true, size: 22),
            para("Broad beans, 2 packets", list: .numbered),
            para("Courgette F1, 1 packet", list: .numbered),
            para("Leek seed, 1 packet", list: .numbered),
        ])]),
    ]),
])

try add("Trip Planning", folders: [
    ("Lisbon", "#34547E", [
        ("Itinerary", [box(40, 40, 440, 220, [
            para("Lisbon, long weekend", bold: true, size: 22),
            para("Friday: arrive, walk through Alfama", list: .bullet),
            para("Saturday: tram 28, then the river at sunset", list: .bullet),
            para("Sunday: day trip to Sintra", list: .bullet),
        ])]),
    ]),
], loose: [
    ("Packing list", [box(40, 40, 360, 200, [
        para("Packing list", bold: true, size: 22),
        para("Passport", list: .bullet),
        para("Phone charger", list: .bullet),
        para("Light jacket", list: .bullet),
    ])]),
])

try add("Recipes", folders: [
    ("Weeknight", "#684674", [
        ("Lentil soup", [box(40, 40, 440, 240, [
            para("Lentil soup", bold: true, size: 22),
            para("Soften an onion and a carrot in oil", list: .numbered),
            para("Add red lentils, stock and cumin", list: .numbered),
            para("Simmer for 20 minutes, then blend half", list: .numbered),
        ])]),
    ]),
])

_ = try pkg.deleteSection(placeholder)
print("Wrote \(url.path)")
