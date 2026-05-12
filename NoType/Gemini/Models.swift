import Foundation

/// Codable types for the subset of the Gemini `generateContent` REST schema
/// we use. Intentionally minimal — only the fields transcription needs.
/// Chunking and implicit-cache prefix are already in service; `usageMetadata`
/// exposes the `cachedContentTokenCount` we monitor in debug builds.
enum GeminiAPI {}

extension GeminiAPI {
    struct Request: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig?
        let systemInstruction: Content?
        /// Tool-use declarations (e.g. `googleSearch`). nil for normal
        /// transcription requests; populated for the app-classifier call
        /// which needs grounded web lookup to identify unfamiliar bundle
        /// ids. Omitted from the encoded JSON when nil (synthesized
        /// `encodeIfPresent` for Optional members).
        let tools: [Tool]?

        init(
            contents: [Content],
            generationConfig: GenerationConfig?,
            systemInstruction: Content?,
            tools: [Tool]? = nil
        ) {
            self.contents = contents
            self.generationConfig = generationConfig
            self.systemInstruction = systemInstruction
            self.tools = tools
        }

        enum CodingKeys: String, CodingKey {
            case contents
            case generationConfig
            case systemInstruction = "system_instruction"
            case tools
        }
    }

    /// Tool declaration. The Gemini REST schema accepts an array of tools
    /// each carrying one declared capability — currently we only use
    /// `googleSearch` for the categorizer.
    struct Tool: Encodable {
        let googleSearch: GoogleSearchTool?

        enum CodingKeys: String, CodingKey {
            case googleSearch = "google_search"
        }
    }

    /// Empty payload — `{"google_search": {}}` opts the model into
    /// web-grounded results for this request.
    struct GoogleSearchTool: Encodable {}

    struct GenerationConfig: Encodable {
        let topP: Double?
        let responseMimeType: String?
        let thinkingConfig: ThinkingConfig?

        enum CodingKeys: String, CodingKey {
            case topP = "top_p"
            case responseMimeType = "response_mime_type"
            case thinkingConfig   = "thinking_config"
        }
    }

    struct ThinkingConfig: Encodable {
        let thinkingLevel: String?

        enum CodingKeys: String, CodingKey {
            case thinkingLevel = "thinking_level"
        }
    }

    struct Content: Encodable {
        let role: String?
        let parts: [Part]
    }

    enum Part: Encodable {
        case text(String)
        case inlineData(mimeType: String, data: String)

        private enum Keys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }

        private struct InlineData: Encodable {
            let mimeType: String
            let data: String
            enum CodingKeys: String, CodingKey {
                case mimeType = "mime_type"
                case data
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .text(let t):
                try c.encode(t, forKey: .text)
            case .inlineData(let mime, let b64):
                try c.encode(InlineData(mimeType: mime, data: b64), forKey: .inlineData)
            }
        }
    }

    struct Response: Decodable {
        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
        let error: APIError?
        let usageMetadata: UsageMetadata?

        enum CodingKeys: String, CodingKey {
            case candidates
            case promptFeedback
            case error
            case usageMetadata
        }
    }

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let cachedContentTokenCount: Int?
    }

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?

        struct Content: Decodable {
            let parts: [Part]?
            let role: String?
        }

        struct Part: Decodable {
            let text: String?
        }
    }

    struct PromptFeedback: Decodable {
        let blockReason: String?
    }

    struct APIError: Decodable {
        let code: Int?
        let message: String?
        let status: String?
    }
}
