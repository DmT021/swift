// RUN: %target-swift-frontend -emit-sil -verify %s -enable-experimental-feature NonDiscardableTypes -enable-experimental-feature MoveOnlyEnumDeinits

// REQUIRES: swift_feature_NonDiscardableTypes
// REQUIRES: swift_feature_MoveOnlyEnumDeinits

// Tests for ~Discardable types: consuming methods don't need `discard self`.
//
// `~Discardable` types cannot have a deinit, so `discard self` is redundant —
// the consuming method body itself is the consumption. The compiler will still
// accept `discard self` in ~Discardable types (it's allowed but not required).
//
// Sema-level tests (deinit ban on ~Discardable types) are in
// test/Sema/nondiscardable_smoke.swift.

//////////////////
// Declarations //
//////////////////

public struct TaskToken: ~Discardable {
  var id: Int
  public init(id: Int) { self.id = id }
  public consuming func complete() {} // No discard self needed
}

// ============================================================================
// MARK: - OK: ~Discardable type with trivial fields — consuming method
// ============================================================================

struct TrivialLinearValue: ~Discardable {
  var x: Int

  init(x: Int) { self.x = x }

  consuming func finish() {
    // OK: consuming method consumes self — no discard self needed.
  }
}

// ============================================================================
// MARK: - OK: ~Discardable type with multiple trivial fields
// ============================================================================

struct TrivialPair: ~Discardable {
  var a: Int
  var b: Bool

  init(a: Int, b: Bool) { self.a = a; self.b = b }

  consuming func done() {
    // OK: consuming method — no discard self needed.
  }
}

// ============================================================================
// MARK: - OK: ~Copyable type with ~Discardable stored property consumed in deinit
// ============================================================================

struct GoodFileHandle: ~Copyable {
  var fd: Int32
  var token: TaskToken

  init(fd: Int32, token: consuming TaskToken) {
    self.fd = fd
    self.token = token
  }

  deinit {
    token.complete()
  }
}

// ============================================================================
// MARK: - Error: ~Copyable type with ~Discardable stored property NOT consumed in deinit
// ============================================================================

struct BadFileHandle: ~Copyable {
  var fd: Int32
  var token: TaskToken

  init(fd: Int32, token: consuming TaskToken) {
    self.fd = fd
    self.token = token
  }

  deinit {
  } // expected-error {{non-discardable stored property 'token' must be consumed before deinit exits}}
}

// ============================================================================
// MARK: - Error: ~Discardable parameter not consumed
// ============================================================================

func externalConsume(_ t: consuming TaskToken) {} // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}

// ============================================================================
// MARK: - Error: ~Discardable local not consumed
// ============================================================================

func localNotConsumed() {
  let t = TaskToken(id: 1) // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}
  _ = t.id
}
