---
date: 2026-05-17
topic: settings-screen
---

# Settings Screen

## Summary

Полноценный Settings-экран в NoType — 4-й tab в sidebar главного окна, с 5 секциями (General / Shortcuts / Microphone & Audio / API / System), консолидирующий разбросанные сегодня настройки и добавляющий новые controls (Open on login, Prevent sleep, Sound effects, Music interruption, Output language как подсказка Gemini, Delete all transcripts, Check for updates, 3-й recording-mode Hold+Space, настраиваемый cancel-shortcut) плюс API-секцию с управлением Gemini-ключом и windowed token-stats, скрытую для будущих SaaS/login-юзеров.

---

## Problem Frame

NoType сегодня предлагает только лёгкую `SettingsView` sheet, открываемую из popover gear: одна страница с paste-delay slider'ом, hotkey-binding, mic-picker'ом, dictionary toggle'ом и BT-input avoidance toggle. Базовая для voice-dictation утилит часть контролов вообще не существует (Open on login, Prevent sleep, Music interruption, Sound effects), часть существует но недоступна для юзера (Output language всегда auto-detect, Recording mode жёстко Hold-to-record + Double-tap), часть существует но спрятана глубоко (mic picker в popover footer, hotkey binding только в onboarding-wizard'е).

Самая большая дыра — управление Gemini API-ключом и видимость собственного расхода токенов. Сегодня юзер вводит ключ в onboarding'е один раз и не имеет UI для смены или мониторинга расхода. Это критично для BYOK-модели: пользователь должен видеть свой billing-footprint и иметь возможность ротации ключа без переустановки приложения.

Конкуренты voice-dictation на macOS (Monologue, Wispr Flow) шипят settings'ы с 5+ секциями. Без аналога NoType выглядит prototype-grade, и каждая новая фича упирается в «куда это положить».

---

## Actors

- A1. **BYOK user** — текущий и единственный режим v1. Юзер с собственным Gemini API key, ключ в Keychain. Видит и управляет ключом + статистикой токенов через API-секцию.
- A2. **SaaS / login user** — будущий режим, **не реализуется в v1**. Юзер с подпиской на NoType-as-a-service, без необходимости управлять Gemini-ключом. API-секция для него скрыта целиком; на её место в будущем встанет Profile/Plan-секция (дизайн вне scope этого документа).

---

## Requirements

**Settings UI architecture**

- R1. Settings-экран реализуется как 4-й элемент sidebar главного окна (наряду с Home / Instructions / Dictionary), не как отдельное preferences-окно (⌘,) и не как sheet.
- R2. Внутри Settings — 5 секций: General, Shortcuts, Microphone & Audio, API, System.
- R3. **API-секция видна только в BYOK-режиме** (см. R26). Имя «API» зарезервировано под будущий SaaS/login-режим, но контент v1 = только BYOK-вариант.
- R4. Popover gear-icon, ранее открывавший лёгкий sheet, теперь открывает главное окно на Settings-tab'е. Старая `SettingsView` sheet удаляется целиком.
- R5. Settings переиспользует существующие `DesignTokens` и `DSComponents` — никаких inline-стилей или новых color/space/radius/font tokens.

**General section**

- R6. **Theme picker** (Light / Dark / System) экспонирует существующий `AppearanceController`; не пишется заново.
- R7. **Open on login** toggle — приложение auto-launch'ится при логине пользователя (`SMAppService`).
- R8. **Prevent sleep during recording** toggle — пока идёт активная запись, система не уходит в sleep (`IOPMAssertion` на время recording-session).
- R9. **Sound effects** toggle — короткий звук на старт/конец записи (accessibility + audio-confirm).
- R10. **Reset onboarding** button — открывает onboarding-wizard заново; сбрасывает только wizard-state (`OnboardingState`), **НЕ** удаляет API key / hotkey / mic выбор / dictionary entries.

**Shortcuts section**

- R11. **Recording hotkey binding** дублирует picker из onboarding-wizard (оригинал в wizard остаётся доступным). Rebind во время активной записи запрещён (matches existing `HotkeyMonitor` rule).
- R12. **Recording mode picker** — три режима: Hold-to-record (текущий default), Double-tap-to-lock (уже существует), **Hold+spacebar-to-lock** (новый, добавляется). Юзер выбирает один.
- R13. **Cancel recording shortcut picker** — настраиваемый shortcut для отмены текущей записи (default: Esc). Валидация: нельзя выбрать ту же клавишу, что и recording hotkey.

**Microphone & Audio section**

- R14. **Microphone picker** дублирует picker из popover footer + onboarding mic-check (оригиналы остаются доступными).
- R15. **BT-input avoidance** toggle экспонирует существующий internal toggle (default ON; при системном BT-default переключается на встроенный mic, чтобы не уронить music quality через HFP/SCO profile switch).
- R16. **Music interruption** picker — в v1 два варианта: **None** (default, текущее поведение) или **Mute** (ducking через `AVAudioSession` во время recording-session). Pause **отложен** (требует private `MediaRemote` API).

**API section** *(visible only in BYOK mode)*

- R17. **Gemini API key management** — текущий ключ показывается masked (`AIzaSy••••••••`); кнопка Edit разворачивает поле для нового ключа. На Save новый ключ валидируется через существующий `GeminiClient.validateKey` (no-cost `GET /v1beta/models`) перед записью в Keychain.
- R18. **Token usage stats** отображаются в окнах Today / 7d / 30d / All, с breakdown по input / output / cached tokens. Cache hit rate (cached ÷ total input) виден производным.
- R19. **`StatsStore` расширяется** трекать input/output/cached tokens per-day. Существующие словесные / сессионные / durational метрики сохраняются (tolerant decoder для старых `stats.json` файлов). $-cost conversion **НЕ** делаем в v1.

**System section**

- R20. **Output language picker** — multi-language allowlist (юзер выбирает 1+ языков, на которых обычно говорит); auto-detect Gemini всегда ON. Список служит подсказкой модели, не force-выбором.
- R21. **Output language allowlist прибавляется к Gemini cache prefix** в той же манере, что `User instruction:` / `Category instruction:` — frozen в `ContextSnapshot` на session start, byte-stable across chunks (load-bearing per `NoType/Gemini/CLAUDE.md` invariant #3 — «cache-friendly part ordering»).
- R22. **Delete all transcripts** button — destructive action с confirm-dialog; очищает `history.json` (last-10 transcripts). **`StatsStore` aggregate НЕ трогается** (matches existing `deleteHistoryEntry` carve-out per `docs/solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`).
- R23. **Current version display + Check for updates button** — показывает `CFBundleShortVersionString`; кнопка триггерит `SPUUpdater.checkForUpdates()`.
- R24. **Per-version skip via pill X** — sidebar update-pill получает small X для dismiss. Dismiss персистится per-version: та же версия больше не показывает pill при следующих auto-check'ах, новые версии — показывают.
- R25. **Paste restore delay slider** экспонирует существующий 50–500 ms slider (default 150 ms, UserDefaults key `notype.pasteRestoreDelayMs`).

**Mode-aware visibility**

- R26. API-секция появляется/исчезает в sidebar в зависимости от user-mode (R3). В v1 user-mode всегда BYOK → API всегда видна. Архитектура user-mode флага должна поддержать будущий flip без переработки sidebar layout'а.

---

## Acceptance Examples

- AE1. **Covers R3, R26.** Given user is in BYOK mode (current v1 default), when they open Settings, then the API section appears in the sidebar alongside General / Shortcuts / Microphone & Audio / System.
- AE2. **Covers R12.** Given user selects «Hold+spacebar-to-lock» as recording mode, when they hold the recording hotkey and press spacebar, then recording locks (continues after they release the hotkey); tapping the hotkey again stops it.
- AE3. **Covers R13.** Given user attempts to assign the same key to Cancel as the current Recording hotkey, when they confirm the choice, then the picker rejects with a validation message and keeps the previous Cancel binding.
- AE4. **Covers R17.** Given user pastes an invalid Gemini key into the Edit field, when they click Save, then `GeminiClient.validateKey` rejects (401/403) and the new key is NOT written to Keychain (the previous key remains active).
- AE5. **Covers R20, R21.** Given user adds «Russian» to the Output language allowlist mid-app-lifecycle, when they start the next recording session, then the new allowlist becomes part of that session's Gemini cache prefix (placement TBD by ce-plan but in a frozen-at-session-start section like `User instruction:`) and remains byte-stable across that session's chunks.
- AE6. **Covers R24.** Given Sparkle finds update v0.2.0 and user clicks X on the pill, when the next daily auto-check runs and still finds v0.2.0 as latest, then no pill re-appears. Given Sparkle later finds v0.2.1, when the next auto-check runs, then a pill appears for v0.2.1.
- AE7. **Covers R22.** Given user clicks Delete all transcripts and confirms, when the action completes, then `history.json` is emptied (last-10 transcripts gone) but `stats.json` (aggregate words/sessions/duration/tokens) remains intact.
- AE8. **Covers R16.** Given user selects Music interruption = Mute and music is playing in Apple Music, when they press the recording hotkey, then music ducks via `AVAudioSession`; when they release the hotkey, music returns to full volume.
- AE9. **Covers R10.** Given user clicks Reset onboarding and goes through the wizard, when they reach the API-key step, then the existing key from Keychain is pre-filled (not blank) and the wizard treats it as «already valid».

---

## Success Criteria

- BYOK-юзер может ротировать Gemini-ключ без переустановки приложения или ручного редактирования Keychain.
- BYOK-юзер видит свой расход токенов за выбранный период (Today / 7d / 30d / All) и cache hit rate (отношение cached к total input).
- Долгая диктовка (>5 минут непрерывно) не прерывается system-sleep'ом, когда включён Prevent sleep toggle.
- Запуск NoType при логине работает out-of-the-box после включения toggle'а — без ручных шагов через System Settings.
- Music interruption при Mute-режиме ducks музыку Apple Music / Spotify во время recording без необходимости юзеру вручную ставить на паузу.
- Settings-экран запоминается как «домашняя комната» приложения для всех конфигурационных решений — юзер не должен искать настройку по разным surface'ам (popover, onboarding, hidden defaults).
- ce-plan **не** должен изобретать:
  - где живёт Settings (4-й sidebar tab в main window)
  - какие секции есть и что в каждой (5 секций по матрице)
  - какие новые controls добавляются и какие existing мигрируют/дублируются
  - scope token-stats (windowed Today/7d/30d/All × input/output/cached, без $-cost, без per-app в v1)
  - семантику per-version skip (X на pill = неявный skip per-version)
  - семантику Reset onboarding (только wizard-state, не данные)

---

## Scope Boundaries

- **Silence remover** — Silero VAD уже отсекает silence на уровне chunking; отдельный slider избыточен. Не делаем.
- **Support non-standard keyboards** toggle — польза неясна (что Monologue под этим понимает — неизвестно). Не делаем.
- **Show dock icon** toggle — N/A: NoType всегда `LSUIElement=true`, dock-иконки не существует архитектурно.
- **Show «monophone» panel** — Monologue-специфичный плавающий UI; у NoType нет аналога.
- **In-app Screen Recording / OCR toggle** — TCC уже это решает (granted → работает, revoked → не работает); внутри-аппшный off-switch без revoking TCC остаётся в `docs/TECHDEBT.md` как открытая задача, **не блокирует v1 Settings-работу**.
- **Music interruption «Pause»** — публичного API нет (требует private `MediaRemote`); добавим, если/когда станет доступно.
- **SaaS/login mode UI** (Profile/Plan-секция вместо API) — режим ещё не существует, только зарезервировано имя секции. Дизайн будет отдельным брейнштормом, когда SaaS-tier появится в роадмапе.
- **$-cost conversion для token-stats** — нет в v1 (требует поддержки актуального прайсинга Gemini); добавим при первом запросе.
- **Per-app token breakdown** — в v1 только aggregate; `StatsStore` уже трекает per-app для слов/сессий, можно расширить позже.
- **Localization новых UI-строк** — английский в v1 (consistent с CLAUDE.md «Open questions: English-only in v1; Russian as fast follow»).
- **«Skip this version» как явный UI-control** — реализуется неявно через X на pill (R24); отдельной кнопки нет.
- **Migration старой `SettingsView` sheet** — sheet удаляется целиком; popover gear редиректит на новый Settings-tab. Coexistence «две sheet'ы + одно окно» не делаем.
- **Dictionary master toggle** — остаётся в Dictionary-табе (как сейчас); НЕ дублируется в Settings (явное решение юзера).

---

## Key Decisions

- **4-й sidebar tab в main window, не отдельное ⌘, окно**: единый main window переиспользует sidebar / DesignTokens / Onboarding-wizard. Современный паттерн (Linear, Notion, Slack) и согласуется с существующим main-window UI.
- **5 секций, не 7**: Data / About / Advanced слиты в одну «System». Меньше пустых экранов в sidebar'е, плотнее каждый экран.
- **Имя секции «API», а не «Account»**: выбрано юзером с явным условием — «секция будет только у пользователей, которые выбрали manual установку». Для login-юзеров секция скрывается целиком, а не переименовывается.
- **Output language как hint, не force**: auto-detect Gemini всегда ON, user picker = allowlist для подсказки. Не ломается на билингвах, не требует юзера думать про точный язык.
- **Mic picker и Hotkey дублируются** между Settings и popover/onboarding: онбординг трудно переоткрыть, popover footer быстрый для смены mic'а. Дублирование принимается осознанно как acceptable UX cost.
- **Reset onboarding сбрасывает только wizard-state**: НЕ удаляет API-ключ / hotkey / mic-выбор / dictionary — wizard должен быть «проверка пройденного», а не «потеря данных».
- **Per-version skip через X на pill, не отдельный Skip UI**: X = «закрыть pill сейчас» одновременно = «не показывай эту версию больше». Чище визуально, нет двух кнопок с пересекающимся смыслом.
- **Token stats: windowed без $-cost в v1**: трендовая видимость без burden'а с актуальностью прайсинга Gemini. Cache hit rate всё равно виден (прямая экономия от prompt-cache).
- **Music interruption: None / Mute в v1, Pause отложен**: Pause требует private `MediaRemote` API; v1 ограничивается публично-доступным `AVAudioSession` ducking.
- **Theme picker экспонирует существующий `AppearanceController`**: уже работает (Light/Dark/System), не пишется заново.
- **Старая `SettingsView` sheet удаляется целиком**: popover gear редиректит на Settings-tab в main window. Без сосуществования.

---

## Dependencies / Assumptions

- **Sparkle 2 SPM** уже подключён (`NoType/Updates/`); R23/R24 опираются на существующий `UpdateController` + `SPUUserDriver`. Per-version skip реализуется поверх Sparkle's seen-version механики или собственным UserDefaults flag — выбор за ce-plan после проверки Sparkle docs (см. Outstanding Questions).
- **Gemini `usageMetadata`** уже парсится (`GeminiAPI.UsageMetadata` в `NoType/Gemini/Models.swift`); R18/R19 опираются на это и расширяют `StatsStore` schema.
- **`AppearanceController`** уже существует (per `docs/architecture/overview.md` threading model); R6 экспонирует, не реализует.
- **`SMAppService` API** для Open on login требует macOS 13+. Наш deployment target — macOS 15 (ADR-001), совместим.
- **`IOPMAssertion` API** для Prevent sleep — публичный, без TCC-prompt'ов.
- **`AVAudioSession` ducking** для Music interruption Mute — публичный, без TCC.
- **`GeminiClient.validateKey`** уже существует для onboarding API-key step; R17 переиспользует.
- **Cache-prefix invariant** (`NoType/Gemini/CLAUDE.md` invariant #3: «byte-stable across chunks of one session») — R21 ОБЯЗАН следовать: Output language section добавляется в `ContextSnapshot`, frozen at session start, byte-stable. Это load-bearing для cost economics через implicit prompt caching.
- **Existing scattered controls** (BT-toggle, paste delay, hotkey, mic picker) — настройки уже существуют в коде; задача — surface их в новый UI, не строить заново.

---

## Outstanding Questions

### Resolve Before Planning

(пусто — все продуктовые решения зафиксированы в Key Decisions / Scope Boundaries)

### Deferred to Planning

- [Affects R2][Technical] **UI-форма sub-навигации внутри Settings-tab'а** — внутренний sidebar (как macOS System Settings), верхние tabs, или scrolled-with-headers? Зависит от существующих `DSComponents` и общей плотности.
- [Affects R17, R18][Technical] **Visual shape API-секции** — masked-key + Edit-modal vs inline-edit; inline-validation feedback; selector для windowed token-stats (segmented control vs dropdown). Дизайн-решения для ce-plan / ce-frontend-design.
- [Affects R16][Technical] **Реализация Mute-варианта Music interruption** — `AVAudioSession.setCategory(.playAndRecord, options: .duckOthers)` или альтернатива (`MTAudioProcessingTap`). Проверить в ce-plan, что ducking работает с Apple Music + Spotify без regressions в VAD.
- [Affects R12, R14][Technical] **Hold+spacebar mode при не-modifier hotkey** — edge case: юзер выбрал клавишу `S` как recording hotkey, включил Hold+Space mode → spacebar во время удержания `S` интерпретируется как lock-action или как печать пробела в фоне? Возможный constraint: Hold+Space-mode разрешён только для modifier-class hotkeys (Right Option / Right Cmd / Right Shift / Fn). Решить в ce-plan.
- [Affects R19][Technical] **`StatsStore` schema migration** — переход v3 → v4 с добавлением token-fields. Tolerant decoder pattern уже применяется (per `NoType/History/CLAUDE.md` «Hard rules»); миграция через `healIfPreV4` callback.
- [Affects R24][Needs research] **Что Sparkle 2 предлагает out-of-box для per-version dismiss** — есть ли `setSkippedVersion:` API или нужен собственный UserDefaults flag поверх `SUFeedURL`? Проверить Sparkle 2 docs в ce-plan перед имплементацией.
- [Affects R10][User decision] **Должен ли Reset onboarding явно предупреждать** «это откроет wizard заново, твой API-ключ сохранится»? Confirm dialog или straight execute? Решить в ce-plan.
- [Affects R22][User decision] **Confirm-dialog shape для Delete all transcripts** — простой Yes/No, или явный «Type DELETE to confirm»? History `remove(id:)` сейчас не запрашивает confirm на per-row trash — массовое deletion возможно заслуживает barrier-grade confirm. Решить в ce-plan.
- [Affects R3, R26][Technical] **Где жить user-mode флагу (BYOK vs SaaS)** — UserDefaults? Отдельный enum? В Keychain? Сейчас всё BYOK, флаг тривиален, но архитектура должна аккомодировать будущий flip. Решить в ce-plan.
- [Affects R20][User decision] **Объём списка языков** в picker'е — все Gemini-supported (~100) или curated (top-20 по популярности)? Resolve в ce-plan вместе с UI-формой picker'а.
