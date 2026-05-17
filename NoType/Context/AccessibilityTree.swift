import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Walks the on-screen accessibility tree of every visible app and produces
/// a `RedactedAXSnapshot` ready to be shipped to Gemini. Every value passes
/// through `SecureFieldMasker` before it reaches the snapshot — the
/// `RedactedAXSnapshot` initializer is module-internal so callers can't
/// bypass that.
///
/// Limits (mirrored from `NoType/Context/CLAUDE.md`):
///
/// - **Total node budget: 5000** across all apps. When we hit it we stop and
///   mark the snapshot `truncated`.
/// - **Per-window depth: 6.** AX trees can be very deep (especially
///   browsers); deeper nodes are rarely informative.
/// - **Per-app node budget: 800.** Prevents a single chatty app from eating
///   the whole budget.
/// - **Per-app wall clock: 100 ms.** A wedged app stalls when you ask for its
///   AX tree; we move on without it.
/// - **Max value length: 2000 chars per node.** Truncated with `…`.
enum AccessibilityTree {
    private static let log = Logger(subsystem: "app.notype", category: "context")

    /// Bundles we never walk: system UI and our own app. The system bits add
    /// noise (and lots of nodes); our own UI shouldn't appear in our prompt.
    private static let skippedBundleIDs: Set<String> = [
        "com.apple.systemuiserver",
        "com.apple.dock",
    ]

    private static let totalNodeBudget = 5_000
    private static let perAppNodeBudget = 800
    private static let perWindowDepth = 6
    private static let perAppTimeout: TimeInterval = 0.1
    private static let maxValueLength = 2_000

    /// Captures the on-screen tree. Safe to call from any actor — the work
    /// is done off the caller's isolation domain via a task group.
    static func snapshot() async -> RedactedAXSnapshot {
        guard AXIsProcessTrusted() else {
            // No Accessibility permission → no tree. Caller (RecordingSession)
            // still records audio; Gemini just gets the active-app hint.
            return RedactedAXSnapshot(apps: [])
        }

        let candidates = await candidateApps()
        if candidates.isEmpty {
            return RedactedAXSnapshot(apps: [])
        }

        let dumps = await withTaskGroup(of: RedactedAppDump?.self) { group in
            for c in candidates {
                group.addTask {
                    await dumpApp(pid: c.pid, name: c.name, bundleID: c.bundleID)
                }
            }
            var collected: [RedactedAppDump] = []
            for await maybe in group {
                if let dump = maybe { collected.append(dump) }
            }
            return collected
        }

        // Apply the global node budget. Counting uses lines as a proxy for
        // nodes (one node ~= one line); good enough for capping.
        var totalNodes = 0
        var truncated = false
        var capped: [RedactedAppDump] = []
        for app in dumps {
            let appNodes = app.windows.reduce(0) { $0 + $1.lines.count }
            if totalNodes + appNodes > totalNodeBudget {
                truncated = true
                break
            }
            totalNodes += appNodes
            capped.append(app)
        }

        let result = RedactedAXSnapshot(apps: capped, truncated: truncated)
        Self.log.info("ax snapshot: \(capped.count) apps, \(totalNodes) nodes, truncated=\(truncated)")
        return result
    }

    // MARK: - Candidate enumeration

    private struct Candidate: Sendable {
        let pid: pid_t
        let name: String
        let bundleID: String
    }

    @MainActor
    private static func candidateApps() -> [Candidate] {
        let selfBundleID = Bundle.main.bundleIdentifier
        let runningApps = NSWorkspace.shared.runningApplications
        var out: [Candidate] = []
        for app in runningApps where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier else { continue }
            if skippedBundleIDs.contains(bundleID) { continue }
            if bundleID == selfBundleID { continue }
            out.append(
                Candidate(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? bundleID,
                    bundleID: bundleID
                )
            )
        }
        return out
    }

    // MARK: - Per-app walk

    /// Wraps the per-app walk in a 100 ms timeout. AX queries can wedge if
    /// the target app's main thread is busy; we don't let one app stall the
    /// whole snapshot.
    ///
    /// Two enforcement layers cooperate so the timeout actually bounds CPU,
    /// not just caller latency:
    /// 1. `withTaskGroup` races `walkApp` against `Task.sleep` and returns
    ///    `nil` when the sleep wins. This bounds *latency*.
    /// 2. `cancelAll()` after the race flips `Task.isCancelled` on the
    ///    walker task. `walkApp` and `walk` check it at every recursion
    ///    step and at every window iteration, so the synchronous AX work
    ///    actually short-circuits instead of running to natural
    ///    completion in the background.
    private static func dumpApp(pid: pid_t, name: String, bundleID: String) async -> RedactedAppDump? {
        await withTaskGroup(of: RedactedAppDump?.self) { group in
            group.addTask {
                walkApp(pid: pid, name: name, bundleID: bundleID)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(Int(perAppTimeout * 1000)))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Per-node decision

    /// Outcome of `decideForNode` for a single AX node:
    /// - `.skipSubtree` — `SecureFieldMasker` flagged this node; drop it
    ///   AND its descendants (secure-field children would be just internal
    ///   text storage).
    /// - `.dropRender` — `AXNoiseFilter` classified this node's line as
    ///   noise (structural chrome, gibberish, terminal scrollback). Don't
    ///   append a line, don't charge against the budget, but **do** still
    ///   recurse into children — a noisy parent may wrap real content.
    /// - `.render(line)` — formatted prompt line; append and charge budget.
    enum NodeDecision: Equatable {
        case skipSubtree
        case dropRender
        case render(String)
    }

    /// Pure per-node pipeline. Pipeline order is load-bearing — pinned by
    /// `AccessibilityTreeTests`:
    ///
    /// 1. `SecureFieldMasker.mask` (security boundary, R8) — `.skip`
    ///    short-circuits to `.skipSubtree`.
    /// 2. `AXNoiseFilter.shouldDropNode` (R4 + R7) — structural chrome
    ///    and gibberish-only content drop to `.dropRender`.
    /// 3. `AXNoiseFilter.isViewportScrollback` (R5) — terminal-parent
    ///    gated scrollback drop.
    /// 4. `formatLine` — the existing nothing-to-render safety net
    ///    (empty-Group case) also falls through to `.dropRender`.
    static func decideForNode(
        role: String?,
        subrole: String?,
        title: String?,
        value: String?,
        metadata: SecureFieldMasker.NodeMetadata,
        parentBundleID: String?,
        depth: Int
    ) -> NodeDecision {
        let action = SecureFieldMasker.mask(value: value, metadata: metadata)
        switch action {
        case .skip:
            return .skipSubtree
        case .keep(let v), .replace(let v, _):
            if AXNoiseFilter.shouldDropNode(
                role: role, subrole: subrole, title: title, value: v
            ) {
                return .dropRender
            }
            if AXNoiseFilter.isViewportScrollback(
                role: role, value: v, parentBundleID: parentBundleID
            ) {
                return .dropRender
            }
            guard let line = formatLine(
                role: role, subrole: subrole, title: title,
                value: v, depth: depth
            ) else {
                return .dropRender
            }
            return .render(line)
        }
    }

    /// Synchronous tree walk for one app. Runs inside a task with the
    /// per-app timeout. Polls `Task.isCancelled` between windows so a
    /// fired timeout actually stops the walk, not just hides it.
    private static func walkApp(pid: pid_t, name: String, bundleID: String) -> RedactedAppDump? {
        let appElement = AXUIElementCreateApplication(pid)

        if Task.isCancelled { return nil }
        let rawWindows: [AXUIElement] = arrayAttribute(of: appElement, key: kAXWindowsAttribute as String)
        if rawWindows.isEmpty {
            return nil  // backgrounded app with no windows — skip
        }

        var nodesRemaining = perAppNodeBudget
        var windowDumps: [RedactedWindowDump] = []

        for window in rawWindows {
            if Task.isCancelled { break }
            if nodesRemaining <= 0 { break }
            if let minimized: Bool = boolAttribute(of: window, key: kAXMinimizedAttribute as String), minimized {
                continue
            }
            let title: String? = AXAttr.stringDescribing(window, kAXTitleAttribute as String)

            var lines: [String] = []
            walk(
                node: window,
                depth: 0,
                parentRole: AXAttr.stringDescribing(window, kAXRoleAttribute as String),
                parentTitle: title,
                parentBundleID: bundleID,
                lines: &lines,
                budget: &nodesRemaining
            )
            // R6: collapse repetitive packs once per window AFTER the walk.
            // Pure post-pass on rendered lines; no AX calls.
            AXNoiseFilter.collapseRepetitivePacks(&lines)
            windowDumps.append(RedactedWindowDump(title: title, lines: lines))
        }

        if windowDumps.isEmpty { return nil }

        return RedactedAppDump(appName: name, bundleID: bundleID, windows: windowDumps)
    }

    private static func walk(
        node: AXUIElement,
        depth: Int,
        parentRole: String?,
        parentTitle: String?,
        parentBundleID: String?,
        lines: inout [String],
        budget: inout Int
    ) {
        if budget <= 0 { return }
        // Honour the per-app timeout's `cancelAll` so a wedged target
        // app can't burn CPU in the background after we've already
        // moved on. Checked at every recursion step — cheap, and one AX
        // attribute fetch is the worst-case extra work we do after the
        // deadline fires.
        if Task.isCancelled { return }

        let role: String?            = AXAttr.stringDescribing(node, kAXRoleAttribute as String)
        let subrole: String?         = AXAttr.stringDescribing(node, kAXSubroleAttribute as String)
        let roleDescription: String? = AXAttr.stringDescribing(node, kAXRoleDescriptionAttribute as String)
        let title: String?           = AXAttr.stringDescribing(node, kAXTitleAttribute as String)
        let identifier: String?      = AXAttr.stringDescribing(node, kAXIdentifierAttribute as String)
        let rawValue: String?        = AXAttr.stringDescribing(node, kAXValueAttribute as String)

        // Skip the window root itself in the dump — its title is already on
        // the `Window:` header line.
        let isWindowRoot = depth == 0 && role == "AXWindow"

        if !isWindowRoot {
            let metadata = SecureFieldMasker.NodeMetadata(
                role: role,
                subrole: subrole,
                roleDescription: roleDescription,
                identifier: identifier,
                parentRole: parentRole,
                parentTitle: parentTitle
            )

            let decision = decideForNode(
                role: role,
                subrole: subrole,
                title: title,
                value: rawValue,
                metadata: metadata,
                parentBundleID: parentBundleID,
                depth: depth
            )

            switch decision {
            case .skipSubtree:
                // Drop this node and everything below it. AXSecureTextField
                // children would be just internal text storage — no reason
                // to descend. Charge budget so secure-rich subtrees can't
                // monopolise the per-app walk.
                budget -= 1
                return
            case .dropRender:
                // Noise — don't append a line, don't charge budget, but
                // DO recurse into children. Per R10: budget caps rendered
                // lines, not nodes visited. A noisy container (label-less
                // Toolbar) may wrap real content (labelled Search field).
                break
            case .render(let line):
                lines.append(line)
                budget -= 1
            }
        }

        if depth >= perWindowDepth { return }

        let children: [AXUIElement] = arrayAttribute(of: node, key: kAXChildrenAttribute as String)
        for child in children {
            if budget <= 0 { return }
            walk(
                node: child,
                depth: depth + 1,
                parentRole: role,
                parentTitle: title ?? parentTitle,
                parentBundleID: parentBundleID,
                lines: &lines,
                budget: &budget
            )
        }
    }

    // MARK: - Formatting

    /// Render a single AX node as one prompt line. Returns `nil` if the node
    /// would carry no signal (no role, no title, no value).
    private static func formatLine(
        role: String?,
        subrole: String?,
        title: String?,
        value: String,
        depth: Int
    ) -> String? {
        let shortRole = role.map { stripAXPrefix($0) }
        let shortSubrole = subrole.map { stripAXPrefix($0) }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = truncateValue(value)

        // Drop nodes that have nothing useful to say.
        if (shortRole == nil || shortRole == "Group" || shortRole == "Generic")
            && (trimmedTitle?.isEmpty ?? true)
            && trimmedValue.isEmpty {
            return nil
        }

        let indent = String(repeating: "  ", count: max(0, depth - 1))
        var out = indent + "- "
        if let r = shortRole {
            out += r
            if let sr = shortSubrole, sr != r { out += "/\(sr)" }
        }
        if let t = trimmedTitle, !t.isEmpty {
            out += " \"\(t.replacingOccurrences(of: "\"", with: "'"))\""
        }
        if !trimmedValue.isEmpty {
            let oneLine = trimmedValue
                .replacingOccurrences(of: "\n", with: " / ")
                .replacingOccurrences(of: "\"", with: "'")
            out += " = \(oneLine)"
        }
        return out
    }

    private static func stripAXPrefix(_ s: String) -> String {
        s.hasPrefix("AX") ? String(s.dropFirst(2)) : s
    }

    private static func truncateValue(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxValueLength { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: maxValueLength)
        return trimmed[..<idx] + "…"
    }

    // MARK: - AX attribute helpers
    //
    // String helpers (string / stringDescribing) live in
    // `NoType/Context/AXAttr.swift` — shared with `CategoryResolver`
    // and `ContextSnapshot`. The bool / array helpers below are
    // walker-specific and stay here.

    private static func boolAttribute(of element: AXUIElement, key: String) -> Bool? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard err == .success, let raw else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    private static func arrayAttribute(of element: AXUIElement, key: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard err == .success, let raw else { return [] }
        guard let cfArray = raw as? [AnyObject] else { return [] }
        return cfArray.compactMap { obj -> AXUIElement? in
            // AXUIElement bridges as CFType, and Swift treats it as AnyObject
            // when stored in a CFArray. The unsafeBitCast through the AXUIElement
            // type is the canonical way to cast an AnyObject element back when
            // we know the array's element type.
            guard CFGetTypeID(obj) == AXUIElementGetTypeID() else { return nil }
            return (obj as! AXUIElement)
        }
    }
}
