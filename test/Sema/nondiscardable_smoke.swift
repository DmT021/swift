// RUN: %target-typecheck-verify-swift -enable-experimental-feature NonDiscardableTypes

// REQUIRES: swift_feature_NonDiscardableTypes

// Smoke test: verify that ~Discardable parses and type-checks.

// ~Discardable alone implies ~Copyable (Copyable refines Discardable).
struct Token: ~Discardable {
  consuming func complete() {}
}

// Explicit both (redundant but valid).
struct Token2: ~Copyable, ~Discardable {
  consuming func complete() {}
}

// Enums too.
enum Action: ~Discardable {
  case pending
  consuming func finish() {}
}

// Generic with ~Discardable constraint.
struct Box<T: ~Copyable & ~Discardable>: ~Discardable {
  var inner: T
  consuming func take() -> T { return inner }
}

// Conditional conformance — must be explicit about all invertible protocols.
extension Box: Discardable where T: Discardable & ~Copyable {}
extension Box: Copyable where T: Copyable {}

func takeCopyable(_: some Copyable) {} // expected-note {{'some Copyable & Copyable' is implicit here}}

// Verify that Token is not Copyable.
func testNonCopyable() {
  let a = Token()
  takeCopyable(a) // expected-error {{global function 'takeCopyable' requires that 'Token' conform to 'Copyable'}}
  let b = copy a // expected-error {{'copy' cannot be applied to noncopyable types}}
  _ = b
}

struct ObserverTest: ~Copyable {
  var token: Token { // expected-error {{non-discardable property 'token' cannot have 'willSet' or 'didSet' observers}}
    willSet { _ = newValue }
    didSet { _ = oldValue }
  }
}
