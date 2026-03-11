// RUN: %target-typecheck-verify-swift -enable-experimental-feature NonDiscardableTypes

// REQUIRES: swift_feature_NonDiscardableTypes

// Tests that ~Discardable implies ~Copyable.
// Because Copyable refines Discardable in the standard library,
// writing ~Discardable automatically suppresses Copyable as well.
// Users do NOT need to write ~Copyable explicitly.

// ============================================================================
// MARK: - ~Discardable alone is sufficient (implies ~Copyable)
// ============================================================================

// This should compile — ~Discardable automatically removes Copyable
// through the Copyable: Discardable refinement.
struct ImpliedNonCopyable: ~Discardable {
  consuming func consume() {}
}

enum ImpliedNonCopyableEnum: ~Discardable {
  case value(Int)
  consuming func consume() {}
}

// ============================================================================
// MARK: - Explicit ~Copyable with ~Discardable is also fine (redundant but valid)
// ============================================================================

struct ExplicitBoth: ~Copyable, ~Discardable {
  consuming func consume() {}
}

enum ExplicitBothEnum: ~Copyable, ~Discardable {
  case value(Int)
  consuming func consume() {}
}

// ============================================================================
// MARK: - ~Discardable types cannot be copied (because they are ~Copyable)
// ============================================================================

func testCopyPrevented() {
  let a = ImpliedNonCopyable()
  let b = a // expected-error {{noncopyable type 'ImpliedNonCopyable' cannot be copied}}
  _ = b
  a.consume()
}

func testExplicitBothCopyPrevented() {
  let a = ExplicitBoth()
  let b = a // expected-error {{noncopyable type 'ExplicitBoth' cannot be copied}}
  _ = b
  a.consume()
}

// ============================================================================
// MARK: - Generic parameter: ~Discardable alone implies ~Copyable
// ============================================================================

// ~Discardable on a generic parameter also implies ~Copyable.
func acceptNonDiscardable<T: ~Discardable>(_ t: consuming T) {}

// Explicit both is also fine (redundant but valid).
func acceptExplicitBoth<T: ~Copyable & ~Discardable>(_ t: consuming T) {}

// Can call with a ~Discardable type.
func testGenericAccept() {
  let t = ImpliedNonCopyable()
  acceptNonDiscardable(t)
}

// ============================================================================
// MARK: - Protocol: ~Discardable on Self implies ~Copyable on Self
// ============================================================================

protocol LinearProto: ~Discardable {
  consuming func fulfill()
}

// Explicit both is also fine (redundant but valid).
protocol ExplicitLinearProto: ~Copyable, ~Discardable {
  consuming func fulfill()
}

// A conforming type can use just ~Discardable.
struct LinearImpl: LinearProto, ~Discardable {
  consuming func fulfill() {}
}

// ============================================================================
// MARK: - Associated type: ~Discardable alone is sufficient
// ============================================================================

protocol HasLinearAssoc: ~Copyable {
  associatedtype Token: ~Discardable
}

protocol HasExplicitLinearAssoc: ~Copyable {
  associatedtype Token: ~Copyable & ~Discardable
}

// ============================================================================
// MARK: - Where clause: ~Discardable implies ~Copyable
// ============================================================================

func whereClause<T>(_ t: consuming T) where T: ~Discardable {}
func whereClauseExplicit<T>(_ t: consuming T) where T: ~Copyable, T: ~Discardable {}

// ============================================================================
// MARK: - Contradiction: explicit Discardable + ~Discardable is an error
// ============================================================================

struct Contradiction: Discardable, ~Discardable {}
// expected-error@-1 {{struct 'Contradiction' required to be 'Discardable' but is marked with '~Discardable'}}
