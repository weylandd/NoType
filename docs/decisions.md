# Architecture Decision Records

> **Migration in progress.** Per the compound-engineering framework, decisions / rationale / rejected alternatives belong in **per-decision files** under `docs/solutions/<category>/`, not in this monolith. ADRs that have moved link to their new home below; the rest still live in this file and will be migrated PR-by-PR.
>
> **Adding a new decision?** Skip this file — write directly into `docs/solutions/<category>/<slug>-<YYYY-MM-DD>.md` using the knowledge-track shape (`## Context → ## Guidance → ## Why This Matters → ## When to Apply → ## Examples → ## Related`). See `docs/solutions/README.md` for the frontmatter contract and category list.

These are the load-bearing decisions for NoType. **Do not relitigate without explicit discussion.** If you think one of these is wrong, open an issue first.

Format: short, blunt, with the alternative considered.

---

## ADR-001 — macOS 15 (Sequoia) minimum

**Migrated to:** [`solutions/tooling-decisions/macos-15-deployment-target-2026-05-15.md`](solutions/tooling-decisions/macos-15-deployment-target-2026-05-15.md)

---

## ADR-002 — Silero VAD instead of Apple SpeechDetector

**Migrated to:** [`solutions/tooling-decisions/silero-vad-coreml-2026-05-15.md`](solutions/tooling-decisions/silero-vad-coreml-2026-05-15.md)

---

## ADR-003 — Gemini 3.1 Flash-Lite

**Migrated to:** [`solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md`](solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md)

---

## ADR-004 — Clipboard-based paste (not AX text injection)

**Migrated to:** [`solutions/architecture-patterns/clipboard-cmd-v-paste-2026-05-15.md`](solutions/architecture-patterns/clipboard-cmd-v-paste-2026-05-15.md)

---

## ADR-005 — Right Option as default hotkey, via CGEventTap

**Migrated to:** [`solutions/design-patterns/right-option-cgeventtap-2026-05-15.md`](solutions/design-patterns/right-option-cgeventtap-2026-05-15.md)

---

## ADR-006 — One Gemini request in flight at a time

**Migrated to:** [`solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`](solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md)

---

## ADR-007 — No streaming responses from Gemini in v1

**Migrated to:** [`solutions/design-patterns/no-streaming-gemini-2026-05-15.md`](solutions/design-patterns/no-streaming-gemini-2026-05-15.md)

---

## ADR-008 — Local concatenation of chunk transcripts

**Migrated to:** [`solutions/design-patterns/local-chunk-concatenation-2026-05-15.md`](solutions/design-patterns/local-chunk-concatenation-2026-05-15.md)

---

## ADR-009 — Full-screen accessibility tree, not just focused window

**Migrated to:** [`solutions/design-patterns/full-screen-ax-tree-2026-05-15.md`](solutions/design-patterns/full-screen-ax-tree-2026-05-15.md)

---

## ADR-010 — JSON file for history, no DB, last 10 only

**Decision:** History is `~/Library/Application Support/NoType/history.json`, capped at 10 entries, plain text, not encrypted.

**Why:** Beta scope. SQLite/CoreData is overkill for a 10-entry FIFO. Unencrypted because the OS file permissions already restrict access to the user, and the threat model for beta does not include hostile local processes.

**Reconsider when:** product asks for history > 100 entries, search, or sync. Then move to SQLite.

---

## ADR-011 — BYOK (bring your own Gemini key), stored in Keychain

**Decision:** The user supplies their Gemini API key in Settings; we store it in macOS Keychain. No proxy, no hosted key.

**Why:** NoType is open source and free. We don't want to operate a billing relationship for v1. Users who want frictionless setup can wait for the future paid tier.

**Trade-off accepted:** Onboarding friction. Mitigated by clear instructions and a deep link to Google AI Studio for key creation.

---

## ADR-012 — Direct download distribution, not Mac App Store

**Decision:** Ship as a notarized .dmg with Sparkle for updates. Not on the Mac App Store.

**Why:** NoType needs Accessibility permission and `CGEventTap`. Both technically work in MAS sandboxed apps, but with extra entitlement reviews and edge-case bugs. For a free OSS app, the MAS overhead isn't worth it.

**Reconsider when:** the project goes paid-tier and wants discovery.

---

## ADR-013 — No telemetry in v1

**Decision:** Zero telemetry, zero analytics, zero crash reporting in v1. No data about the user or their dictation behavior leaves the device.

**Why:** Open-source, privacy-respecting positioning. Crash reports can be added later as opt-in via Sentry-like service. For now, users report issues on GitHub.

**Local-only carve-out:** `StatsStore` (`~/Library/Application Support/NoType/stats.json`) keeps lifetime aggregates that drive the Home tab — total words, session count, per-day buckets, per-app totals. **It never leaves the device.** No network call ever touches this file. It's derived counts only — no transcripts, no audio, no PII. See `NoType/History/CLAUDE.md` "Lifetime stats" for the schema and `ADR-010` for the related history-store decision.

**Reconsider when:** actual stability complaints arrive that we can't reproduce. Then add opt-in crash reporting only.

---

## ADR-014 — Optional screenshot + OCR fallback for AX-poor apps

**Decision:** When the macOS accessibility tree returns no usable content for the user's active app — which happens routinely on Electron (Slack, Discord, VS Code), web-views (Notion, Linear web, Figma), and custom-NSText apps — fall back to:
1. Screenshotting the active window via `ScreenCaptureKit` (`SCScreenshotManager.captureImage`).
2. Running local OCR via `Vision` (`VNRecognizeTextRequest`, accurate level, auto language).
3. Scrubbing each recognised line through `SecureFieldMasker.scrubContent` (cards, bearer tokens, JWTs, GitHub / OpenAI / Google / Slack / Stripe / AWS keys, PEM blocks, URL creds, 40-char opaque tokens).
4. Appending the resulting text inside the **existing** `On-screen context:` Gemini prompt part — no new top-level section, the 5-text-parts cached-prefix shape stays intact.

The feature is **opt-in via the Screen Recording TCC permission** and has **no separate Settings toggle in v1**. If the user grants permission in onboarding (carded as "Optional"), the fallback runs whenever AX comes back contentless for the active app. If they skip, behaviour is identical to today's AX-only path.

**Why:**
- AX is genuinely the best source when it works; OCR-everything would inflate tokens and lose the metadata-driven `SecureFieldMasker` skip-rule layer for password fields.
- An adaptive fallback recovers the apps users dictate into most (Slack, Discord, Notion, web inboxes) without paying any cost on AX-rich apps (Mail, native compose boxes).
- Local OCR keeps the privacy posture explicit: pixels never reach Gemini, recognised text is scrubbed before it enters the prompt, no screenshots are persisted.
- Embedding inside the existing `On-screen context:` part preserves the implicit-cache contract pinned by `GeminiRequestBuilderTests`.

**Decisions inside the decision:**
- **Active window only.** Full-screen OCR would be ~2× the cost and dramatically widen the privacy surface.
- **OCR is on the critical path of the first chunk.** The `contextTask` does not gate the user's hotkey press — audio capture starts immediately — but the first Gemini request `await`s the snapshot before dispatch. Concretely, OCR runs in parallel with the AX walk; both are independent siblings under per-task wall-clock caps (AX 1500 ms, OCR 2500 ms — generous safety belts, not perceived-latency budgets). The first audio chunk can't be produced until VAD detects a ≥1 s pause OR the user releases, so for any session >1 s the OCR latency is masked by speech time.
- **Local Vision OCR, not Gemini multimodal.** Multimodal would skip OCR code but ship raw pixels to the cloud (no scrub possible) and inflate tokens.
- **Type-level guarantee preserved.** `ScreenCaptureContext.capture(...)` returns a `RedactedScreenText?` whose initializer is module-internal — same shape as `RedactedAXSnapshot`. There is no public path from raw `CGImage` text to the network.

**Trade-offs accepted:**
- Quick-release sessions (<500 ms hotkey hold, immediate paste expected) may add up to ~2.5 s of perceived latency if OCR is slow on a dense screen. Realistic median is 100–500 ms. Acceptable: short utterances rarely benefit from OCR-context disambiguation anyway.
- On AX-rich apps, we run Vision OCR in parallel and then throw the result away (~150 ms of CPU we paid for nothing). Acceptable — the alternative (serial: wait for AX, then conditionally start OCR) would add ~150 ms to the first chunk in the AX-poor case where the user feels the latency.
- AX and OCR have **independent** caps and partial results survive: if AX completes but OCR runs over its cap, AX result is used; if OCR completes but AX times out, OCR is used with an empty-tree fallback. The previous joint-deadline design discarded both on either overrun (deliberately replaced after observing Mail timeouts in v1 testing).
- ADR-013's "no screen recording" line is softened to "no screen recording by default". The capability exists, requires explicit user action, and never persists pixels.

**Alternatives considered:**
- **Always OCR (replace AX).** Rejected — loses cross-window context AX provides on Mail/Xcode/etc.
- **Always run both, always include OCR in prompt.** Rejected — bloats the cached prefix by 2–5K tokens even when AX was sufficient.
- **Gemini multimodal (send the JPEG itself).** Rejected — cannot scrub pixels client-side, worse for privacy.

**Reconsider when:**
- Apple ships a sandboxed equivalent that doesn't require Screen Recording permission.
- We find an OCR-text shape the masker doesn't cover and users report leakage — extend `SecureFieldMasker` rather than disabling the fallback.

---

## ADR-015 — Per-app categorization + user / category instructions in the cache prefix

**Decision:** Replace the bundle-id-to-`StyleHint` enum dictionary (`appStyleHints` — 8 hard-coded entries) with a two-layer system:

1. **Per-app `AppCategory`** — one of `messaging`, `email`, `social`, `notes`, `docs`, `code`, `search`, `uncategorized`. Resolved by an LLM categorizer (one `generateContent` call to `gemini-3.1-flash-lite` with `googleSearch` tool enabled) on the first session in an unfamiliar app, cached forever in `~/Library/Application Support/NoType/instructions.json`. Source-tagged (`auto` / `manual`) so a user override survives subsequent re-classifications. `search` is never returned by the classifier — it's an AX-only override resolved at session start when the focused element looks like a search field or address bar.
2. **`User instruction:` and `Category instruction:` prompt sections** — new optional cache-prefix parts that ship alongside `App: ... / Category:`. User instruction is a free-form textarea (global, applies to every session). Category instruction is per-category and defaults to a developer-supplied prompt, with a Settings-side override per category.

The cached prefix grows from 5 to up to 7 textual parts. The two new sections are conditionally omitted (`User instruction:` when empty, `Category instruction:` when nil — typical for `.uncategorized`); both decisions are frozen at session start and remain stable for every chunk of that session, so implicit caching still hits chunk-to-chunk inside a session.

> **Update (ADR-016):** the personal-dictionary feature added a `User dictionary:` part (always present, body `(empty)` when no entries), shifting the actual cached-prefix shape to **6/7/8** parts. The User-/Category-instruction omission rules described above are unchanged. See ADR-016 and `NoType/Gemini/CLAUDE.md` for the post-dictionary part order.

**Why:**
- The old `appStyleHints` dictionary covered 8 bundle ids and gave the model exactly one of 5 register hints. It was strictly worse than per-app categorization that adapts behavior per channel (line breaks in email, no terminal punctuation in search, hashtag handling in social) AND lets the user tune both their global style and per-category formatting.
- A new tool-call per app is cheap (<1¢ over an app's whole lifetime — classification happens once, cached forever) and is fire-and-forget so it never blocks recording.
- The `search` override is the highest-leverage case — without it, dictating into Chrome's omnibox gets the bundle's category (often `uncategorized` or `messaging`), which adds terminal punctuation to search queries and degrades results. Implementing it as a synchronous AX read at session start (no extra Gemini call) keeps the search experience snappy.
- Keeping `User instruction:` and `Category instruction:` as cache-prefix sections (rather than mixing them into the system instruction) preserves caching: a user can edit their global instruction between sessions without invalidating any per-session cache.

**Decisions inside the decision:**
- **Single SKU.** Both transcription and classification use `gemini-3.1-flash-lite`. One model id, one pricing surface, simpler operational story. The classifier turns on `tools: [{"google_search": {}}]`; transcription does not.
- **Confidence gating.** The classifier returns `{"category", "confidence": "high|medium|low"}`. Only `high` / `medium` are cached. `low` and `uncategorized` outputs trigger a retry on the next session — keeps the cache honest at the cost of occasionally re-charging for the call.
- **Manual overrides are sticky.** `InstructionsStore.upsertAutoAssignment` refuses to overwrite an existing `source: .manual` record. The user can force re-classification from the Instructions tab via the "Re-classify with AI" menu item, which removes the assignment and fires a fresh classify.
- **Two omittable sections, never both required.** The user instruction can be empty and the category can be `.uncategorized` — yielding the same 5-text-part shape the pre-feature behavior had. New users see no behavioral regression until they start using either field.
- **No window-title in the classifier input (v1).** The classifier only sees `display_name` + `bundle_id`. Window titles can leak PII (draft subject lines, file paths) and would need `SecureFieldMasker.scrubContent` first. Acceptable accuracy hit for v1 — revisit if browser-based apps need disambiguation.

**Trade-offs accepted:**
- The cached prefix shape changes — all 13 `GeminiRequestBuilderTests` were rewritten to pin the new contract. This is a one-time cost; the new tests cover more ground (conditional omission, byte-stability with both optional sections present, search-category rendering).
- The classifier call is one extra ~500 ms HTTP request per new app per user, on the first session. Fire-and-forget so it never blocks recording, but it does spend a small amount of API quota.
- The Instructions tab adds non-trivial UI surface (textarea + per-category drill-in + apps list with reassign menu). Net surface ~600 lines of SwiftUI — accepted in exchange for the per-channel formatting wins and the user's ability to customize behavior end-to-end.

**Alternatives considered:**
- **Keep `appStyleHints` and grow it.** Rejected — doesn't scale (we'd have to ship app dictionary updates for every popular app), doesn't help with user-level customization, and doesn't handle the search-field case.
- **Single big system-prompt swap based on category.** Rejected — would invalidate cache between any two sessions with different categories. Keeping category-specific text in `Category instruction:` as a separate prompt part preserves the cross-session cache when the category happens to match.
- **Pre-bake category assignments for the top 100 apps and skip the classifier.** Rejected — would cover the head but miss the long tail. The classifier handles unfamiliar apps automatically; pre-baked lookups are maintenance debt.
- **Categorize via a local on-device model (small Llama, etc.).** Rejected for v1 — adds a ~2 GB model dep, marginal accuracy vs Gemini-with-web-search, and we'd lose the disambiguation that web search provides for unfamiliar bundle ids.

**Reconsider when:**
- The classifier mis-categorizes a common app shape we didn't anticipate (e.g. a popular markdown editor lands in `code` instead of `notes`). Add to the categorizer's disambiguation guidance section; don't introduce a hard-coded override.
- Window titles become necessary for browser-based apps. Re-introduce them as a `optional` field in the classifier input AND prepend `SecureFieldMasker.scrubContent` in the same change.

---

## ADR-016 — Personal dictionary (canonical spellings + replacement pairs)

**Decision:** Add a new self-contained `NoType/Dictionary/` module backing a third main-window tab. It owns two independent concerns:

1. **`User dictionary:` cache-prefix section.** A new section in every Gemini transcription request, between `Category instruction:` (optional) and `Insertion target:`. Comma-separated list of canonical spellings — brands, proper nouns, jargon — that biases Gemini's transcription of the audio it actually hears. **Always present**, even when the list is empty (body `(empty)`).
2. **Auto-replacement pass.** Pure client-side find/replace pairs (e.g. `то есть → т.е.`) applied to the final stitched transcript **between** `finalizeForInsertion` and `paste` — i.e. after Gemini, never sent to Gemini.

Both concerns persist to `~/Library/Application Support/NoType/dictionary.json`. Mirrors `InstructionsStore` operationally: actor isolation, atomic writes, corruption recovery via `.corrupt-<ts>` rename.

Dictionary entries are mixed-source:
- **User-added** (sticky, never trimmed by cap logic, max 30 chars per entry, capped at 100 manually).
- **Auto-harvested** by `DictionaryHarvester` (pure client-side function) after each successful session — see "Auto-harvest" below. FIFO trim when total > 100 — auto entries go oldest-first; user entries are sticky.

**Auto-harvest is skipped only when user-entry count is at the cap (100).** With all slots filled by sticky user entries, the harvester can't write anything anyway. There is no "extraction skip threshold" / "auto-extraction paused at 80" — that was v1 LLM-extractor logic and is gone in v2.

The cached prefix grows from 7 to 8 textual parts (unchanged from v1).

**Auto-harvest design (v2 — supersedes v1 LLM extractor):**

The original ADR-016 v1 used a one-shot Gemini call per session to suggest dictionary candidates from the final transcript text. In practice this produced **few and noisy terms** — the extractor was given only the bare transcript text plus existing dictionary entries, so it had to guess which terms were proper nouns vs common words, with no access to the audio or the on-screen context the transcription model used.

**v2 replaces the LLM extractor with a pure-function client-side intersector** (`DictionaryHarvester.harvest`):

1. Tokenize the just-pasted transcript (Unicode word boundaries plus atypical-text binders `.`, `_`, `/`, `-`).
2. For each token position, try increasing multi-word spans (3 → 2 → 1 tokens). Search the on-screen context the model saw at session start (AX tree + optional OCR + insertion target's textBefore/After) for the phrase, case-insensitive with proper word-boundary handling.
3. When a span matches, capture the **context's casing** as canonical, apply a shape filter (must look proper-noun-ish: starts with uppercase, has internal mixed-case, all-caps, or contains an atypical binder), dedup case-insensitively against existing dictionary, and save.
4. Longest-match priority — `Вася Пупкин` wins over saving `Вася` and `Пупкин` separately.
5. Cap at 5 candidates per session, 30 chars per entry.

**Why v2 instead of v1:**
- **Quality**: a candidate is added iff it appears in BOTH the transcript AND the surrounding context the model saw. By construction, the entry is something the context disambiguated — exactly what we want the dictionary to seed for future sessions where that context won't be available.
- **Cost**: zero API calls. One Gemini call per session vanishes from the bill.
- **Latency**: <5 ms client-side vs ~500 ms LLM round-trip. Harvest is now synchronous in `AppState.finalizeRecording`, not fire-and-forget.
- **Determinism**: same input → same output. No model stochasticity, no hallucinated "weird terms" the user complained about in v1.
- **Privacy**: the transcript no longer leaves the device for the purpose of extraction. Gemini still gets the transcript during transcription, but not a second time for analysis.

**Decisions inside the decision (v2):**
- **Shape filter applies to the CANONICAL form (context's casing), not the transcript form.** Reason: the transcription engine sometimes writes proper nouns lowercase when audio is unclear; the on-screen context has the right casing. Checking shape on the canonical form is what lets `anthropic` in the transcript save as `Anthropic` from the on-screen text.
- **No common-words stoplist.** Shape filter (proper-noun-like or atypical-binder-bearing) handles UI chrome rejection. Lowercase plain words ("send", "inbox", "reply") never reach saving.
- **Atypical binders kept anywhere in the token** — covers `claude.md`, `generate_keys`, `bin/python`, `state-of-the-art`, `_priv`, `bin/`. The user explicitly asked for this; it captures filenames, identifiers, and CLI paths.
- **Internal period only.** A trailing period (sentence end) is dropped during tokenization. `Anthropic.` → `Anthropic`. `claude.md` → `claude.md` (period followed by `m`).
- **30-char cap on dictionary entries** (raised from 20 in v1). With the algorithmic intersector, max 3-word spans of typical English/Slavic words land well under 30. The cap exists primarily as a sanity-check against parser misbehavior and as a soft UX limit on manual entries; it also matches `DictionaryHarvester.sanityMaxLength`.
- **Single-letter trigger rejected** (`minSingleTokenLength = 2`). Tokens like "I" or "A" pass shape but are never useful as dictionary entries.
- **Replacement matching: word-boundary + auto-capitalised variant** — unchanged from v1. ICU-aware `\b` so Cyrillic / other Unicode alphabets work. When `from` starts with a lowercase letter we auto-generate a capitalized variant — `то есть → т.е.` also matches `То есть` and replaces it with `Т.е.`. All-caps (`ТО ЕСТЬ`) is intentionally not matched; the user adds an explicit pair if they need it.
- **30-char cap only on dictionary entries**, not on replacement pairs. Replacement values often expand abbreviations and routinely exceed 30 chars; the cap exists to prevent the prompt section from being bloated, which doesn't apply to client-side find/replace.
- **`DictionaryContext` is frozen at session start** — unchanged from v1. Edits to the Dictionary tab during a recording session don't affect the in-flight transcription or the paste-time replacements. The frozen snapshot lives on `RecordingSession`; `replacements` is stored on the session as `replacementsFrozen` (separate from `cachedContext`) so a quick-release path that falls back to `ContextSnapshot.minimal(activeApp:)` still gets the user's replacement pairs applied.
- **Length filter and case-insensitive dedup at every entry point** — UI textfield, `DictionaryStore` mutators, `DictionaryHarvester` (`sanityMaxLength`), and the on-disk decoder. A hand-edited `dictionary.json` can't sneak overlong / duplicate entries past the cache prefix.

**Trade-offs accepted (v2):**
- The cached Gemini prefix shape is unchanged at 8 text parts — `GeminiRequestBuilderTests` continues to pin the v1 contract.
- The harvester misses terms whose canonical form on screen happens to be lowercase (rare but possible — a broken AX label, or a deliberately lowercase brand like "stripe" used inline in body text). v1 LLM extractor could in theory have caught these; v2 silently drops them. Acceptable: lowercase brand names are rare, and the next session where context is correctly cased picks them up.
- The harvester relies on the on-screen context being captured during the session. Sessions where AX returned nothing AND Screen Recording was off get an empty `contextText` → no candidates. Pre-v2 same sessions still produced LLM candidates from transcript alone. Net trade is fewer-but-cleaner candidates; user feedback in v1 was that the LLM produced "noisy and few" terms, so optimizing for cleanliness over volume is the right move.
- The Dictionary tab adds ~500 lines of SwiftUI surface (replacement table + tag-cloud flow layout + add/edit affordances + per-entry chip with delete) — unchanged from v1.

**Alternatives considered:**
- **Skip the `User dictionary:` prompt section, do replacements only.** Rejected — replacements can't fix what Gemini didn't catch correctly in the audio. A Russian speaker dictating "Anthropic" in their accent gets back transliterated Cyrillic; the dictionary biases Gemini to pick "Anthropic" up front, before any replacement could ever fire.
- **Single mixed list with no source distinction.** Rejected — without `.user` / `.auto` source labels we can't make the trim FIFO honour manual additions and can't visually distinguish "your terms" from "what we learned" in the UI.
- **Multi-turn LLM extractor that continues the transcription conversation.** Considered for v2 in place of the algorithm. Rejected after weighing: the algorithm gives stronger "context-derived only" guarantees by construction, costs nothing per session, and is deterministic. The LLM-multi-turn path would have added complexity (replaying the conversation as `user(audio)→model(transcript)→user(extract)`), depended on implicit cache TTL covering the gap between session end and extractor fire, and still risked the original "noisy and few" failure mode.
- **Hybrid (algorithmic + LLM fallback for empty algorithmic results).** Rejected — added complexity and unclear value. If the algorithm finds nothing, the on-screen context didn't actually disambiguate anything, and the LLM would just be guessing again.
- **Per-app dictionaries (Slack-only entries, Linear-only entries).** Rejected for v1 — the user's brands / names are largely consistent across apps. Re-introduce if a real use case surfaces (e.g. domain-specific jargon that's relevant only to one app).
- **Sync the dictionary across devices via iCloud.** Out of scope for v1; revisit when Sparkle auto-update lands and we have an opinion on cross-device state in general.

**Reconsider when:**
- Users start complaining that the harvester misses lowercase brand names they actually dictate frequently (Stripe / stripe, etc.). Add an "ignore casing" mode where any 4+ char alphabetic match in context is allowed through, behind a Dictionary-tab toggle.
- The 30-char cap turns out to truncate real entries users care about (long compound names, technical phrases). Bump up to 50.
- The replacement pass introduces user-visible bugs at boundaries (e.g. interaction with `finalizeForInsertion`'s leading-space rule). Move replacements to before boundary normalisation and add tests pinning both branches.

---

## ADR-017 — Sparkle 2 auto-updates with a custom in-app banner UI

**Decision:** Distribute NoType updates via **Sparkle 2** (SPM dep, `from: 2.6.0`). Appcast lives in this repo at `docs/appcast.xml`, served by **GitHub Pages** from `/docs` of `weylandd/NoType` at `https://weylandd.github.io/NoType/appcast.xml`. Release binaries (`.dmg` + `.zip`) live on **GitHub Releases** of the same repo. The .zip is the Sparkle artefact, signed with **EdDSA** (`sign_update`); the .dmg is the first-time-install artefact the README links to.

The update UI is custom: a small "Update to X.Y.Z" pill in the main-window sidebar rendered by `NoType/UI/UpdateBanner.swift`, driven by `NoType/Updates/UpdateController.swift` wrapping `SPUUpdater` with a custom `SPUUserDriver` (`NoType/Updates/UpdateUserDriver.swift`) — **Sparkle's standard modal alert window is bypassed entirely**. Click the banner → Sparkle downloads, verifies the EdDSA signature against `SUPublicEDKey` in `Info.plist`, and relaunches on the new build. No manual "Check for updates" button and no auto-check toggle ship in v1; daily scheduled checks are always on.

**Why:**
- **Sparkle 2 over Sparkle 1.x:** Sparkle 1 is on a frozen branch since 2022, doesn't ship strict-concurrency-friendly APIs, and has known XPC quirks on macOS 26. Sparkle 2.6+ adopts MainActor + Sendable, has a clean `SPUUserDriver` protocol for custom UIs, and is the actively maintained line.
- **Sparkle 2 over rolling our own:** Auto-updating macOS apps correctly is hard — EdDSA signature verification, atomic in-place replacement (Sparkle uses a relauncher process so the app can replace itself), TCC preservation across the rebrand, ACL-aware Keychain access. Sparkle solves all of these; reproducing them would be 1000+ lines of finicky code we'd then need to maintain.
- **Custom user driver over `SPUStandardUserDriver`:** NoType is `LSUIElement = true`, a menu-bar utility. Sparkle's standard alert window steals focus and looks out of place. A compact in-sidebar pill matches the rest of the UI shape and how peers like Claude Desktop surface updates.
- **GitHub Pages from `docs/`, same repo:** stable CDN-cached URL (no rate-limit issues `raw.githubusercontent.com` has), zero cross-repo plumbing (no deploy keys / PATs to wire up), one repo to grant secrets to. The alternative — a separate `notype-releases` repo — is reasonable when the main repo is private and releases are public, neither of which applies here.
- **EdDSA (Ed25519) over DSA:** Sparkle 2 deprecates DSA. EdDSA keys are 32 bytes (vs DSA's 1 KB+), signing is fast, verification is constant-time. The private key lives in the developer's Keychain (and a password-manager backup); the public key is embedded in `Info.plist`. Losing the private key permanently kills the update path — every installed copy rejects releases signed with a new public key — so it gets the same "back it up" treatment as a TLS root CA.

**Decisions inside the decision:**
- **`.zip` for Sparkle, `.dmg` for first-time install.** The .zip path is faster (no `hdiutil attach`), cleaner to `sign_update`, and Sparkle's documented recommendation. The .dmg is what the README's "Download" link points to and what a fresh user installs by dragging — its UX is the right shape for an introduction, the .zip's isn't.
- **Auto-check always on, no user toggle, no manual trigger in Settings.** Same call as ADR-013 about telemetry: minimal v1, no controls that demand UX design we haven't earned. The check is in the background, the only visible artefact is the banner when a new release ships. Daily cadence is Sparkle's documented default. If users start complaining we'll add toggles.
- **Banner inside the sidebar, not a floating HUD.** HUDs are reserved for transient action-driven states (recording, transcribing, errors). An available update is a persistent state of the app that the user might ignore for hours; embedding it in the sidebar gives it the same visual weight as the nav items without pulling focus away from the main pane.
- **Auto-install on `showReady(toInstallAndRelaunch:)`.** When Sparkle finishes downloading and asks "ready to install + relaunch?", the custom driver replies `.install` without a second prompt — the user already clicked the banner once, asking again is friction. If we ever want a "download in background, install on next quit" flow we'll capture this reply on the controller and surface a second banner state.
- **GitHub Actions release on `push: tags: ['v*']`** — enabled. Tag a commit with `vX.Y.Z` and push; the workflow runs xcodegen → archive → notarize → sign → publish. See `docs/build.md` "Cutting a release" for the recipe and the CI-secret list. Local fallback (`scripts/release.sh` + `scripts/publish_release.sh`) is preserved and exercises the same code paths.

**Trade-offs accepted:**
- **`Package.resolved` is gitignored.** A future Sparkle 2.x bump could ship a regression we don't catch until the next CI release run. Mitigated by `from: 2.6.0` minimum + xcodebuild's lock-on-first-build, but not as airtight as committing the resolved file.
- **The banner has no "Skip this version" affordance in v1.** Users who click "dismiss" (via the future close button, not implemented yet) will see the banner again on the next scheduled check. Acceptable — `.skip` is a separate `SPUUserUpdateChoice` we can wire up when a real Settings surface needs it.

**Alternatives considered:**
- **Mac App Store auto-update.** Rejected — see ADR-012. NoType needs Accessibility + `CGEventTap`, both of which fight MAS sandboxing.
- **GitHub Releases polling without Sparkle.** Rejected — we'd have to ship our own download/verify/replace/relaunch flow, plus TCC preservation, plus delta updates if we ever want them. Sparkle's the right level of abstraction for this.
- **Hosted appcast on `notype.app` once domain lands.** Reasonable migration target. When the domain is set up, change `SUFeedURL` in `Info.plist` AND publish a `<sparkle:newSUFeedURL>` element in the old appcast for one release cycle so existing installs migrate forward. Out of scope today.

**Reconsider when:**
- Users start asking for a "Check for Updates…" menu — add a manual trigger to Settings, but keep the banner as the primary surface.
- We adopt delta updates (`generate_appcast --maximum-deltas N`) — small change to `scripts/release.sh` (sign the deltas too) + the appcast item generator.
