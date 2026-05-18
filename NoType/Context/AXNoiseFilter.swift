import Foundation

/// Pure, deterministic noise filtering for AX-tree nodes — runs **after**
/// `SecureFieldMasker.mask` has decided keep / replace / skip. The filter
/// only drops UI scaffolding, viewport blobs, and OCR-as-AX gibberish that
/// carry no transcription disambiguation value; secure-field skips are
/// never overridden because the masker runs first inside
/// `AccessibilityTree.decideForNode`.
///
/// Three independent layers run in this order at the call site
/// (`AccessibilityTree.decideForNode`):
///
/// 1. **Structural / gibberish per-node drop** — `shouldDropNode`.
/// 2. **Viewport scrollback drop (terminal-parent gated)** —
///    `isViewportScrollback`. Distinct from
///    `InsertionTarget.looksLikeScrollback` because the cost matrices
///    differ: a false positive on the focused-field bail-out is cheap
///    (`.empty` cursor context); a false positive in the walker silently
///    drops an open document.
/// 3. **Repetitive-pack post-pass** — `collapseRepetitivePacks` runs once
///    per window after the walk has produced its `lines` array. Replaces
///    runs of ≥6 same-role same-stem lines with a single summary line of
///    the form `- Image (× N items, stem "Screenshot YYYY-MM-DD")`. The
///    stem token survives so first-time dictation of a list item still
///    benefits from on-screen spelling disambiguation.
///
/// **Hard rule, mirroring `SecureFieldMasker`:** any change to this file
/// must add at least one new test case to `NoTypeTests/AXNoiseFilterTests`.
/// No exceptions.
enum AXNoiseFilter {

    // MARK: - Known terminal emulators (shared)

    /// Bundle ids of terminal emulators whose visible scrollback ships
    /// through AX as one giant `kAXValueAttribute` blob. Two call sites
    /// gate on this set:
    ///
    /// 1. `AXNoiseFilter.isViewportScrollback` — the walker's R5 drop
    ///    gate. A false positive here would silently drop an open Notes
    ///    / Bear / BBEdit / Pages document, so the gate is intentionally
    ///    conservative (terminal-parent + scrollback shape).
    /// 2. `InsertionTarget.captureSync` — the focused-field bail-out.
    ///    Terminals expose visible scrollback as the focused element's
    ///    `kAXValueAttribute`; the cursor inside that buffer is
    ///    meaningless for our use case, so we bail to `.empty`.
    ///
    /// Lives here (not on `InsertionTarget`) because the noise filter
    /// owns the policy of "what is a terminal?"; the focused-field
    /// reader is just another consumer.
    static let knownTerminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "io.alacritty",
    ]

    // MARK: - Per-node drop (R4 + R7)

    /// Returns `true` when the node carries no transcription signal:
    /// structural window chrome with no title/value (R4), or a short
    /// content carrier dominated by non-alphabetic/non-decimal characters
    /// (R7). Pure — no AX live calls; inputs are the same values
    /// `AccessibilityTree.walk` already read off the node.
    static func shouldDropNode(
        role: String?,
        subrole: String?,
        title: String?,
        value: String
    ) -> Bool {
        if isStructuralChrome(role: role, subrole: subrole, title: title, value: value) {
            return true
        }
        return isGibberishOnlyNode(title: title, value: value)
    }

    // MARK: - Structural chrome (R4)

    /// Subroles that are pure window-chrome widgets — zoom / minimize /
    /// close glyphs, scrollbar arrows. These never carry transcription
    /// content even when the role is the generic `AXButton`.
    private static let chromeSubroleSet: Set<String> = [
        "AXCloseButton",
        "AXMinimizeButton",
        "AXFullScreenButton",
        "AXZoomButton",
        "AXToolbarButton",
        "AXIncrementArrow",
        "AXDecrementArrow",
        "AXIncrementPage",
        "AXDecrementPage",
    ]

    /// Roles that are purely mechanical / geometry indicators. Their
    /// `kAXValueAttribute` (if any) is a numeric position, not content.
    private static let pureMechanicRoles: Set<String> = [
        "AXScrollBar",
        "AXValueIndicator",
    ]

    /// Container roles whose own line is signal-free when they carry no
    /// title or value of their own. Children are still walked — only the
    /// container's own rendered line is suppressed.
    private static let labellessContainerRoles: Set<String> = [
        "AXSplitGroup",
        "AXTabGroup",
        "AXToolbar",
        "AXScrollArea",
        "AXLayoutArea",
        "AXLayoutItem",
    ]

    private static func isStructuralChrome(
        role: String?,
        subrole: String?,
        title: String?,
        value: String
    ) -> Bool {
        let titleTrimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueTrimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = (titleTrimmed.map { !$0.isEmpty } ?? false) || !valueTrimmed.isEmpty

        // Pure-mechanic roles ALWAYS drop. Their `kAXValueAttribute` is a
        // numeric position string ("0", "0.5", "1414") — not transcription
        // content. The chrome / container categories below are different:
        // their content (when present) is human-readable, so we respect it.
        if let role, pureMechanicRoles.contains(role) {
            return true
        }
        // Chrome subroles drop ONLY when they carry no content of their
        // own. macOS doesn't usually give CloseButton a title — but if an
        // accessibility-friendly app does (e.g., `Button/CloseButton`
        // titled "Close Document"), that title is real signal and must
        // survive. Conservative about role-based drops.
        if !hasContent, let subrole, chromeSubroleSet.contains(subrole) {
            return true
        }
        // Label-less containers: drop only when there's no title and no
        // value of their own. A titled tab group like "tab bar" or a
        // toolbar with a search field as a value-bearing child still
        // renders as a useful structural hint.
        if !hasContent, let role, labellessContainerRoles.contains(role) {
            return true
        }
        return false
    }

    // MARK: - Gibberish density (R7)

    /// Drops the node when its content carriers (title and/or value) are
    /// all short AND all gibberish-dominant. A node that has at least one
    /// real-text carrier survives — e.g. `Image "Movies"` with a gibberish
    /// value would still be rendered because the title is real text.
    private static func isGibberishOnlyNode(title: String?, value: String) -> Bool {
        let titleProbe: String? = {
            guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { return nil }
            return t
        }()
        let valueProbe: String? = {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }()
        // No content at all → not our job (formatLine / structural drop handles it).
        guard titleProbe != nil || valueProbe != nil else { return false }
        let titleIsSignal = titleProbe.map { !isGibberishDominant($0) } ?? false
        let valueIsSignal = valueProbe.map { !isGibberishDominant($0) } ?? false
        return !titleIsSignal && !valueIsSignal
    }

    /// Length floor (in non-whitespace scalars) above which a value is
    /// considered "long" and always kept regardless of symbol density.
    /// Long content with high symbol density is more often code, JSON, or
    /// structured data the user may dictate about than mojibake.
    static let gibberishLengthFloor = 8

    /// Drop threshold for non-alphabetic/non-decimal ratio on short
    /// content. `> 0.4` means more than 40% of the (non-whitespace)
    /// characters are neither letters nor digits.
    static let gibberishNonAlphaThreshold = 0.4

    /// True when `s` is short AND dominated by non-alphabetic /
    /// non-decimal characters. Pure — exposed for direct unit testing.
    ///
    /// **Perf note:** the loop short-circuits the long-content escape
    /// valve before allocating any per-scalar storage — a multi-KB
    /// `kAXValueAttribute` (e.g., a giant Notes document accidentally
    /// routed here) bails on the (N + 1)th non-whitespace scalar
    /// without ever materializing the full filter. Single pass; no
    /// intermediate array.
    static func isGibberishDominant(_ s: String) -> Bool {
        var nonWhitespaceCount = 0
        var alphaOrDecimal = 0
        for scalar in s.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            nonWhitespaceCount += 1
            // Long content (above the floor) always passes — early exit
            // before doing any more bookkeeping. Saves both the
            // remaining scan and any allocation on multi-KB inputs.
            if nonWhitespaceCount > gibberishLengthFloor { return false }
            if scalar.properties.isAlphabetic || isAsciiDecimal(scalar) {
                alphaOrDecimal += 1
            }
        }
        guard nonWhitespaceCount > 0 else { return false }
        let nonAlphaRatio = Double(nonWhitespaceCount - alphaOrDecimal) / Double(nonWhitespaceCount)
        return nonAlphaRatio > gibberishNonAlphaThreshold
    }

    private static func isAsciiDecimal(_ s: Unicode.Scalar) -> Bool {
        s.value >= 0x30 && s.value <= 0x39
    }

    // MARK: - Viewport scrollback (R5)

    /// Returns `true` when the node looks like terminal scrollback AND its
    /// containing app is a known terminal emulator. The terminal-parent gate
    /// is what distinguishes this from `InsertionTarget.looksLikeScrollback`
    /// — the same shape predicate applied to two different cost matrices.
    /// In `InsertionTarget.captureSync` a false positive yields `.empty`
    /// cursor context (cheap). In the walker, a false positive drops the
    /// open Notes / Bear / BBEdit / Pages document — the exact cross-window
    /// signal case ADR-009 was built for.
    ///
    /// `containingBundleID` is the bundle id of the *app* owning the node,
    /// not the AX parent element. The naming reflects the semantic — we
    /// want "which app is this node inside?", not "what's the immediate
    /// AX parent element?".
    static func isViewportScrollback(
        role: String?,
        value: String,
        containingBundleID: String?
    ) -> Bool {
        guard let containingBundleID,
              Self.knownTerminalBundleIDs.contains(containingBundleID) else {
            return false
        }
        guard let role else { return false }
        return InsertionTarget.looksLikeScrollback(value: value, role: role)
    }

    // MARK: - Repetitive-pack collapse (R6)

    /// Runs of ≥6 lines collapse into a single summary line. Tuned for
    /// Finder screenshot listings (24+ items) and similar templated lists
    /// without false-positiving on small same-role groupings.
    static let packCollapseThreshold = 6

    /// Replaces runs of ≥6 same-role same-stem rendered lines with a
    /// single summary line. Mutates `lines` in place. Pure — only
    /// inspects the rendered string content, no AX calls.
    static func collapseRepetitivePacks(_ lines: inout [String]) {
        guard lines.count >= packCollapseThreshold else { return }
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var i = 0
        while i < lines.count {
            let runEnd = endOfRun(lines: lines, startAt: i)
            let runLength = runEnd - i
            if runLength >= packCollapseThreshold,
               let summary = makeSummaryLine(for: lines[i..<runEnd]) {
                out.append(summary)
            } else {
                out.append(contentsOf: lines[i..<runEnd])
            }
            i = runEnd
        }
        lines = out
    }

    /// Returns the exclusive end index of the run starting at `startAt`
    /// where each consecutive line shares the same pack key as
    /// `lines[startAt]`. Returns at minimum `startAt + 1`.
    private static func endOfRun(lines: [String], startAt: Int) -> Int {
        guard let firstKey = packKey(for: lines[startAt]) else {
            return startAt + 1
        }
        var j = startAt + 1
        while j < lines.count {
            guard let key = packKey(for: lines[j]), key == firstKey else { break }
            j += 1
        }
        return j
    }

    /// Title-only lines (no `= value`) produced by
    /// `AccessibilityTree.formatLine`. Captures indent, role token, and
    /// quoted title. Value-bearing lines are deliberately NOT packable —
    /// they're too varied to safely collapse.
    private static let packLineRegex = try! NSRegularExpression(
        pattern: #"^(\s*)-\s+(\S+)\s+"([^"]+)"\s*$"#
    )

    private struct PackKey: Equatable {
        let indent: Int
        let role: String
        let stem: String
    }

    private static func packKey(for line: String) -> PackKey? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = packLineRegex.firstMatch(in: line, range: range),
              match.numberOfRanges == 4 else { return nil }
        guard let indentRange = Range(match.range(at: 1), in: line),
              let roleRange   = Range(match.range(at: 2), in: line),
              let titleRange  = Range(match.range(at: 3), in: line) else { return nil }
        let indent = line.distance(from: line.startIndex, to: indentRange.upperBound)
                   - line.distance(from: line.startIndex, to: indentRange.lowerBound)
        let role = String(line[roleRange])
        let title = String(line[titleRange])
        let stem = stripTrailingTemplateTokens(title)
        guard !stem.isEmpty else { return nil }
        return PackKey(indent: indent, role: role, stem: stem)
    }

    /// Strip trailing date/time discriminators from a title to obtain its
    /// stem. Conservative by design: only strips when a YYYY-MM-DD-shaped
    /// date appears after a whitespace boundary. Inline version numbers
    /// like "Release 1.0" / "Release 2.0" are NOT stripped — version
    /// numbers are content-bearing, not template noise.
    ///
    /// Examples (verified by `AXNoiseFilterTests`):
    /// - `"Screenshot 2026-05-16 at 17.50.07"` → `"Screenshot"`
    /// - `"Снимок экрана 2026-01-26 в 19.40.53"` → `"Снимок экрана"`
    /// - `"Untitled Document"` → `"Untitled Document"`
    /// - `"Release 1.0"` → `"Release 1.0"`
    static func stripTrailingTemplateTokens(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let dateMatch = trailingDateRegex.firstMatch(in: trimmed, range: range),
           let cutRange = Range(dateMatch.range, in: trimmed) {
            let head = trimmed[trimmed.startIndex..<cutRange.lowerBound]
            return head.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// Matches a trailing date pattern of the form `YYYY[-./]MM[-./]DD`
    /// preceded by whitespace, optionally followed by a short
    /// timestamp/locale suffix of up to 32 chars (digits, dots, colons,
    /// spaces, and a single locale word — e.g., ` at 17.50.07`, ` в
    /// 19.40.53`, ` 18:30`). Tied to a whitespace boundary on both ends:
    ///
    /// - **Left:** date must follow whitespace so inline version numbers
    ///   (e.g., "Release 1.0", which has no `YYYY` immediately after a
    ///   space) don't match.
    /// - **Right (new):** the optional suffix is bounded to 32 chars of
    ///   timestamp-shaped content. This protects against the
    ///   "Meeting YYYY-MM-DD - Alice" / "Project YYYY-MM-DD review"
    ///   class — titles where a date appears mid-string but the
    ///   participant / topic name *after* the date is real signal that
    ///   should survive in the stem.
    ///
    /// Two earlier failure modes informed the current shape:
    /// - **`\S*\s*` between whitespace and date** turned out greedy on
    ///   Russian "Снимок экрана 2026-..." (`\S*` matched "экрана",
    ///   stripping the locale word). Tightened to require the date
    ///   immediately after whitespace.
    /// - **`.*$` after the date** (its first tightening) was too
    ///   permissive and would strip arbitrary trailing content like
    ///   " - Alice" / " - Bob", collapsing meeting/note titles that
    ///   shouldn't pack. The 32-char suffix window is tight enough to
    ///   cover real timestamps + locale words without absorbing
    ///   participant names or topic suffixes.
    private static let trailingDateRegex = try! NSRegularExpression(
        pattern: #"\s+\d{4}[-./]\d{1,2}[-./]\d{1,2}([\s.][\d:.\s\w]{0,32})?$"#
    )

    private static func makeSummaryLine(for run: ArraySlice<String>) -> String? {
        guard let first = run.first, let key = packKey(for: first) else { return nil }
        let indent = String(repeating: " ", count: key.indent)
        return "\(indent)- \(key.role) (× \(run.count) items, stem \"\(key.stem)\")"
    }
}
