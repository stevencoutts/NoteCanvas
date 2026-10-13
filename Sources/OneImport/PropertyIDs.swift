import OneStore

/// PropertyID constants (MS-ONE section 2.1.12) and the sets of properties each mapper reads.
enum PID {
    // layout
    static let offsetH: PropertyID = 0x14001C14           // OffsetFromParentHoriz
    static let offsetV: PropertyID = 0x14001C15           // OffsetFromParentVert
    static let maxWidth: PropertyID = 0x14001C1B          // LayoutMaxWidth
    static let maxHeight: PropertyID = 0x14001C1C         // LayoutMaxHeight
    static let reservedWidth: PropertyID = 0x14001CDB     // LayoutOutlineReservedWidth
    // structure
    static let elementChildren: PropertyID = 0x24001C20
    static let contentChildren: PropertyID = 0x24001C1F
    static let listNodes: PropertyID = 0x24001C26
    static let childLevel: PropertyID = 0x0C001C03        // OutlineElementChildLevel
    static let childGraphSpaces: PropertyID = 0x2C001D63  // ChildGraphSpaceElementNodes (object-space IDs)
    // text
    static let richUnicode: PropertyID = 0x1C001C22
    static let richAscii: PropertyID = 0x1C003498
    static let runIndex: PropertyID = 0x1C001E12
    static let runFormatting: PropertyID = 0x24001E13
    static let paragraphStyle: PropertyID = 0x2000342C
    static let paragraphStyleId: PropertyID = 0x1C00345A
    static let paragraphAlignment: PropertyID = 0x0C003477
    static let isTitleText: PropertyID = 0x08001CB4
    static let isTitleDate: PropertyID = 0x08001CB5
    static let isTitleTime: PropertyID = 0x08001C87
    static let numberListFormat: PropertyID = 0x1C001C1A
    // run style
    static let bold: PropertyID = 0x08001C04
    static let italic: PropertyID = 0x08001C05
    static let underline: PropertyID = 0x08001C06
    static let strikethrough: PropertyID = 0x08001C07
    static let superscript: PropertyID = 0x08001C08
    static let subscriptText: PropertyID = 0x08001C09
    static let font: PropertyID = 0x1C001C0A
    static let fontSize: PropertyID = 0x10001C0B          // half-points
    static let fontColor: PropertyID = 0x14001C0C         // COLORREF
    static let highlight: PropertyID = 0x14001C0D         // COLORREF
    static let hyperlink: PropertyID = 0x08001E14
    static let hyperlinkURL: PropertyID = 0x1C001E20      // WzHyperlinkUrl
    static let charset: PropertyID = 0x0C001D01
    // objects
    static let pictureContainer: PropertyID = 0x20001C3F
    static let webPictureContainer: PropertyID = 0x200034C8
    static let imageAltText: PropertyID = 0x1C001E58
    static let tableColumnWidths: PropertyID = 0x1C001D66
    static let tableBordersVisible: PropertyID = 0x08001D5E
    static let embeddedFileContainer: PropertyID = 0x20001D9B
    static let embeddedFileName: PropertyID = 0x1C001D9C
    static let pageLevel: PropertyID = 0x14001DFF

    static let consumedByRichText: Set<PropertyID> = [richUnicode, richAscii, runIndex, runFormatting, paragraphStyle,
                                                      paragraphAlignment, isTitleText, isTitleDate, isTitleTime]
    static let consumedByStyle: Set<PropertyID> = [bold, italic, underline, strikethrough, superscript, subscriptText, font,
                                                   fontSize, fontColor, highlight, hyperlink, hyperlinkURL, charset,
                                                   paragraphStyleId, paragraphAlignment]
    static let consumedByOutline: Set<PropertyID> = [offsetH, offsetV, maxWidth, reservedWidth, elementChildren]
    static let consumedByElement: Set<PropertyID> = [contentChildren, elementChildren, listNodes]
    static let consumedByNumberList: Set<PropertyID> = [numberListFormat]
    static let consumedByImage: Set<PropertyID> = [offsetH, offsetV, maxWidth, maxHeight, pictureContainer, webPictureContainer, imageAltText]
    static let consumedByTable: Set<PropertyID> = [offsetH, offsetV, elementChildren, tableColumnWidths, tableBordersVisible]
    static let consumedByAttachment: Set<PropertyID> = [offsetH, offsetV, embeddedFileContainer, embeddedFileName]
    static let consumedByPage: Set<PropertyID> = [elementChildren]
}
