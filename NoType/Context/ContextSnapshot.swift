import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Identity of the app the user is dictating into. Captured at session start
/// from `NSWorkspace.shared.frontmostApplication`.
struct AppInfo: Sendable, Equatable {
    let name: String
    let bundleID: String
}

/// Already-redacted content of a single window. Built by `AccessibilityTree`
/// after every value has passed through `SecureFieldMasker`.
struct RedactedWindowDump: Sendable, Equatable {
    let title: String?
    /// Pre-formatted text lines, indented for prompt-readability. Already
    /// scrubbed and length-limited.
    let lines: [String]
}

/// Already-redacted content of one app's on-screen windows.
struct RedactedAppDump: Sendable, Equatable {
    let appName: String
    let bundleID: String
    let windows: [RedactedWindowDump]
}

/// Result of walking the on-screen accessibility tree. The constructor is
/// internal to the Context module — outside callers can only get one of these
/// from `AccessibilityTree.snapshot()`. There is no public accessor for the
/// raw nodes, only the pre-formatted prompt rendering. This is the
/// type-level guarantee referenced in `NoType/Context/CLAUDE.md`: there is no
/// path that ships unredacted AX text to the network.
public struct RedactedAXSnapshot: Sendable, Equatable {
    let apps: [RedactedAppDump]
    let truncated: Bool

    init(apps: [RedactedAppDump], truncated: Bool = false) {
        self.apps = apps
        self.truncated = truncated
    }

    /// Plain-text rendering destined for the Gemini prompt. No JSON, no XML
    /// — compact and readable for the model.
    public func formattedForPrompt() -> String {
        if apps.isEmpty {
            return "(no on-screen context available)"
        }

        var out = ""
        for app in apps {
            out += "=== \(app.appName) (\(app.bundleID)) ===\n"
            if app.windows.isEmpty {
                out += "  (no windows)\n"
                continue
            }
            for window in app.windows {
                if let title = window.title, !title.isEmpty {
                    out += "Window: \"\(title)\"\n"
                } else {
                    out += "Window:\n"
                }
                for line in window.lines {
                    out += "  \(line)\n"
                }
            }
            out += "\n"
        }
        if truncated {
            out += "(context truncated — node budget exceeded)\n"
        }
        return out
    }

    /// True when the AX walk produced at least one window with content
    /// for the given bundle id. Used by `RecordingSession` to decide
    /// whether to include the OCR fallback sub-block in the prompt.
    /// False when the dump is missing entirely, has no windows, or every
    /// window has zero collected lines — the typical Electron / web-view /
    /// custom-NSText failure mode.
    func hasContent(for bundleID: String) -> Bool {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            return false
        }
        return app.windows.contains { !$0.lines.isEmpty }
    }
}

/// Already-scrubbed OCR result for one window. Built by `ScreenCaptureContext`
/// after every recognised line has passed through `SecureFieldMasker.scrubContent`.
///
/// Type-level guarantee mirrors `RedactedAXSnapshot`: the initializer is
/// module-internal and there is no public accessor for raw pixel-recognised
/// text — only `formattedForPrompt()` produces network-shippable output.
public struct RedactedScreenText: Sendable, Equatable {
    let appName: String
    let bundleID: String
    let windowTitle: String?
    /// Lines as returned by Vision (reading order), each already scrubbed.
    /// Empty strings are dropped before storage.
    let scrubbedLines: [String]
    /// Set when the OCR pass hit a line-count or character budget and
    /// stopped early. Surfaced in the prompt so the model knows it has
    /// only partial coverage.
    let truncated: Bool

    init(
        appName: String,
        bundleID: String,
        windowTitle: String?,
        scrubbedLines: [String],
        truncated: Bool = false
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.scrubbedLines = scrubbedLines
        self.truncated = truncated
    }

    /// Plain-text rendering appended to the existing `On-screen context:`
    /// prompt part. Starts with a separator + sub-header so the model can
    /// tell AX content from OCR content; rest of the format mirrors the
    /// AX block for visual consistency.
    public func formattedForPrompt() -> String {
        var out = "\n--- Screen text (OCR — active window) ---\n"
        out += "=== \(appName) (\(bundleID)) ===\n"
        if let title = windowTitle, !title.isEmpty {
            out += "Window: \"\(title)\"\n"
        } else {
            out += "Window:\n"
        }
        if scrubbedLines.isEmpty {
            out += "  (no text recognised)\n"
        } else {
            for line in scrubbedLines {
                out += "  \(line)\n"
            }
        }
        if truncated {
            out += "(OCR truncated — budget exceeded)\n"
        }
        return out
    }
}

/// The textual neighborhood of the user's cursor in the focused text field.
///
/// Sent to Gemini as a separate cached-prefix section so the model knows
/// the exact strings on either side of the insertion point — driving
/// start-capitalization, whitespace boundaries, and final punctuation
/// choices in the dictated text.
///
/// Captured once at session start, in parallel with the on-screen AX
/// walk. The cursor cannot move during a session (the user is holding
/// the hotkey, not typing), so the value is stable for the whole session
/// and lives in the cached prompt prefix.
///
/// Edge cases — collapse to `.empty` or `.unknown`. The corresponding
/// prompt section is never dropped, only its values become empty strings:
///
/// - No focused element / `kAXFocusedUIElementAttribute` fails → `.unknown`.
/// - Element is not a text field (no `kAXValueAttribute`) → `.unknown`.
///   This is the typical Electron / web-view / Telegram-desktop /
///   Slack-message-input / Discord / Notion failure mode. We can't see
///   the field's content, but the field very likely has content the
///   cursor sits inside of.
/// - `kAXSelectedTextRangeAttribute` is missing → assume cursor at end
///   of value; still `.known` (we have textBefore = entire value).
/// - Element is `AXSecureTextField` → `.empty` (we deliberately refuse
///   to read it; treating as empty is safer than `.unknown` because
///   dictating into a password field is a user mistake we don't want to
///   compensate for).
/// - Surrogate-pair cut at the soft limit (lossy decode used) → `.known`.
///
/// The `isKnown` discriminator lets `TextInjector.finalizeForInsertion`
/// tell "field is genuinely empty" from "we couldn't read the field" —
/// the latter triggers a defensive leading-space when stitched starts
/// with a word-opener, since we can't know what character is in front of
/// the cursor. The prompt section is serialised identically in both cases
/// (empty quoted strings), so the cached-prefix shape stays stable.
struct InsertionTarget: Sendable, Equatable {
    /// Up to `maxSideLength` chars immediately before the cursor.
    let textBefore: String
    /// Up to `maxSideLength` chars immediately after the cursor.
    let textAfter: String
    /// `false` when the AX subsystem failed to read the focused field
    /// (no focused element, no `kAXValueAttribute`). `textBefore` /
    /// `textAfter` are still empty strings in that case, but the meaning
    /// is "we don't know what's around the cursor", not "the field is
    /// empty". `true` for every successful read AND for the secure-field
    /// refuse-to-read path (we know what the field is, we just won't
    /// touch it).
    let isKnown: Bool

    static let empty = InsertionTarget(textBefore: "", textAfter: "", isKnown: true)
    /// AX couldn't read the focused field. `finalizeForInsertion` treats
    /// this as "probably non-empty, we just can't see it" and defensively
    /// prepends a leading space.
    static let unknown = InsertionTarget(textBefore: "", textAfter: "", isKnown: false)

    /// Memberwise init with `isKnown` defaulting to `true`. Keeps callers
    /// that don't care about the discriminator (tests, the prompt
    /// renderer's fixtures) terse without sacrificing the type-level
    /// distinction in `captureSync`.
    init(textBefore: String, textAfter: String, isKnown: Bool = true) {
        self.textBefore = textBefore
        self.textAfter = textAfter
        self.isKnown = isKnown
    }

    /// Soft cap on each side. Keeps the cached-prefix budget bounded
    /// even when the user is dictating into a huge document.
    static let maxSideLength = 500

    private static let log = Logger(subsystem: "app.notype", category: "context")

    /// Snapshot the focused field. Safe to call from any actor.
    static func capture() async -> InsertionTarget {
        // Not trusted → we'll never read AX anything. Treat as unknown
        // so the boundary heuristic in `finalizeForInsertion` is
        // defensive about a possibly-populated field.
        guard AXIsProcessTrusted() else { return .unknown }
        return await Task.detached(priority: .userInitiated) {
            captureSync()
        }.value
    }

    /// Synchronous capture — runs off the calling actor inside `capture()`.
    /// Exposed for unit tests that drive AX through fixtures.
    static func captureSync() -> InsertionTarget {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRaw: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        )
        guard focusErr == .success,
              let focused = focusedRaw,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            log.info("ax capture: no focused element (err=\(focusErr.rawValue, privacy: .public))")
            return .unknown
        }
        let element = focused as! AXUIElement

        // Refuse to read password fields outright — mirrors the
        // SecureFieldMasker skip rule used by the AX walker. The
        // focused-field path must never be a way around that guarantee.
        if let role = AXAttr.string(element, kAXRoleAttribute as String),
           role == "AXSecureTextField" {
            log.info("ax capture: focused element is AXSecureTextField, skipping")
            return .empty
        }
        if let subrole = AXAttr.string(element, kAXSubroleAttribute as String),
           subrole == "AXSecureTextField" {
            log.info("ax capture: focused subrole is AXSecureTextField, skipping")
            return .empty
        }

        let role = AXAttr.string(element, kAXRoleAttribute as String) ?? "?"

        // Terminal emulators (Ghostty, iTerm, Apple Terminal, Warp, kitty,
        // alacritty, hyper, wezterm) expose their visible scrollback as the
        // focused element's `kAXValueAttribute`. The "cursor" inside that
        // buffer is meaningless for our use case — the user's prompt sits
        // at the end of the scrollback, but AX often reports position 0 or
        // points into wrapped output. Bail to `.empty` (not `.unknown`):
        // the terminal prompt has no continuation text to glue against, so
        // adding a defensive leading space would be wrong on every short
        // dictation. We treat the field as genuinely empty.
        if let bundle = focusedBundleID(of: element),
           AXNoiseFilter.knownTerminalBundleIDs.contains(bundle) {
            log.info("ax capture: terminal app \(bundle, privacy: .public) detected — bailing to .empty")
            return .empty
        }

        guard let value = AXAttr.string(element, kAXValueAttribute as String) else {
            // Many Electron / web-view text fields don't expose AXValue.
            // Without `value` we can't slice — but we can still
            // distinguish "field is empty" from "field has content we
            // can't see" via `kAXNumberOfCharactersAttribute`, which
            // Electron's a11y shim exposes more reliably than AXValue.
            //
            // 0 chars → `.empty` (genuinely empty Slack / Telegram
            //   compose, fresh Discord input, just-opened browser URL
            //   bar that was empty). Cursor is at position 0, no
            //   continuation; `finalizeForInsertion` won't add the
            //   defensive leading space.
            // > 0 chars → `.unknown` (field has content, but we can't
            //   see where the cursor is). Keeps the defensive
            //   leading-space behavior so we don't glue to existing
            //   text (`"Прошлое предложение.Новый ввод"` bug).
            // attribute itself missing → `.unknown` (status quo for
            //   apps that expose nothing — defensive wins).
            if let nchars = intAttr(element, kAXNumberOfCharactersAttribute as String) {
                if nchars == 0 {
                    log.info("ax capture: \(role, privacy: .public) has no AXValue, 0 chars reported → .empty")
                    return .empty
                }
                log.info("ax capture: \(role, privacy: .public) has no AXValue, \(nchars) chars reported → .unknown (defensive)")
                return .unknown
            }
            log.info("ax capture: \(role, privacy: .public) has no AXValue or char count (likely Electron/web) → .unknown")
            return .unknown
        }

        // Shape-based terminal / scrollback detection — covers terminals
        // not in `AXNoiseFilter.knownTerminalBundleIDs` (custom builds,
        // niche emulators) and similar viewport-style components that
        // expose visible text through `kAXValueAttribute`. Real text
        // fields rarely have this shape: compose boxes are 1–10 lines,
        // search/URL are single-line. Bail to `.empty` for the same
        // reason terminals do: the visible scrollback is not
        // continuation context for the cursor.
        if Self.looksLikeScrollback(value: value, role: role) {
            log.info("ax capture: focused value shape looks like scrollback (lines=\(value.unicodeScalars.lazy.filter { $0 == "\n" }.count), len=\(value.utf16.count)) — bailing to .empty")
            return .empty
        }

        // macOS counts AX selection ranges in UTF-16 code units.
        // Try `kAXSelectedTextRangeAttribute` first; fall back to
        // `kAXInsertionPointLineNumberAttribute` + AXLineRange to recover
        // the cursor in apps that omit the simple selection attribute.
        var range = CFRange(location: -1, length: 0)
        var rangeRaw: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        )
        if rangeErr == .success,
           let raw = rangeRaw,
           CFGetTypeID(raw) == AXValueGetTypeID() {
            let axValue = raw as! AXValue
            if AXValueGetType(axValue) == .cfRange {
                AXValueGetValue(axValue, .cfRange, &range)
            }
        }

        let cursor: Int
        let cursorSource: String
        if range.location < 0 {
            // Fallback: if the field exposes an insertion-point line
            // number we can resolve it to a character offset via the
            // line-range parametrised attribute. Several Cocoa text
            // views support this even when AXSelectedTextRange is
            // missing.
            if let lineCursor = insertionPointFromLineNumber(element: element, value: value) {
                cursor = lineCursor
                cursorSource = "line-fallback"
            } else {
                // Worst case: assume cursor at end of value. The model
                // sees `Text after cursor: ""` and treats the dictation
                // as appending to the end of the field — which is the
                // common case for empty compose boxes.
                cursor = value.utf16.count
                cursorSource = "end-of-value"
            }
        } else {
            cursor = range.location
            cursorSource = "ax-range"
        }

        let target = slice(value: value, cursor: cursor)
        log.info(
            "ax capture: role=\(role, privacy: .public) cursor=\(cursor) (\(cursorSource, privacy: .public)) value=\(value.utf16.count)c → before=\(target.textBefore.count)c after=\(target.textAfter.count)c"
        )
        // Truncated content preview at debug level only — privacy:.private
        // so it's redacted in release. Helps diagnose "wrong cursor"
        // reports without exposing the field in production logs.
        log.debug(
            "ax capture preview: before=\"\(target.textBefore.suffix(60), privacy: .private)\" after=\"\(target.textAfter.prefix(60), privacy: .private)\""
        )
        return target
    }

    /// Resolve the cursor position via `kAXInsertionPointLineNumberAttribute`
    /// + `kAXRangeForLineParameterizedAttribute`. Returns the start offset
    /// of the cursor's line as a best-effort cursor position. Used when
    /// `kAXSelectedTextRangeAttribute` is missing.
    private static func insertionPointFromLineNumber(element: AXUIElement, value: String) -> Int? {
        var lineRaw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element,
            kAXInsertionPointLineNumberAttribute as CFString,
            &lineRaw
        )
        guard err == .success, let raw = lineRaw else { return nil }
        var line: Int = 0
        if CFGetTypeID(raw) == CFNumberGetTypeID() {
            CFNumberGetValue((raw as! CFNumber), .nsIntegerType, &line)
        } else { return nil }

        var lineRangeRaw: CFTypeRef?
        var lineNumberValue = line
        let lineRangeErr = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForLineParameterizedAttribute as CFString,
            CFNumberCreate(nil, .nsIntegerType, &lineNumberValue),
            &lineRangeRaw
        )
        guard lineRangeErr == .success,
              let lrr = lineRangeRaw,
              CFGetTypeID(lrr) == AXValueGetTypeID() else { return nil }
        let axValue = lrr as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var lineRange = CFRange(location: 0, length: 0)
        AXValueGetValue(axValue, .cfRange, &lineRange)
        return max(0, min(lineRange.location, value.utf16.count))
    }

    /// Heuristic: a focused element's `kAXValueAttribute` "looks like
    /// scrollback" when it has the shape of terminal output rather than
    /// a text field. Catches terminals not in
    /// `AXNoiseFilter.knownTerminalBundleIDs` and similar viewport-style
    /// components.
    ///
    /// Triggers when: many newlines (≥5) AND total length large (>1000
    /// chars) AND role suggests a text-area (so we don't false-positive
    /// on a giant single-line URL field). Tuned to be conservative — a
    /// legit multi-line editor (Bear, Notes) with ≥5 lines of body text
    /// rarely exceeds 1000 chars without the user opening a long doc,
    /// and at that point lite path doesn't fire (long sessions take the
    /// full path with AX tree anyway).
    static func looksLikeScrollback(value: String, role: String) -> Bool {
        let isTextArea = role == "AXTextArea" || role == "AXStaticText"
        guard isTextArea else { return false }
        let nlCount = value.unicodeScalars.lazy.filter { $0 == "\n" }.count
        return nlCount >= 5 && value.utf16.count > 1000
    }

    /// PID of the app owning an AX element → its bundle id. Used to
    /// match against `AXNoiseFilter.knownTerminalBundleIDs` without
    /// round-tripping through `NSWorkspace.frontmostApplication`
    /// (which can race with app-switch events during session start).
    private static func focusedBundleID(of element: AXUIElement) -> String? {
        var pid: pid_t = 0
        let err = AXUIElementGetPid(element, &pid)
        guard err == .success, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Pure UTF-16 slicing + scrubbing. Exposed (internal) for tests so
    /// they can drive the trimming and surrogate-boundary logic without
    /// going through AX.
    static func slice(value: String, cursor: Int, maxSide: Int = maxSideLength) -> InsertionTarget {
        let total = value.utf16.count
        let clampedCursor = max(0, min(cursor, total))
        let beforeStart = max(0, clampedCursor - maxSide)
        let afterEnd    = min(total, clampedCursor + maxSide)

        let rawBefore = utf16Slice(value, from: beforeStart, to: clampedCursor)
        let rawAfter  = utf16Slice(value, from: clampedCursor, to: afterEnd)

        // Apply the same content-pattern scrubbing the AX walk uses, so a
        // bearer token / card number sitting at the edge of the focused
        // field doesn't sneak into the prompt unredacted. Skip-rule
        // enforcement happens upstream (in `captureSync`, by role check).
        // Here we run only the value-content layer.
        let textBefore = SecureFieldMasker.scrubContent(rawBefore)
        let textAfter  = SecureFieldMasker.scrubContent(rawAfter)

        return InsertionTarget(textBefore: textBefore, textAfter: textAfter, isKnown: true)
    }

    /// Read an integer AX attribute (e.g. `kAXNumberOfCharactersAttribute`).
    /// Returns nil if the attribute is missing or not a CFNumber.
    private static func intAttr(_ element: AXUIElement, _ key: String) -> Int? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard err == .success, let raw else { return nil }
        guard CFGetTypeID(raw) == CFNumberGetTypeID() else { return nil }
        var out: Int = 0
        guard CFNumberGetValue(raw as! CFNumber, .nsIntegerType, &out) else { return nil }
        return out
    }

    /// Slice a String on UTF-16 code-unit boundaries. Falls back to a
    /// lossy decode if the boundaries cut a surrogate pair (replaces with
    /// U+FFFD) — better than dropping the whole side.
    private static func utf16Slice(_ s: String, from start: Int, to end: Int) -> String {
        guard start < end, end <= s.utf16.count else { return "" }
        let u = s.utf16
        let i = u.index(u.startIndex, offsetBy: start)
        let j = u.index(u.startIndex, offsetBy: end)
        if let str = String(u[i..<j]) {
            return str
        }
        return String(decoding: Array(u[i..<j]), as: UTF16.self)
    }
}

/// Bundle of everything the Gemini request builder needs about the user's
/// surroundings. Computed once at session start; held by `RecordingSession`;
/// dropped on session end. Never persisted, never logged.
///
/// `category` + `userInstruction` + `categoryInstruction` are captured at
/// session start and frozen for the lifetime of the session — keeping
/// them stable is what lets the implicit-cache prefix stay byte-identical
/// across chunks of the same session (see `NoType/Gemini/CLAUDE.md`).
struct ContextSnapshot: Sendable, Equatable {
    let activeApp: AppInfo
    /// Resolved category for this session — cached `bundleID → category`
    /// from `InstructionsStore`, or `.search` when the AX-override
    /// matched the focused field, or `.uncategorized` when we have no
    /// classification yet. See `CategoryResolver`.
    let category: AppCategory
    /// Trimmed global user instruction. Empty == not set, in which case
    /// the `User instruction:` section is omitted entirely from the
    /// Gemini request.
    let userInstruction: String
    /// Resolved category instruction — user override or
    /// `AppCategory.defaultPrompt`. `nil` == no instruction to send
    /// (typical for `.uncategorized`); the `Category instruction:`
    /// section is omitted entirely.
    let categoryInstruction: String?
    /// Personal-dictionary entries shipped in the `User dictionary:`
    /// cache-prefix section. Empty array → section body is `(empty)`;
    /// the section itself is always present so the prefix shape stays
    /// stable across sessions (and across chunks of one session). See
    /// `NoType/Dictionary/CLAUDE.md` and ADR-016.
    let dictionary: [String]
    /// Find/replace pairs applied to the final transcript after the
    /// Gemini round-trip and before paste. Frozen at session start —
    /// edits during a session don't reach this snapshot. Not part of
    /// the Gemini request; lives in `ContextSnapshot` purely as the
    /// single source of truth at paste time, mirroring how the
    /// insertion target is captured once and reused at `stop()`.
    let replacements: [DictionaryReplacement]
    let tree: RedactedAXSnapshot
    let insertionTarget: InsertionTarget
    /// Optional OCR fallback for the active window. Populated only when
    /// Screen Recording permission was granted AND the AX dump for the
    /// active app's bundle id came back contentless (Electron / web-view /
    /// custom-NSText cases). When set, the Gemini request builder appends
    /// `screenText.formattedForPrompt()` inside the existing `On-screen context:`
    /// prompt part — no new top-level prompt section is introduced, so the
    /// cached-prefix shape (up to 7 text parts) stays intact.
    let screenText: RedactedScreenText?

    init(
        activeApp: AppInfo,
        category: AppCategory,
        userInstruction: String,
        categoryInstruction: String?,
        dictionary: [String] = [],
        replacements: [DictionaryReplacement] = [],
        tree: RedactedAXSnapshot,
        insertionTarget: InsertionTarget,
        screenText: RedactedScreenText? = nil
    ) {
        self.activeApp = activeApp
        self.category = category
        self.userInstruction = userInstruction
        self.categoryInstruction = categoryInstruction
        self.dictionary = dictionary
        self.replacements = replacements
        self.tree = tree
        self.insertionTarget = insertionTarget
        self.screenText = screenText
    }

    /// Cheap fallback when the AX walk fails or times out, or when the
    /// final-chunk dispatch path can't wait for `contextTask` to settle.
    /// Collapses to the minimum stable shape: `Category: uncategorized`,
    /// no user instruction, no category instruction, empty dictionary,
    /// no replacements, empty tree, empty insertion target. Cache-prefix-
    /// wise this is the 6-text-part case (App+Category, User dictionary,
    /// Insertion target, On-screen context, Prior chunks, per-call
    /// instruction) — the dictionary section is always present but
    /// renders `(empty)` when no entries.
    static func minimal(activeApp: AppInfo) -> ContextSnapshot {
        ContextSnapshot(
            activeApp: activeApp,
            category: .uncategorized,
            userInstruction: "",
            categoryInstruction: nil,
            dictionary: [],
            replacements: [],
            tree: RedactedAXSnapshot(apps: []),
            insertionTarget: .empty,
            screenText: nil
        )
    }
}
