import ApplicationServices
import Foundation

/// Shared helpers for reading AX attributes off an `AXUIElement`.
///
/// Keeps the `AXUIElementCopyAttributeValue` + `as?` cast dance in one
/// place so callers (`CategoryResolver`, `ContextSnapshot`,
/// `AccessibilityTree`) don't each re-implement the same five lines.
///
/// **Which helper to use:**
/// - Reading a known string-typed attribute (`role`, `subrole`,
///   `identifier`, `title`, the value of a text field) → `AXAttr.string`.
/// - Reading attributes that the OS may surface as String OR a
///   numeric/boolean type (e.g. `kAXValueAttribute` on a slider /
///   stepper / progress indicator) → `AXAttr.stringDescribing`.
enum AXAttr {

    /// Read a String-typed AX attribute. Returns nil if the attribute
    /// is missing or not a String — does NOT coerce numeric values.
    static func string(_ element: AXUIElement, _ key: String) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard err == .success, let raw else { return nil }
        return raw as? String
    }

    /// Read an AX attribute whose value is itself an `AXUIElement`
    /// (e.g. `kAXParentAttribute`). Returns nil if the attribute is
    /// missing or not an AXUIElement. Guarded + non-forced cast, per the
    /// no-force-unwrap convention.
    static func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard err == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        // CFGetTypeID above is the real type check. `AnyObject → AXUIElement`
        // can't use `as?` (a compiler-proven-infallible downcast; warnings-as-
        // errors rejects it) nor `as` (not convertible), so the guarded,
        // non-forced `unsafeDowncast` is the idiomatic CF form — no `as!`, and
        // no trap because the CFTypeID was just verified.
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    /// Read an AX attribute that may be a String OR a numeric type,
    /// coercing the latter to its string form. Used by the generic AX
    /// walker so widgets that expose `kAXValueAttribute` as
    /// `NSNumber` still produce something useful (e.g. `"5"` for a
    /// slider value) in the dump.
    static func stringDescribing(_ element: AXUIElement, _ key: String) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard err == .success, let raw else { return nil }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }
}
