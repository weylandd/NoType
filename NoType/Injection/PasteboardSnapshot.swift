import AppKit

/// A faithful snapshot of every type on a pasteboard. Captures all UTIs (not
/// just `.string`) so users with images, RTF, file URLs, custom UTIs, etc., on
/// their clipboard get the original contents back after we paste.
struct PasteboardSnapshot {
    private let items: [NSPasteboardItem]

    static func capture(_ pb: NSPasteboard) -> PasteboardSnapshot {
        let copies: [NSPasteboardItem] = pb.pasteboardItems?.compactMap { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        return PasteboardSnapshot(items: copies)
    }

    func restore(to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items)
    }
}
