// RUN: %target-swift-emit-sil %s -sil-verify-all -verify -enable-experimental-feature NonDiscardableTypes

// REQUIRES: swift_feature_NonDiscardableTypes

// Tests for deinit interaction with ~Discardable.
//
// Key rules:
// 1. A ~Discardable type CANNOT have a deinit. Deinit IS the discard path,
//    which contradicts the type's contract.
// 2. A ~Copyable type that stores ~Discardable properties and IS NOT itself
//    ~Discardable must provide a deinit that explicitly consumes those properties.
// 3. A class that stores ~Discardable properties must consume them in its deinit.

//////////////////
// Declarations //
//////////////////

public struct TaskToken: ~Discardable {
  var id: Int
  public consuming func complete() { _ = id }
}

public struct Obligation: ~Discardable {
  var description: Int
  public consuming func fulfill() { _ = description }
}

// ============================================================================
// MARK: - Error: ~Discardable type cannot have deinit
// ============================================================================

struct BadLinear: ~Discardable {
  var id: Int

  consuming func finish() { _ = id }

  deinit {} // expected-error {{non-discardable type 'BadLinear' cannot have a deinit}}
}

// ============================================================================
// MARK: - Error: ~Discardable enum cannot have deinit
// ============================================================================

enum BadLinearEnum: ~Discardable {
  case value(Int)

  consuming func resolve() {}

  deinit {} // expected-error {{non-discardable type 'BadLinearEnum' cannot have a deinit}}
}

// ============================================================================
// MARK: - OK: ~Copyable (but Discardable) type wrapping ~Discardable, with deinit that consumes
// ============================================================================

struct ResourceHolder: ~Copyable {
  var token: TaskToken

  deinit {
    token.complete() // OK: explicitly consumes the ~Discardable stored property.
  }
}

// ============================================================================
// MARK: - Error: ~Copyable type wrapping ~Discardable, deinit does NOT consume
// ============================================================================

struct BadResourceHolder: ~Copyable {
  var token: TaskToken

  deinit {
    // expected-error @-1 {{non-discardable stored property 'token' must be explicitly consumed in deinit}}
    print("going away")
    // Bug: token is implicitly destroyed here — violates ~Discardable contract.
  }
}

// ============================================================================
// MARK: - Error: ~Copyable type wrapping ~Discardable, deinit consumes on only one path
// ============================================================================

struct ConditionalHolder: ~Copyable {
  var token: TaskToken
  var shouldComplete: Bool

  deinit {
    // expected-error @-1 {{non-discardable stored property 'token' must be explicitly consumed on all paths in deinit}}
    if shouldComplete {
      token.complete()
    }
    // else: token implicitly destroyed — error.
  }
}

// ============================================================================
// MARK: - OK: ~Copyable type wrapping ~Discardable, deinit consumes on all paths
// ============================================================================

struct AllPathsHolder: ~Copyable {
  var token: TaskToken
  var shouldComplete: Bool

  deinit {
    if shouldComplete {
      token.complete()
    } else {
      // Must call a consuming function — cannot just `consume` into nothing.
      token.complete()
    }
  }
}

// ============================================================================
// MARK: - Error: multiple ~Discardable properties, not all consumed in deinit
// ============================================================================

struct MultiPropHolder: ~Copyable {
  var token: TaskToken
  var obligation: Obligation

  deinit {
    // expected-error @-1 {{non-discardable stored property 'obligation' must be explicitly consumed in deinit}}
    token.complete() // OK for token
    // obligation not consumed!
  }
}

// ============================================================================
// MARK: - OK: multiple ~Discardable properties, all consumed in deinit
// ============================================================================

struct GoodMultiPropHolder: ~Copyable {
  var token: TaskToken
  var obligation: Obligation

  deinit {
    token.complete()
    obligation.fulfill()
  }
}

// ============================================================================
// MARK: - Error: ~Copyable type without deinit holding ~Discardable property
// ============================================================================

struct NoDeinit: ~Copyable {
  var token: TaskToken
  // expected-error @-1 {{stored property 'token' of type 'TaskToken' is non-discardable; struct 'NoDeinit' must either be '~Discardable' or provide a 'deinit' that explicitly consumes 'token'}}
}

// ============================================================================
// MARK: - OK: ~Copyable & ~Discardable type without deinit holding ~Discardable property
// ============================================================================

// This is fine because the obligation propagates: whoever holds a TwoTokens
// must consume it, which means calling a consuming method on it.
struct TwoTokens: ~Discardable {
  var a: TaskToken
  var b: TaskToken

  consuming func finishBoth() {
    a.complete()
    b.complete()
  }
}

// ============================================================================
// MARK: - Class with ~Discardable stored property: deinit must consume
// ============================================================================

class ClassWithToken {
  var token: TaskToken?

  deinit {
    // expected-error @-1 {{non-discardable stored property 'token' must be explicitly consumed in deinit}}
    // Classes always have deinits. ~Discardable properties must be consumed.
  }
}

class GoodClassWithToken {
  var token: TaskToken?

  deinit {
    if var t = consume token {
      t.complete()
    }
    // OK: token consumed on all paths (including nil case — nil is Discardable).
  }
}
