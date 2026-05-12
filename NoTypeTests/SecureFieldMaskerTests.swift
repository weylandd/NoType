import XCTest
@testable import NoType

/// **Security boundary.** Per `NoType/Context/CLAUDE.md`: any change to
/// `SecureFieldMasker.swift` must add at least one new test case here.
/// No exceptions.
///
/// Two layers are tested:
/// - **Skip rules** (`mask(value:metadata:)` → `.skip(...)`) — node-level
///   metadata that makes us drop the value entirely.
/// - **Content patterns** (`scrubContent(_:)` and `.replace(...)`) — value
///   text that looks like a secret regardless of the surrounding metadata.
final class SecureFieldMaskerTests: XCTestCase {

    // MARK: - Skip rules

    func test_skip_secureRole() {
        let result = SecureFieldMasker.mask(
            value: "hunter2",
            metadata: .init(role: "AXSecureTextField")
        )
        XCTAssertEqual(result, .skip(reason: "secure role"))
    }

    func test_skip_secureSubrole() {
        let result = SecureFieldMasker.mask(
            value: "hunter2",
            metadata: .init(role: "AXTextField", subrole: "AXSecureTextField")
        )
        XCTAssertEqual(result, .skip(reason: "secure subrole"))
    }

    func test_skip_secureRoleDescription_caseInsensitive() {
        let result = SecureFieldMasker.mask(
            value: "hunter2",
            metadata: .init(role: "AXTextField", roleDescription: "Secure entry field")
        )
        XCTAssertEqual(result, .skip(reason: "secure role description"))
    }

    func test_skip_identifierContainsPassword() {
        let result = SecureFieldMasker.mask(
            value: "hunter2",
            metadata: .init(role: "AXTextField", identifier: "loginPasswordField")
        )
        XCTAssertEqual(result, .skip(reason: "identifier=password"))
    }

    func test_skip_identifierContainsToken_caseInsensitive() {
        let result = SecureFieldMasker.mask(
            value: "anything",
            metadata: .init(role: "AXTextField", identifier: "API_TOKEN_input")
        )
        XCTAssertEqual(result, .skip(reason: "identifier=token"))
    }

    func test_skip_identifierAllSecretTokens() {
        // Each token must trigger a skip independently. Locks the inventory
        // — adding/removing a token requires updating the test.
        let tokens = ["password", "passcode", "pin", "secret", "token", "apikey", "credential"]
        for token in tokens {
            let result = SecureFieldMasker.mask(
                value: "x",
                metadata: .init(role: "AXTextField", identifier: "field_\(token)_id")
            )
            switch result {
            case .skip: break
            default: XCTFail("identifier substring '\(token)' should trigger skip; got \(result)")
            }
        }
    }

    func test_skip_passwordSheetByTitle() {
        // Heuristic: parent sheet's title implies the children carry secrets.
        let result = SecureFieldMasker.mask(
            value: "hunter2",
            metadata: .init(
                role: "AXTextField",
                parentRole: "AXSheet",
                parentTitle: "Sign in to Acme"
            )
        )
        XCTAssertEqual(result, .skip(reason: "sensitive sheet"))
    }

    func test_skip_twoFactorSheetByTitle() {
        let result = SecureFieldMasker.mask(
            value: "123456",
            metadata: .init(
                role: "AXTextField",
                parentRole: "AXSheet",
                parentTitle: "Two-Factor Authentication"
            )
        )
        XCTAssertEqual(result, .skip(reason: "sensitive sheet"))
    }

    func test_noSkip_innocuousSheetTitle() {
        let result = SecureFieldMasker.mask(
            value: "search for cats",
            metadata: .init(
                role: "AXTextField",
                parentRole: "AXSheet",
                parentTitle: "Find in Page"
            )
        )
        XCTAssertEqual(result, .keep("search for cats"))
    }

    func test_noSkip_passwordSubstringInUnrelatedIdentifier() {
        // "credentialsList" contains "credential" — current heuristic accepts
        // this and skips it. Pinning the behaviour: if we ever tighten the
        // matcher to whole-word only, this test should be updated together.
        let result = SecureFieldMasker.mask(
            value: "items",
            metadata: .init(role: "AXList", identifier: "credentialsList")
        )
        XCTAssertEqual(result, .skip(reason: "identifier=credential"))
    }

    // MARK: - Value-content patterns

    func test_mask_creditCard_validLuhn() {
        // 4111 1111 1111 1111 is the canonical Visa test number — Luhn-valid.
        let result = SecureFieldMasker.mask(
            value: "4111 1111 1111 1111",
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .replace("[REDACTED — likely card number]", reason: "content"))
    }

    func test_mask_creditCard_dashSeparated() {
        let result = SecureFieldMasker.mask(
            value: "4111-1111-1111-1111",
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .replace("[REDACTED — likely card number]", reason: "content"))
    }

    func test_mask_creditCard_skipsLuhnInvalid() {
        // 13–19 digits that look card-shaped but don't pass Luhn shouldn't
        // be masked — prevents over-eager redaction of e.g. order numbers.
        let result = SecureFieldMasker.mask(
            value: "1234567890123456",
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .keep("1234567890123456"))
    }

    func test_mask_bearerHeader() {
        let result = SecureFieldMasker.mask(
            value: "Authorization: Bearer abcdef0123456789ABCDEF0123",
            metadata: .init(role: "AXTextField")
        )
        guard case let .replace(scrubbed, _) = result else {
            XCTFail("expected replace, got \(result)"); return
        }
        XCTAssertTrue(scrubbed.contains("[REDACTED — likely auth header]"), scrubbed)
        XCTAssertFalse(scrubbed.contains("abcdef0123456789ABCDEF0123"))
    }

    func test_mask_basicAuthHeader_caseInsensitive() {
        let result = SecureFieldMasker.mask(
            value: "BASIC dXNlcjpwYXNzd29yZHN0cmluZw==",
            metadata: .init(role: "AXTextField")
        )
        guard case let .replace(scrubbed, _) = result else {
            XCTFail("expected replace, got \(result)"); return
        }
        XCTAssertTrue(scrubbed.contains("[REDACTED — likely auth header]"), scrubbed)
    }

    func test_mask_stripeKey_test() {
        // Prefix split to avoid GitHub Push Protection's static pattern match
        // on the test fixture; runtime value is unchanged.
        let result = SecureFieldMasker.mask(
            value: "sk" + "_test_aBcDeFgHiJkLmNoPqRsTuVwX",
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .replace("[REDACTED — likely API key]", reason: "content"))
    }

    func test_mask_stripeKey_live_publishable() {
        let result = SecureFieldMasker.mask(
            value: "pk_live_aBcDeFgHiJkLmNoPqRsTuVwX",
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .replace("[REDACTED — likely API key]", reason: "content"))
    }

    func test_mask_awsAccessKey() {
        let result = SecureFieldMasker.mask(
            value: "AKIAIOSFODNN7EXAMPLE",
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .replace("[REDACTED — AWS key]", reason: "content"))
    }

    func test_mask_longOpaqueToken_lettersAndDigits() {
        let token = "abcdef0123456789ABCDEF0123456789abcdef0123"  // 42 chars, mixed
        let result = SecureFieldMasker.mask(
            value: token,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .replace("[REDACTED — likely token]", reason: "content"))
    }

    func test_mask_longOpaqueToken_skipsPureLetters() {
        // 40+ letters with no digits are usually prose (long compound word,
        // hashed transcript chunk, etc.) — the letter+digit gate keeps us
        // from over-redacting natural text.
        let s = String(repeating: "a", count: 50)
        let result = SecureFieldMasker.mask(
            value: s,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .keep(s))
    }

    func test_mask_longOpaqueToken_skipsPureDigits() {
        let s = String(repeating: "9", count: 50)
        // Pure-digit run >= 50 won't match the credit-card regex bound
        // (max 19) nor the AWS / Stripe / Bearer rules, and won't pass
        // the letter+digit gate on the opaque-token rule either.
        let result = SecureFieldMasker.mask(
            value: s,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .keep(s))
    }

    func test_mask_keepsSurroundingProse() {
        let result = SecureFieldMasker.mask(
            value: "key is AKIAIOSFODNN7EXAMPLE for the staging account",
            metadata: .init(role: "AXTextField")
        )
        guard case let .replace(scrubbed, _) = result else {
            XCTFail("expected replace, got \(result)"); return
        }
        XCTAssertTrue(scrubbed.contains("key is "), scrubbed)
        XCTAssertTrue(scrubbed.contains(" for the staging account"), scrubbed)
        XCTAssertTrue(scrubbed.contains("[REDACTED — AWS key]"), scrubbed)
        XCTAssertFalse(scrubbed.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    // MARK: - Targeted secret families

    func test_mask_jwt() {
        // Canonical 3-part JWT with the `eyJ` base64-of-`{"` header prefix.
        let value = "session=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXStaticText")
        )
        guard case let .replace(scrubbed, _) = result else {
            XCTFail("expected replace, got \(result)"); return
        }
        XCTAssertTrue(scrubbed.contains("[REDACTED — likely JWT]"), scrubbed)
        XCTAssertFalse(scrubbed.contains("eyJhbGc"))
        XCTAssertFalse(scrubbed.contains("eyJzdWIi"))
    }

    func test_mask_githubClassicPersonalAccessToken() {
        // `ghp_` + 36 chars is the GitHub classic PAT shape.
        let value = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(
            result,
            .replace("[REDACTED — likely GitHub token]", reason: "content")
        )
    }

    func test_mask_githubFineGrainedToken() {
        let value = "github_pat_11AAAAAA0AbcDefGhiJkl0_MnoPqrStuVwxYz0123456789AbcDefGhiJkl"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(
            result,
            .replace("[REDACTED — likely GitHub token]", reason: "content")
        )
    }

    func test_mask_googleAPIKey() {
        // 39 chars total (`AIza` + 35) — deliberately one short of the
        // generic 40-char opaque-token threshold. The dedicated rule is
        // load-bearing for our own Gemini-key class of secret.
        let value = "AIzaSyA1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(
            result,
            .replace("[REDACTED — likely Google API key]", reason: "content")
        )
    }

    func test_mask_openAIKey() {
        let value = "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(
            result,
            .replace("[REDACTED — likely API key]", reason: "content")
        )
    }

    func test_mask_anthropicKey() {
        let value = "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(
            result,
            .replace("[REDACTED — likely API key]", reason: "content")
        )
    }

    func test_openAIPattern_doesNotCollideWithStripe() {
        // Stripe uses `_test_` / `_live_` with underscores. The OpenAI rule
        // requires a hyphen after `sk`, so the two regexes never overlap.
        // Both must still redact; we just want to confirm Stripe wins the
        // labelling for its own shape.
        // Prefix split to avoid GitHub Push Protection's static pattern match.
        let value = "sk" + "_test_aBcDeFgHiJkLmNoPqRsTuVwX"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(
            result,
            .replace("[REDACTED — likely API key]", reason: "content")
        )
    }

    func test_mask_slackBotToken() {
        // Prefix split to avoid GitHub Push Protection's static pattern match.
        let value = "xo" + "xb-12345678901-1234567890123-aBcDeFgHiJkLmNoPqRsTuVwX"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(
            result,
            .replace("[REDACTED — likely Slack token]", reason: "content")
        )
    }

    func test_mask_pemPrivateKeyBlock() {
        let value = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAxxxAbCdEfGhIjKlMnOpQrStUvWxYz0123456789
        AbCdEfGhIjKlMnOpQrStUvWxYz0123456789==
        -----END RSA PRIVATE KEY-----
        """
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXStaticText")
        )
        guard case let .replace(scrubbed, _) = result else {
            XCTFail("expected replace, got \(result)"); return
        }
        XCTAssertTrue(scrubbed.contains("[REDACTED — private key]"), scrubbed)
        XCTAssertFalse(scrubbed.contains("MIIEow"))
        XCTAssertFalse(scrubbed.contains("BEGIN RSA"))
    }

    func test_mask_pemPrivateKey_truncatedAtBeginMarker() {
        // AX value capture is truncated at 2000 chars per node — the END
        // marker can disappear mid-stream. Even the BEGIN line alone is
        // enough signal to redact what we still hold.
        let value = "Here's my key:\n-----BEGIN OPENSSH PRIVATE KEY-----\nMIIEowIBAAKCAQEAxxx"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXStaticText")
        )
        guard case let .replace(scrubbed, _) = result else {
            XCTFail("expected replace, got \(result)"); return
        }
        XCTAssertTrue(scrubbed.contains("[REDACTED — private key]"), scrubbed)
        XCTAssertFalse(scrubbed.contains("BEGIN OPENSSH"))
        XCTAssertTrue(scrubbed.contains("Here's my key:"), scrubbed)
    }

    func test_mask_urlWithEmbeddedCredentials() {
        let value = "Clone: https://alice:p4ssw0rd@github.com/acme/repo.git"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXStaticText")
        )
        guard case let .replace(scrubbed, _) = result else {
            XCTFail("expected replace, got \(result)"); return
        }
        XCTAssertTrue(scrubbed.contains("https://[REDACTED — url creds]@github.com/acme/repo.git"), scrubbed)
        XCTAssertFalse(scrubbed.contains("alice"))
        XCTAssertFalse(scrubbed.contains("p4ssw0rd"))
    }

    func test_keep_sshStyleGitRemote() {
        // `git@github.com:user/repo.git` has no `://` — SSH-style, no
        // embedded creds. Must not match `urlCredsRegex`.
        let value = "Remote: git@github.com:acme/repo.git"
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXStaticText")
        )
        XCTAssertEqual(result, .keep(value))
    }

    // MARK: - Negative cases — policy lock for false-positive ceiling

    func test_keep_shortAlphanumericProductTokens() {
        // Locks the deliberate policy choice (NoType/Context/CLAUDE.md):
        // short mixed-case alphanumeric strings — version numbers, model
        // names, artefact tags — must NOT trigger redaction. Lowering the
        // generic-token threshold below ~40 chars would zap these and ruin
        // the AX context Gemini relies on for proper-noun transcription.
        let values = ["iPhone15", "macOS26", "Swift6", "v0.1.0", "Xcode26", "MacBook4", "issue1234"]
        for v in values {
            let result = SecureFieldMasker.mask(
                value: v,
                metadata: .init(role: "AXStaticText")
            )
            XCTAssertEqual(result, .keep(v), "expected \(v) to pass through unchanged")
        }
    }

    // MARK: - Empty / no-op paths

    func test_keep_nilValueReturnsEmptyKeep() {
        let result = SecureFieldMasker.mask(
            value: nil,
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .keep(""))
    }

    func test_keep_emptyValueReturnsEmptyKeep() {
        let result = SecureFieldMasker.mask(
            value: "",
            metadata: .init(role: "AXTextField")
        )
        XCTAssertEqual(result, .keep(""))
    }

    func test_keep_plainProse() {
        let value = "Hey team, the Q3 plan looks good — let's review on Tuesday."
        let result = SecureFieldMasker.mask(
            value: value,
            metadata: .init(role: "AXStaticText")
        )
        XCTAssertEqual(result, .keep(value))
    }

    // MARK: - scrubContent direct path

    func test_scrubContent_idempotent_onScrubbedOutput() {
        // Running scrubContent on already-scrubbed text must not corrupt the
        // markers. Important for `InsertionTarget.slice`, which scrubs the
        // value-content layer on text already filtered upstream.
        let once = SecureFieldMasker.scrubContent("AKIAIOSFODNN7EXAMPLE was rotated.")
        let twice = SecureFieldMasker.scrubContent(once)
        XCTAssertEqual(once, twice)
    }

    // MARK: - OCR fallback consumer
    //
    // The screenshot+OCR fallback feeds recognised lines through
    // `scrubContent` before they enter `RedactedScreenText`. These cases
    // pin the OCR-shaped inputs we expect Vision to surface — they're
    // shapes the AX walker historically never produced (AX skip-rules
    // already drop password fields), so the content-pattern layer is the
    // sole defence on this path.

    func test_ocr_scrubs_creditCard_visibleOnScreen() {
        // Form-preview / payment-step screen.
        let line = "Card: 4111 1111 1111 1111  Exp 04/29"
        let scrubbed = SecureFieldMasker.scrubContent(line)
        XCTAssertTrue(scrubbed.contains("[REDACTED — likely card number]"))
        XCTAssertFalse(scrubbed.contains("4111 1111 1111 1111"))
    }

    func test_ocr_scrubs_bearerToken_visibleInRequestPanel() {
        // Browser devtools / Insomnia / Paw — auth headers shown raw.
        let line = "Authorization: Bearer abcdef1234567890ABCDEF1234567890XYZ"
        let scrubbed = SecureFieldMasker.scrubContent(line)
        XCTAssertTrue(scrubbed.contains("[REDACTED — likely auth header]"))
    }

    func test_ocr_scrubs_awsAccessKey_visibleInTerminal() {
        let line = "export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"
        let scrubbed = SecureFieldMasker.scrubContent(line)
        XCTAssertTrue(scrubbed.contains("[REDACTED — AWS key]"))
    }

    func test_ocr_scrubs_googleAPIKey_visibleInSettingsPanel() {
        // 39 chars total = `AIza` (4) + 35-char body — Google API keys
        // have a fixed length and the regex matches exactly that.
        let line = "GEMINI_KEY=AIzaSyA1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q"
        let scrubbed = SecureFieldMasker.scrubContent(line)
        XCTAssertTrue(scrubbed.contains("[REDACTED — likely Google API key]"))
    }

    func test_ocr_scrubs_jwt_visibleInInspector() {
        let line = "id_token: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let scrubbed = SecureFieldMasker.scrubContent(line)
        XCTAssertTrue(scrubbed.contains("[REDACTED — likely JWT]"))
    }

    func test_ocr_preserves_proseAndProperNouns() {
        // Critical: don't over-redact. OCR routinely captures channel
        // names, contact names, file names — these must survive so the
        // model can disambiguate jargon.
        let line = "#engineering Acme Corp — John Doe yesterday at 10:24am"
        let scrubbed = SecureFieldMasker.scrubContent(line)
        XCTAssertEqual(scrubbed, line, "innocuous OCR text must pass through unchanged")
    }

    func test_ocr_idempotent_underRepeatedScrubbing() {
        // Defence in depth — if the OCR pipeline ever runs scrubContent
        // twice for any reason, the second pass must be a no-op (no
        // double-replacement, no marker corruption).
        let line = "User pasted sk-proj-aaaaaaaaaaaaaaaaaaaa next to AKIAABCDEFGHIJKLMNOP"
        let once  = SecureFieldMasker.scrubContent(line)
        let twice = SecureFieldMasker.scrubContent(once)
        XCTAssertEqual(once, twice)
    }
}
