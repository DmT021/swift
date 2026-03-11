// RUN: %target-swift-frontend -emit-sil -verify %s -enable-experimental-feature NonDiscardableTypes -enable-experimental-feature MoveOnlyEnumDeinits

// REQUIRES: swift_feature_NonDiscardableTypes
// REQUIRES: swift_feature_MoveOnlyEnumDeinits

// Tests for `discard self` interaction with ~Discardable types.
//
// These tests focus on SIL-level checking:
// - NonDiscardableChecker: unconsumed locals, unconsumed deinit properties
// - discard self with DropDeinitInst skip
//
// Sema-level tests (deinit ban on ~Discardable types) are in
// test/Sema/nondiscardable_smoke.swift.

//////////////////
// Declarations //
//////////////////

public struct TaskToken: ~Discardable {
  var id: Int
  public init(id: Int) { self.id = id }
  public consuming func complete() { discard self }
}

// ============================================================================
// MARK: - OK: ~Discardable type with trivial fields using discard self
// ============================================================================

struct TrivialLinearValue: ~Discardable {
  var x: Int

  init(x: Int) { self.x = x }

  consuming func finish() {
    discard self // OK: all fields are trivial, self is consumed via discard.
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
    discard self // OK: all fields trivial.
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
