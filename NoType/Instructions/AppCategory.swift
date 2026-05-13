import Foundation

/// Per-app dictation category. Each session resolves exactly one of these
/// — either from a cached `AppCategoryAssignment` keyed on `bundleID`, or
/// (for `.search`) from a synchronous AX check on the focused element at
/// session start. The category controls the `Category instruction:` block
/// in the Gemini cache prefix, which in turn dictates per-channel
/// formatting (line breaks, greetings, hashtag handling, etc.).
///
/// `messaging`/`email`/`social`/`notes`/`docs`/`code` — what the
/// categorizer LLM may return (see `GeminiClient.classifyApp`).
/// `search` — never assigned by classifier; chosen at runtime by
/// `CategoryResolver` when the focused field looks like a search /
/// address bar (any bundle id can host one, e.g. Chrome's omnibox).
/// `uncategorized` — the default for unknown apps and the fallback when
/// the classifier returns low confidence. No `Category instruction:`
/// part is shipped for `uncategorized` — base rules only.
enum AppCategory: String, Codable, CaseIterable, Sendable, Equatable, Identifiable {
    case messaging
    case email
    case social
    case notes
    case docs
    case code
    case search
    case uncategorized

    var id: String { rawValue }

    /// Human-readable label used in the Instructions tab UI.
    var displayName: String {
        switch self {
        case .messaging:     return "Messaging"
        case .email:         return "Email"
        case .social:        return "Social"
        case .notes:         return "Notes"
        case .docs:          return "Docs"
        case .code:          return "Code"
        case .search:        return "Search"
        case .uncategorized: return "Uncategorized"
        }
    }

    /// One-line caption for the categories list (under the display name).
    var blurb: String {
        switch self {
        case .messaging:     return "Chats, IM, AI conversations"
        case .email:         return "Letters with greeting and sign-off"
        case .social:        return "Public posts, hashtags, mentions"
        case .notes:         return "Personal notes & PKM apps"
        case .docs:          return "Structured documents for others"
        case .code:          return "IDEs, editors, terminals"
        case .search:        return "Search fields & address bars (AX-detected)"
        case .uncategorized: return "Unknown apps & fallback"
        }
    }

    /// Categories the LLM categorizer is allowed to return. Excludes
    /// `.search` (AX-only — see `CategoryResolver`) and `.uncategorized`
    /// is returned only as a low-confidence escape hatch.
    static var classifierCases: [AppCategory] {
        [.messaging, .email, .social, .notes, .docs, .code]
    }

    /// Categories the user can manually move an app into. Excludes
    /// `.search` (AX-only) and `.uncategorized` (achieved by removing
    /// the assignment rather than setting it).
    static var manuallyAssignableCases: [AppCategory] {
        [.messaging, .email, .social, .notes, .docs, .code]
    }

    /// Default category-instruction prompt for this category, shipped as
    /// the `Category instruction:` block in the Gemini cache prefix when
    /// the user hasn't customised it. `uncategorized` returns `nil` — the
    /// block is omitted entirely from the request for unknown apps.
    var defaultPrompt: String? {
        switch self {
        case .messaging: return Self.messagingPrompt
        case .email:     return Self.emailPrompt
        case .social:    return Self.socialPrompt
        case .notes:     return Self.notesPrompt
        case .docs:      return Self.docsPrompt
        case .code:      return Self.codePrompt
        case .search:    return Self.searchPrompt
        case .uncategorized: return nil
        }
    }

    /// Parse a string returned by the categorizer LLM. Unknown values
    /// collapse to `.uncategorized` so a hallucinated category never
    /// crashes the pipeline.
    static func parseClassifierResponse(_ raw: String) -> AppCategory {
        AppCategory(rawValue: raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
            ?? .uncategorized
    }

    // MARK: - Default prompt texts (verbatim from the prompt-engineering brief)

    private static let messagingPrompt = """
    This text is going into a chat or messenger app. Users in this context write short, conversational messages. Formatting conventions:

    - Keep sentences short and natural. Don't over-punctuate.
    - Multiple sentences on the same topic stay on one line — no line breaks unless the speaker explicitly says "new line" or paused long enough that the chunk boundary suggests a new message.
    - Lowercase sentence starts are acceptable if the speaker's tone is casual. Match the register of the speaker.
    - No greetings, salutations, or sign-offs unless the speaker explicitly dictated them.
    - Emoji only if the speaker said the emoji name explicitly (e.g. "smiley face").
    """

    private static let emailPrompt = """
    This text is going into an email client. Users compose structured letters here. Formatting conventions:

    - If the speaker opens with a greeting (e.g. "Hi Sarah", "Доброе утро, Дмитрий", "Querida Maria"), put it on its own line, followed by a blank line, then the body.
    - If the speaker closes with a sign-off (e.g. "Best", "Thanks", "С уважением", "Saludos"), put a blank line before it, then the sign-off on its own line, then the speaker's name on the next line if dictated.
    - Paragraph breaks inside the body: insert a blank line when the speaker shifts topic or pauses long enough to suggest a new paragraph.
    - Standard sentence-case capitalization. Full terminal punctuation on complete sentences.
    - Do NOT invent a greeting or sign-off the speaker did not dictate. If they jumped straight into the body, leave it as body.
    """

    private static let socialPrompt = """
    This text is going into a social media or public posting app. Users compose posts for a public audience here. Formatting conventions:

    - Standard sentence-case capitalization and full punctuation in most cases, but adapt to the platform's convention if obvious from context.
    - Treat dictated hashtags as hashtags. When the speaker says "hashtag X" (or equivalent in their language), render as `#X` with no space.
    - Treat dictated mentions as mentions ONLY when the speaker uses an unambiguous mention cue — "mention X", "tag X", or "at-mention X" (or the natural equivalent in their language). Render as `@X` with no space. A bare locative "at" ("at home", "at three pm", "at the office") is NOT a mention — keep it as the preposition.
    - No greetings or sign-offs — posts address the audience implicitly.
    - Line breaks between distinct points if the speaker pauses to shift topic. Otherwise keep as flowing prose.
    - Emoji only if the speaker said the emoji name explicitly.
    """

    private static let notesPrompt = """
    This text is going into a note-taking app. Users write longer-form personal text here. Formatting conventions:

    - Use natural paragraph structure. Break paragraphs when the speaker shifts topic or pauses noticeably between thoughts.
    - Standard sentence-case capitalization and full punctuation.
    - No greetings or sign-offs — notes are for the user, not addressed to anyone.
    - If the speaker dictates a list (e.g. "first thing, second thing, third thing" or "пункт первый, пункт второй"), format as a bullet list with `- ` markers, one item per line. Otherwise prose.
    - If the speaker says "header" or "heading" followed by text, format that text as a markdown heading on its own line with `# `.
    """

    private static let docsPrompt = """
    This text is going into a structured document app. Users write formal, longer-form content for others to read. Formatting conventions:

    - Standard sentence-case capitalization and full punctuation throughout.
    - Paragraph breaks: insert a blank line whenever the speaker shifts topic or pauses noticeably between thoughts. Lean toward more paragraphs rather than fewer.
    - If the speaker says "heading" or "header" followed by text, format as a markdown heading on its own line with `# ` (or `## ` if they specify a level).
    - If the speaker dictates a list ("first... second... third...", or "пункт первый... пункт второй..."), render as a bullet list with `- ` markers.
    - If the speaker says "new section" or "new chapter", insert a blank line, then a `##` heading if they dictate a title, otherwise just the blank line.
    - No greetings or sign-offs unless the speaker explicitly dictates them.
    """

    private static let codePrompt = """
    This text is going into a code editor, IDE, or terminal. Users dictate either code, technical comments, or shell commands. Formatting conventions:

    - Spell technical terms as code identifiers: programming languages, library names, function names, file paths, CLI flags, environment variables. Use the on-screen context to match exact spelling and casing.
    - Minimal natural-language punctuation. No greetings, no sign-offs.
    - If the speaker is clearly dictating code (says keywords, operators, brackets aloud — "open paren", "equals", "new line"), render those as actual syntax, not as words.
    - If the speaker is dictating a comment or commit message, render as prose without code syntax.
    - When in doubt between code and prose, default to prose — let the user fix it rather than miswriting code as natural language.
    """

    private static let searchPrompt = """
    This text is going into a search field or address bar. Formatting conventions:

    - NO terminal punctuation (. ! ?). Search engines and address bars perform worse with punctuation.
    - Lowercase unless the speaker explicitly used a proper noun.
    - No greetings, no sign-offs, no list formatting, no markdown.
    - Keep it terse — search queries are typically 2 to 8 words. If the speaker dictated more, transcribe verbatim, but don't add filler.
    - No hashtags or mentions unless the speaker explicitly dictated the symbol.
    """
}
