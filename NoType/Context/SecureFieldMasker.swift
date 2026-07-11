import Foundation

/// Pure, deterministic redaction of accessibility-tree node values before
/// they ever leave the device. This is the security boundary for the Context
/// module — nothing else may decide whether a value is safe to ship.
///
/// Two layers run in order:
///
/// 1. **Skip rules** check the node's metadata. If any rule matches the node
///    is dropped entirely — the value never enters the snapshot. (Cheap: most
///    sensitive fields are tagged at the AX role/identifier level by the
///    hosting app.)
///
/// 2. **Value-content patterns** scan the raw value text for shapes that
///    look like secrets even when the surrounding metadata didn't flag them
///    (think: card number pasted into a regular AXTextField). Matches are
///    replaced with a `[REDACTED — <reason>]` marker.
///
/// Hard rule, repeated from `NoType/Context/CLAUDE.md`: any change here adds at
/// least one new test case. No exceptions.
enum SecureFieldMasker {
    /// Result of redacting a single node.
    enum MaskAction: Equatable, Sendable {
        /// Drop the node entirely — its value never reaches the snapshot.
        case skip(reason: String)
        /// Keep the node, replace the value with the supplied scrubbed text.
        case replace(String, reason: String)
        /// Keep the node and the value as-is.
        case keep(String)
    }

    /// Just the metadata fields the masker needs. Decoupled from
    /// `MockAXNode` / live AX walker so unit tests can synthesize cases by
    /// hand.
    struct NodeMetadata: Equatable, Sendable {
        var role: String?
        var subrole: String?
        var roleDescription: String?
        var identifier: String?
        /// Role of the closest ancestor AX element, if known.
        var parentRole: String?
        /// Title of the closest ancestor AX element, if known. Useful for the
        /// "password manager sheet" heuristic.
        var parentTitle: String?

        init(
            role: String? = nil,
            subrole: String? = nil,
            roleDescription: String? = nil,
            identifier: String? = nil,
            parentRole: String? = nil,
            parentTitle: String? = nil
        ) {
            self.role = role
            self.subrole = subrole
            self.roleDescription = roleDescription
            self.identifier = identifier
            self.parentRole = parentRole
            self.parentTitle = parentTitle
        }
    }

    /// Top-level entry point. Run *before* the value joins the snapshot.
    static func mask(value: String?, metadata: NodeMetadata) -> MaskAction {
        if let reason = skipReason(for: metadata) {
            return .skip(reason: reason)
        }
        guard let raw = value, !raw.isEmpty else {
            return .keep("")
        }

        let scrubbed = scrubContent(raw)
        if scrubbed != raw {
            return .replace(scrubbed, reason: "content")
        }
        return .keep(raw)
    }

    // MARK: - Skip rules

    private static let secureRoleSet: Set<String> = [
        "AXSecureTextField"
    ]

    /// Identifier substrings that strongly suggest the node holds a secret
    /// even when the role doesn't say so.
    private static let secretIdentifierTokens: [String] = [
        "password", "passcode", "pin", "secret", "token", "apikey", "credential"
    ]

    /// Title patterns for sheets/dialogs whose children are typically
    /// secret-bearing inputs (password manager prompts, sign-in dialogs).
    private static let sensitiveSheetTitleRegex = try! NSRegularExpression(
        pattern: #"password|secret|sign\s*in|sign\s*on|two[-\s]?factor|authentication"#,
        options: .caseInsensitive
    )

    /// The shared secure-field skip decision. `internal` (not `private`) so
    /// `InsertionTarget.captureSync` can apply the SAME rule set the AX walker
    /// uses instead of its own narrower role-only check — keeping the two
    /// paths from drifting (R9). Returns a non-nil reason string when the node
    /// must be dropped entirely.
    static func skipReason(for m: NodeMetadata) -> String? {
        if let role = m.role, secureRoleSet.contains(role) {
            return "secure role"
        }
        if let subrole = m.subrole, secureRoleSet.contains(subrole) {
            return "secure subrole"
        }
        if let desc = m.roleDescription,
           desc.range(of: "secure", options: .caseInsensitive) != nil {
            return "secure role description"
        }
        if let id = m.identifier?.lowercased() {
            for token in secretIdentifierTokens where id.contains(token) {
                return "identifier=\(token)"
            }
        }
        if m.parentRole == "AXSheet", let title = m.parentTitle {
            let range = NSRange(title.startIndex..., in: title)
            if sensitiveSheetTitleRegex.firstMatch(in: title, range: range) != nil {
                return "sensitive sheet"
            }
        }
        return nil
    }

    // MARK: - Value-content patterns

    /// Run every regex-style scrubber over the raw text and return the
    /// (possibly transformed) result. Order matters: the more specific
    /// patterns run first so generic catch-alls don't swallow them and so
    /// each replacement carries the most informative `[REDACTED — …]` label.
    static func scrubContent(_ raw: String) -> String {
        var s = raw
        s = replaceCreditCards(s)
        s = replaceBearerHeaders(s)
        s = replacePEMPrivateKeys(s)
        s = replaceJWTs(s)
        s = replaceGitHubTokens(s)
        s = replaceGoogleAPIKeys(s)
        s = replaceOpenAIStyleKeys(s)
        s = replaceSlackTokens(s)
        s = replaceStripeKeys(s)
        s = replaceAWSKeys(s)
        s = replaceURLCreds(s)
        s = replaceBase64Blobs(s)
        s = replaceLongOpaqueTokens(s)
        return s
    }

    private static let cardCandidateRegex = try! NSRegularExpression(
        pattern: #"\b(?:\d[ -]*?){13,19}\b"#
    )

    private static func replaceCreditCards(_ s: String) -> String {
        replaceMatches(in: s, regex: cardCandidateRegex) { match, full in
            let digits = match.filter(\.isNumber)
            guard digits.count >= 13, digits.count <= 19, luhnValid(digits) else {
                return nil
            }
            _ = full
            return "[REDACTED — likely card number]"
        }
    }

    /// Standard Luhn (mod-10) checksum.
    private static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var alt = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            if alt {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
            alt.toggle()
        }
        return sum % 10 == 0
    }

    private static let bearerHeaderRegex = try! NSRegularExpression(
        pattern: #"(?i)(bearer|basic)\s+[A-Za-z0-9._\-+/=]{20,}"#
    )

    private static func replaceBearerHeaders(_ s: String) -> String {
        replaceMatches(in: s, regex: bearerHeaderRegex) { _, _ in
            "[REDACTED — likely auth header]"
        }
    }

    /// PEM-armored private key (RSA, EC, OpenSSH, etc.). Multi-line. The END
    /// marker is optional so we also catch the case where AX value capture
    /// truncates partway through the body — even a stranded BEGIN line is
    /// enough signal that a private key is on screen.
    private static let pemPrivateKeyRegex = try! NSRegularExpression(
        pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?:[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----)?"#
    )

    private static func replacePEMPrivateKeys(_ s: String) -> String {
        replaceMatches(in: s, regex: pemPrivateKeyRegex) { _, _ in
            "[REDACTED — private key]"
        }
    }

    /// JSON Web Token: three base64url-encoded segments separated by dots.
    /// Anchored on the literal `eyJ` prefix (base64 of `{"`) for both header
    /// and payload — avoids matching arbitrary `base64.base64.base64`
    /// triplets that appear in unrelated text.
    private static let jwtRegex = try! NSRegularExpression(
        pattern: #"\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#
    )

    private static func replaceJWTs(_ s: String) -> String {
        replaceMatches(in: s, regex: jwtRegex) { _, _ in
            "[REDACTED — likely JWT]"
        }
    }

    /// GitHub tokens: classic PAT (`ghp_`), OAuth (`gho_`), user-to-server
    /// (`ghu_`), server-to-server (`ghs_`), refresh (`ghr_`), and the
    /// fine-grained PAT prefix (`github_pat_`).
    private static let githubTokenRegex = try! NSRegularExpression(
        pattern: #"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"#
    )

    private static func replaceGitHubTokens(_ s: String) -> String {
        replaceMatches(in: s, regex: githubTokenRegex) { _, _ in
            "[REDACTED — likely GitHub token]"
        }
    }

    /// Google API keys (incl. the user's own Gemini key). 39 chars total —
    /// sits one character under the generic opaque-token threshold, so the
    /// dedicated rule is required. Important for NoType specifically: a
    /// user who pastes their key into chat or docs must not have it shipped
    /// right back to Gemini in the AX context.
    private static let googleAPIKeyRegex = try! NSRegularExpression(
        pattern: #"\bAIza[0-9A-Za-z_\-]{35}\b"#
    )

    private static func replaceGoogleAPIKeys(_ s: String) -> String {
        replaceMatches(in: s, regex: googleAPIKeyRegex) { _, _ in
            "[REDACTED — likely Google API key]"
        }
    }

    /// OpenAI / Anthropic style keys: `sk-...` (with optional `ant-`
    /// vendor segment). The hyphen-separator differentiates them from
    /// Stripe's `sk_test_…` / `sk_live_…` (handled by `stripeKeyRegex`).
    private static let openAIStyleKeyRegex = try! NSRegularExpression(
        pattern: #"(?i)\bsk-(?:ant-)?[A-Za-z0-9_\-]{20,}\b"#
    )

    private static func replaceOpenAIStyleKeys(_ s: String) -> String {
        replaceMatches(in: s, regex: openAIStyleKeyRegex) { _, _ in
            "[REDACTED — likely API key]"
        }
    }

    /// Slack tokens: bot (`xoxb-`), app (`xoxa-`), personal (`xoxp-`),
    /// refresh (`xoxe-`), and others. Letter set kept permissive
    /// (`[a-z]`) so future Slack variants don't slip through.
    private static let slackTokenRegex = try! NSRegularExpression(
        pattern: #"\bxox[a-z]-[A-Za-z0-9-]{10,}\b"#
    )

    private static func replaceSlackTokens(_ s: String) -> String {
        replaceMatches(in: s, regex: slackTokenRegex) { _, _ in
            "[REDACTED — likely Slack token]"
        }
    }

    /// Basic-auth credentials embedded in a URL:
    /// `scheme://user:pass@host/...`. We keep the `scheme://…@host/…` shape
    /// so the AX context still reads as "this is a URL" — only the
    /// `user:pass@` segment is redacted.
    private static let urlCredsRegex = try! NSRegularExpression(
        pattern: #"://[^/\s:@]+:[^/\s@]+@"#
    )

    private static func replaceURLCreds(_ s: String) -> String {
        replaceMatches(in: s, regex: urlCredsRegex) { _, _ in
            "://[REDACTED — url creds]@"
        }
    }

    private static let stripeKeyRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(sk|pk|rk)_(test|live)_[A-Za-z0-9]{16,}\b"#
    )

    private static func replaceStripeKeys(_ s: String) -> String {
        replaceMatches(in: s, regex: stripeKeyRegex) { _, _ in
            "[REDACTED — likely API key]"
        }
    }

    private static let awsKeyRegex = try! NSRegularExpression(
        pattern: #"\bAKIA[0-9A-Z]{16}\b"#
    )

    private static func replaceAWSKeys(_ s: String) -> String {
        replaceMatches(in: s, regex: awsKeyRegex) { _, _ in
            "[REDACTED — AWS key]"
        }
    }

    /// Standard-base64 blob (charset `A-Za-z0-9+/=`, length ≥ 40). Complements
    /// `opaqueTokenRegex`, whose `[A-Za-z0-9_\-]` charset structurally CANNOT
    /// match a run containing `+`, `/`, or `=` — the exact shape of AWS secret
    /// access keys and raw base64-encoded key material (`wJalr…FEMI/K7…`,
    /// GCP service-account blobs). Sits directly ABOVE the generic catch-all
    /// so the specific provider rules above still win (they run first and
    /// their patterns — `_`/`-`/`.`/prefix-anchored — are never pure base64
    /// runs ≥ 40), but nothing more generic can shadow it.
    ///
    /// Uses a maximal-run look-around (not `\b`) because `+`/`/`/`=` are
    /// non-word chars that `\b` would split on.
    private static let base64BlobRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9+/=])[A-Za-z0-9+/=]{40,}(?![A-Za-z0-9+/=])"#
    )

    private static func replaceBase64Blobs(_ s: String) -> String {
        replaceMatches(in: s, regex: base64BlobRegex) { match, _ in
            // Same letter-AND-digit gate as the opaque catch-all (avoids
            // redacting prose and digit-less file paths), PLUS a required
            // base64-special char (`+`/`/`/`=`). The special-char gate means
            // this rule fires ONLY on the shape the opaque rule can't reach —
            // a pure `[A-Za-z0-9]` run stays the opaque rule's job below, and
            // hyphen/underscore tokens are never touched here.
            let hasLetter  = match.contains(where: { $0.isLetter })
            let hasDigit   = match.contains(where: { $0.isNumber })
            let hasSpecial = match.contains(where: { $0 == "+" || $0 == "/" || $0 == "=" })
            guard hasLetter && hasDigit && hasSpecial else { return nil }
            return "[REDACTED — likely secret]"
        }
    }

    private static let opaqueTokenRegex = try! NSRegularExpression(
        pattern: #"\b[A-Za-z0-9_\-]{40,}\b"#
    )

    private static func replaceLongOpaqueTokens(_ s: String) -> String {
        replaceMatches(in: s, regex: opaqueTokenRegex) { match, _ in
            // Filter out matches that are pure base-N noise the user typed in
            // a normal text box. Heuristic: require both letters and digits.
            // Pure prose words (incl. long compounds) and pure number runs are
            // skipped. URLs / sentences are tokenised by `\b` so they don't
            // trip this.
            let hasLetter = match.contains(where: { $0.isLetter })
            let hasDigit  = match.contains(where: { $0.isNumber })
            guard hasLetter && hasDigit else { return nil }
            return "[REDACTED — likely token]"
        }
    }

    /// Apply `transform` to every regex match. Returning `nil` from
    /// `transform` keeps the original substring intact.
    private static func replaceMatches(
        in input: String,
        regex: NSRegularExpression,
        transform: (_ match: String, _ full: String) -> String?
    ) -> String {
        let ns = input as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: input, range: range)
        guard !matches.isEmpty else { return input }

        var result = ""
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            let matchText = ns.substring(with: m.range)
            if let replacement = transform(matchText, input) {
                result += replacement
            } else {
                result += matchText
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }
}
