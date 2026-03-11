// RUN: %target-typecheck-verify-swift -enable-experimental-feature NonDiscardableTypes

// REQUIRES: swift_feature_NonDiscardableTypes

// Basic tests for ~Discardable type declarations and protocol rules.

// ============================================================================
// MARK: - Valid declarations
// ============================================================================

// ~Discardable implies ~Copyable (because Copyable: Discardable).
// Just ~Discardable is sufficient.
struct TaskToken: ~Discardable {
  consuming func complete() {}
}

// Explicit ~Copyable is redundant but valid.
struct TaskToken2: ~Copyable, ~Discardable {
  consuming func complete() {}
}

// Order shouldn't matter.
struct TaskToken3: ~Discardable, ~Copyable {
  consuming func complete() {}
}

// Enums can be ~Discardable too.
enum Obligation: ~Discardable {
  case pending(Int)
  case resolved

  consuming func fulfill() {
    self = .resolved // consume self
  }
}

// ============================================================================
// MARK: - Protocol basics
// ============================================================================

// Discardable is a marker protocol, so it should not be extendable.
extension Discardable { // expected-error {{cannot extend protocol 'Discardable'}}
  func hello() {}
}

// Can use Discardable in type constraints.
func whatever<T>(_ t: T) where T: Discardable {}
func vatever<T: Discardable>(_ t: T) {}
func buttever(_ t: any Discardable) {}
func zuttever(_ t: some Discardable) {}

// Can use Discardable as a typealias.
typealias PleaseLetMeDoIt = Discardable
typealias WhatIfIQualify = Swift.Discardable

// ============================================================================
// MARK: - Invalid: both Discardable and ~Discardable
// ============================================================================

struct Contradiction: Discardable, ~Discardable {}
// expected-error@-1 {{struct 'Contradiction' required to be 'Discardable' but is marked with '~Discardable'}}

// ============================================================================
// MARK: - ~Discardable types can have consuming methods
// ============================================================================

struct FileHandle: ~Discardable {
  let fd: Int32

  consuming func close() {
    // consume self by doing cleanup
    _ = fd
  }

  consuming func closeWithError() throws {
    _ = fd
  }
}

// ============================================================================
// MARK: - ~Discardable types CANNOT have deinit
// ============================================================================

struct GuardedResource: ~Discardable {
  var value: Int

  consuming func release() {
    _ = value
  }

  deinit {} // expected-error {{non-discardable type 'GuardedResource' cannot have a deinit}}
}

// ============================================================================
// MARK: - Generic ~Discardable types
// ============================================================================

struct Wrapper<T: ~Copyable & ~Discardable>: ~Copyable, ~Discardable {
  var inner: T

  consuming func unwrap() -> T {
    return inner
  }
}

// Conditional conformance to Discardable and Copyable.
extension Wrapper: Discardable where T: Discardable {}
extension Wrapper: Copyable where T: Copyable {}

// ============================================================================
// MARK: - Classes can store ~Discardable properties
// ============================================================================

class ResourceManager {
  var token: TaskToken? // Classes can store ~Discardable values

  deinit {
    // expected-error {{non-discardable stored property 'token' must be explicitly consumed before deinit finishes}}
    // The developer must explicitly consume `token` here.
  }
}

class GoodResourceManager {
  var token: TaskToken?

  deinit {
    if let t = consume token {
      t.complete()
    }
    // OK: token is consumed on all paths.
  }
}

// ============================================================================
// MARK: - Actors can store ~Discardable properties
// ============================================================================

actor WorkerActor {
  var obligation: Obligation?

  deinit {
    // expected-error {{non-discardable stored property 'obligation' must be explicitly consumed before deinit finishes}}
  }
}
