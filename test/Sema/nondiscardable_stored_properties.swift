// RUN: %target-typecheck-verify-swift -enable-experimental-feature NonDiscardableTypes

// REQUIRES: swift_feature_NonDiscardableTypes

// Tests containment rules for ~Discardable stored properties.
// A ~Discardable stored property may only appear inside:
// 1. ~Copyable structs and enums
// 2. class types
// 3. actor types
//
// A Copyable struct storing a ~Discardable property is an error.

// ============================================================================
// MARK: - Helper types
// ============================================================================

// ~Discardable implies ~Copyable (Copyable refines Discardable).
struct TaskToken: ~Discardable {
  consuming func complete() {}
}

struct Obligation: ~Discardable {
  var id: Int
  consuming func fulfill() { _ = id }
}

// ============================================================================
// MARK: - Error: Copyable struct storing ~Discardable property
// ============================================================================

struct CopyableContainer { // expected-note {{consider adding '~Copyable' to struct 'CopyableContainer'}}
  var token: TaskToken
  // expected-error@-1 {{stored property 'token' of 'Discardable'-conforming struct 'CopyableContainer' has non-Discardable type 'TaskToken'}}
}

// ============================================================================
// MARK: - Error: Copyable enum with ~Discardable associated value
// ============================================================================

enum CopyableEnum { // expected-note {{consider adding '~Copyable' to enum 'CopyableEnum'}}
  case idle
  case working(TaskToken)
  // expected-error@-1 {{associated value 'working' of 'Discardable'-conforming enum 'CopyableEnum' has non-Discardable type 'TaskToken'}}
}

// ============================================================================
// MARK: - OK: ~Copyable struct storing ~Discardable property
// ============================================================================

struct NoncopyableContainer: ~Copyable {
  var token: TaskToken
  // Note: this struct is NOT ~Discardable itself. When it is destroyed,
  // `token` would be implicitly destroyed — which may or may not be fine
  // depending on whether NoncopyableContainer adds ~Discardable too.

  consuming func finish() {
    token.complete()
  }
}

// ============================================================================
// MARK: - OK: ~Discardable struct storing ~Discardable property
// ============================================================================

struct LinearContainer: ~Discardable {
  var token: TaskToken

  consuming func finish() {
    token.complete()
  }
}

// ============================================================================
// MARK: - OK: class storing ~Discardable property
// ============================================================================

class ClassContainer {
  var token: TaskToken?

  deinit {
    if let t = consume token {
      t.complete()
    }
  }
}

// ============================================================================
// MARK: - OK: actor storing ~Discardable property
// ============================================================================

actor ActorContainer {
  var obligation: Obligation?

  deinit {
    if let o = consume obligation {
      o.fulfill()
    }
  }
}

// ============================================================================
// MARK: - Error: Copyable generic struct with ~Discardable member
// ============================================================================

struct GenericBox<T> { // expected-note {{consider adding '~Copyable' to generic struct 'GenericBox'}}
  var value: T
}

func instantiateWithNonDiscardable() {
  let _ = GenericBox<TaskToken>(value: TaskToken())
  // expected-error@-1 {{type 'TaskToken' does not conform to protocol 'Copyable'}}
}

// ============================================================================
// MARK: - OK: Generic struct that suppresses both Copyable and Discardable
// ============================================================================

struct LinearBox<T: ~Copyable & ~Discardable>: ~Discardable {
  var value: T

  consuming func take() -> T {
    return value
  }
}

extension LinearBox: Discardable where T: Discardable {}
// Copyable implies Discardable, so no need for `& Discardable` here.
extension LinearBox: Copyable where T: Copyable {}

// ============================================================================
// MARK: - Multiple stored properties
// ============================================================================

struct MultiField: ~Discardable {
  var a: TaskToken
  var b: Obligation

  consuming func finishAll() {
    a.complete()
    b.fulfill()
  }
}

// ============================================================================
// MARK: - Nested noncopyable struct without ~Discardable containing ~Discardable
// ============================================================================

struct Outer: ~Copyable {
  // Note: Outer is ~Copyable but not ~Discardable.
  // It can hold a ~Discardable property because it's ~Copyable.
  // However, when Outer is destroyed, its `token` will be implicitly destroyed.
  // Whether the compiler flags this depends on whether we require Outer to also
  // be ~Discardable (virality). For the MVP, this is valid — the obligation
  // transfers to whoever holds the Outer.
  var token: TaskToken

  consuming func finish() {
    token.complete()
  }
}
