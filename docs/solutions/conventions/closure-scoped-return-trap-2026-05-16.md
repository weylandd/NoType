---
title: Closure-scoped `return` trap — `guard return` inside `withUnsafe*` only escapes the closure
date: 2026-05-16
category: conventions
module: cross-cutting
problem_type: convention
component: tooling
severity: high
applies_when:
  - Writing or reviewing code that uses `withUnsafeBufferPointer` / `withUnsafeBytes` / `withUnsafeMutablePointer` / `withContiguousStorageIfAvailable` / similar closure-takers
  - Hardening a force-unwrap into a `guard let … else { … }`
  - Reviewing PRs that move guard-style invariant checks into closures
tags: [swift, swift-6, closures, unsafe-pointer, force-unwrap, defensive-programming]
---

# Closure-scoped `return` trap — `guard return` inside `withUnsafe*` only escapes the closure

## Context

The standard pattern for replacing a force-unwrap with a defensive guard is:

```swift
guard let x = optional else { return }
```

When the optional is `UnsafeBufferPointer.baseAddress` (or any pointer property exposed inside a `withUnsafe…` closure), the natural translation is:

```swift
array.withUnsafeBufferPointer { src in
    guard let base = src.baseAddress else { return }
    // copy from `base`
}
// rest of function continues, expecting the copy to have happened
```

**The `return` only exits the closure, not the enclosing function.** Execution falls through past the `withUnsafe…` call with the post-closure state untouched: the target buffer was never written, but the function continues as if it had been.

In NoType this trap shipped twice in the same PR (force-unwrap hardening, PR #27):

- `SileroVAD.probability(for:)` — would have fed CoreML 4096 uninitialised float32s after the 64-sample carriedContext, producing a garbage speech probability that `PauseDetector` consumes as truth.
- `ChunkBuilder.encodeAAC(_:)` — would have set `buffer.frameLength = frames` against an unwritten PCM buffer; `file.write(from:)` would ship an m4a of silence to Gemini.

Both were unreachable in practice (upstream count guards), but the whole *point* of the inner guards was defence-in-depth against a future refactor that loosened the upstream guards. The bare `return` actively undermined that goal.

## Guidance

**Use `try` from inside the closure.** Most `withUnsafe…` methods are `rethrows`, so a `throw` inside the closure flows out as a thrown error from the enclosing function:

```swift
try array.withUnsafeBufferPointer { src in
    guard let base = src.baseAddress else {
        throw MyError.bufferUnavailable
    }
    // copy from `base`
}
// only reachable if the closure completed successfully
```

If the enclosing function can't throw, escalate to `precondition` / `preconditionFailure`. A nil `baseAddress` on a non-empty buffer is a programming-invariant violation, not a recoverable condition.

**Throw a dedicated error case**, not a synthetic value of an existing case. NoType's first attempt threw `VADError.inputShapeMismatch(expected: 4096, got: 0)` from this path — but `samples.count == 4096` was already guaranteed by the upstream guard, so `got: 0` was a lie. The replacement `VADError.inputBufferUnavailable` / `ChunkError.bufferUnavailable` names the actual invariant.

## Why This Matters

- **Silent corruption is worse than a crash.** A bare `return` from inside a `withUnsafe…` closure produces no log, no exception, no test failure — just downstream garbage. CoreML happily classifies uninitialised audio as speech; AVAudioFile happily writes a zero-frame m4a. The system continues, and the bug shows up as "transcripts are bad" three layers downstream.
- **Defence-in-depth must actually defend.** A guard that documents an invariant without enforcing it is decoration. If the upstream guard ever loosens, the inner one must convert the violation into a visible failure (throw or crash), not a silent miscompute.
- **Error case names should match the failure mode.** Reusing a shape-mismatch case for a buffer-pointer violation makes future log-triage harder. The whole point of surfacing the failure was so a future reader can tell *which* invariant tripped.

## When to Apply

- **Every `withUnsafeBufferPointer { … }` / `withUnsafeBytes { … }` / etc. with a `guard` inside the closure.** The trap is universal — it's a Swift language feature, not a NoType quirk.
- **Every force-unwrap → guard refactor that touches a closure boundary.** Make the throw-from-closure shape part of the same diff; don't leave the guard as a bare `return`.

## Examples

**Wrong** (shipped in PR #27, fixed in PR #34):

```swift
samples.withUnsafeBufferPointer { src in
    guard let base = src.baseAddress else { return }   // ⚠️ only escapes the closure
    audioPtr.advanced(by: contextSize).update(from: base, count: chunkSize)
}
// MLDictionaryFeatureProvider runs next with uninitialised tail
```

**Right** (PR #34):

```swift
try samples.withUnsafeBufferPointer { src in
    guard let base = src.baseAddress else {
        throw VADError.inputBufferUnavailable
    }
    audioPtr.advanced(by: contextSize).update(from: base, count: chunkSize)
}
// only reachable when `audio_input` is fully initialised
```

**Trade-off accepted:** the enclosing function's `throws` clause covers a path that's currently unreachable. Worth the extra surface — without it the defence is fake.

## Related

- `solutions/conventions/force-unwrap-error-and-logging-2026-05-15.md` — the broader convention this trap is a sub-case of (force-unwrap removal + error model).
- `NoType/Recording/SileroVAD.swift` `probability(for:)` — the canonical example after the fix.
- `NoType/Recording/ChunkBuilder.swift` `encodeAAC(_:)` — the second example.
- PR #34 — the fix that surfaced the pattern; lives in git history.
