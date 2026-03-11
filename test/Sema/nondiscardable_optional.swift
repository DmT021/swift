// RUN: %target-typecheck-verify-swift -enable-experimental-feature NonDiscardableTypes

// REQUIRES: swift_feature_NonDiscardableTypes

// Tests that ~Discardable is viral through Optional and Result.
// When a generic wrapper holds a ~Discardable type, the wrapper itself
// must conditionally become ~Discardable.

// ============================================================================
// MARK: - Helper types
// ============================================================================

// ~Discardable implies ~Copyable (Copyable refines Discardable).
struct TaskToken: ~Discardable {
  consuming func complete() {}
}

enum MyError: Error {
  case failed
}

// ============================================================================
// MARK: - Optional wrapping ~Discardable
// ============================================================================

func testOptionalNonDiscardable() {
  var token: TaskToken? = TaskToken()

  // ERROR: Cannot reassign 'token' to nil, because the previous value
  // would be implicitly discarded.
  token = nil // expected-error {{cannot implicitly discard a non-discardable value}}

  // OK: Destructuring transfers the obligation.
  switch consume token {
  case .some(let t):
    t.complete() // Explicitly consumed
  case .none:
    break // Safely discarded (no payload)
  }
}

func testOptionalConsumeAll() {
  var token: TaskToken? = TaskToken()

  // OK: Explicitly consume through if-let.
  if let t = consume token {
    t.complete()
  }
  // After this, token is .none — safely consumed.
}

func testOptionalReassignConsumed() {
  var token: TaskToken? = TaskToken()

  // OK: First consume old value, then reassign.
  if let t = consume token {
    t.complete()
  }
  token = TaskToken() // OK: previous value was consumed

  // Must consume the new value too.
  if let t = consume token {
    t.complete()
  }
}

// ============================================================================
// MARK: - Result wrapping ~Discardable
// ============================================================================

func testResultNonDiscardable() {
  let result: Result<TaskToken, MyError> = .success(TaskToken())

  // Must destructure and consume the success payload.
  switch consume result {
  case .success(let token):
    token.complete()
  case .failure(_):
    break // No obligation to consume the error.
  }
}

func testResultIgnored() {
  let result: Result<TaskToken, MyError> = .success(TaskToken())
  // expected-error@-1 {{'result' of non-discardable type 'Result<TaskToken, MyError>' must be explicitly consumed before end of scope}}
  _ = result // This doesn't actually consume; it's a no-op for ~Copyable.
}

// ============================================================================
// MARK: - Optional is Discardable when Wrapped is Discardable
// ============================================================================

func testOptionalOfDiscardable() {
  var x: Int? = 42
  x = nil // OK: Int is Discardable, so Optional<Int> is Discardable.
  _ = x
}

// ============================================================================
// MARK: - Nested Optional of ~Discardable
// ============================================================================

func testNestedOptional() {
  var token: TaskToken?? = .some(.some(TaskToken()))

  // Must destructure all the way down.
  switch consume token {
  case .some(.some(let t)):
    t.complete()
  case .some(.none):
    break
  case .none:
    break
  }
}

// ============================================================================
// MARK: - Conditional Discardable conformance
// ============================================================================

struct Box<T: ~Copyable & ~Discardable>: ~Discardable {
  var value: T
  consuming func take() -> T { return value }
}

extension Box: Discardable where T: Discardable {}
// Copyable implies Discardable, so no need for `& Discardable` here.
extension Box: Copyable where T: Copyable {}

func testBoxDiscardable() {
  let box = Box(value: 42)
  // Box<Int> is Discardable because Int is Discardable.
  // Implicit discard is fine.
  _ = box
}

func testBoxNonDiscardable() {
  let box = Box(value: TaskToken())
  // expected-error@-1 {{'box' of non-discardable type 'Box<TaskToken>' must be explicitly consumed before end of scope}}
}

func testBoxNonDiscardableConsumed() {
  let box = Box(value: TaskToken())
  let token = box.take()
  token.complete()
  // OK: box was consumed via take(), token was consumed via complete().
}
