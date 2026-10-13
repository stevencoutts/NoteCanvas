import AppKit

public enum RunFormat {
    case bold, italic, underline, strike
    case size(Double)
    case color(NSColor)
}

enum FormatApplier {
    /// Applies a run-level format to the selection (or the typing attributes when nothing is selected).
    static func apply(_ f: RunFormat, to tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var t = tv.typingAttributes
            mutate(&t, f, turnOn: !isOn(f, t))
            tv.typingAttributes = t
            return
        }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        var allOn = true
        storage.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            runs.append((r, attrs))
            if !isOn(f, attrs) { allOn = false }
        }
        storage.beginEditing()
        for (r, attrs) in runs {
            var a = attrs
            mutate(&a, f, turnOn: !allOn)
            storage.setAttributes(a, range: r)
        }
        storage.endEditing()
        tv.didChangeText()                         // fires textDidChange -> controller -> model
    }

    private static func isOn(_ f: RunFormat, _ a: [NSAttributedString.Key: Any]) -> Bool {
        switch f {
        case .bold: return ((a[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold)) ?? false
        case .italic: return ((a[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic)) ?? false
        case .underline: return ((a[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
        case .strike: return ((a[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
        case .size, .color: return false           // always "apply", never "toggle off"
        }
    }

    private static func mutate(_ a: inout [NSAttributedString.Key: Any], _ f: RunFormat, turnOn: Bool) {
        let fm = NSFontManager.shared
        let font = (a[.font] as? NSFont) ?? NSFont.systemFont(ofSize: AttributedBridge.baseSize)
        switch f {
        case .bold:
            a[.font] = turnOn ? fm.convert(font, toHaveTrait: .boldFontMask) : fm.convert(font, toNotHaveTrait: .boldFontMask)
        case .italic:
            a[.font] = turnOn ? fm.convert(font, toHaveTrait: .italicFontMask) : fm.convert(font, toNotHaveTrait: .italicFontMask)
        case .underline:
            a[.underlineStyle] = turnOn ? NSUnderlineStyle.single.rawValue : 0
        case .strike:
            a[.strikethroughStyle] = turnOn ? NSUnderlineStyle.single.rawValue : 0
        case .size(let s):
            let heading = (a[.pmHeading] as? Int) ?? 0
            a[.font] = fm.convert(font, toSize: CGFloat(s) * AttributedBridge.headingScale[min(max(heading, 0), 3)])
        case .color(let c):
            a[.foregroundColor] = c
        }
    }
}
