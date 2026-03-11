// RUN: %target-swift-emit-sil %s -sil-verify-all -verify -enable-experimental-feature NonDiscardableTypes

// REQUIRES: swift_feature_NonDiscardableTypes

// Tests that Never-terminating paths satisfy ~Discardable requirements.
//
// If a function terminates by calling fatalError() or any other Never-returning
// function, the ~Discardable value does not need to be consumed on that path,
// because the program never continues past that point.

//////////////////
// Declarations //
//////////////////

public struct TaskToken: ~Discardable {
  var id: Int
  public consuming func complete() { _ = id }
}

public func makeToken() -> TaskToken {
  return TaskToken(id: 1)
}

// ============================================================================
// MARK: - OK: all non-Never paths consume, Never path does not
// ============================================================================

func testFatalErrorPath(_ condition: Bool) {
  let token = makeToken()
  if condition {
    token.complete()
  } else {
    fatalError("unreachable") // Never-returning — no need to consume token.
  }
}

// ============================================================================
// MARK: - OK: consume then fatalError on different paths
// ============================================================================

func testConsumeOrFatal(_ condition: Bool) {
  let token = makeToken()
  guard condition else {
    fatalError("precondition failed") // Never path — OK.
  }
  token.complete()
}

// ============================================================================
// MARK: - OK: preconditionFailure is Never
// ============================================================================

func testPreconditionFailure(_ condition: Bool) {
  let token = makeToken()
  if condition {
    token.complete()
  } else {
    preconditionFailure("should not happen")
  }
}

// ============================================================================
// MARK: - OK: custom Never-returning function
// ============================================================================

func die(_ message: String) -> Never {
  fatalError(message)
}

func testCustomNever(_ condition: Bool) {
  let token = makeToken()
  if condition {
    token.complete()
  } else {
    die("fatal")
  }
}

// ============================================================================
// MARK: - OK: entire function returns Never
// ============================================================================

func testEntireFunctionNever() -> Never {
  let _token = makeToken()
  // No need to consume token — function never returns.
  fatalError("this function never returns")
}

// ============================================================================
// MARK: - Error: fatalError only on one branch, other branch doesn't consume
// ============================================================================

func testNotAllPathsCovered(_ x: Int) {
  let token = makeToken()
  // expected-error @-1 {{non-discardable value 'token' must be explicitly consumed on all paths}}
  switch x {
  case 0:
    token.complete()
  case 1:
    fatalError("bad state") // Never — OK for this branch
  default:
    break // ERROR: token not consumed on this path!
  }
}

// ============================================================================
// MARK: - OK: all non-Never branches consume
// ============================================================================

func testAllBranchesCoveredOrNever(_ x: Int) {
  let token = makeToken()
  switch x {
  case 0:
    token.complete()
  case 1:
    fatalError("bad state") // Never — OK
  default:
    token.complete()
  }
}

// ============================================================================
// MARK: - OK: while true loop (never exits)
// ============================================================================

func testInfiniteLoop() {
  let _token = makeToken()
  // An infinite loop that never breaks means the scope never ends.
  // The value is never implicitly destroyed — this is OK.
  while true {
    // process forever
  }
}

// ============================================================================
// MARK: - Error: loop that CAN exit without consuming
// ============================================================================

func testLoopWithBreak(_ items: [Int]) {
  let token = makeToken()
  // expected-error @-1 {{non-discardable value 'token' must be explicitly consumed on all paths}}
  for item in items {
    if item < 0 {
      token.complete()
      return // consumed, then exits.
    }
  }
  // Falls through when items is empty or no negative item — token not consumed.
}

// ============================================================================
// MARK: - OK: loop that exits only via consume or Never
// ============================================================================

func testLoopConsumeOrFatal(_ items: [Int]) {
  let token = makeToken()
  for item in items {
    if item < 0 {
      token.complete()
      return
    }
  }
  // If we get here, token was not consumed in the loop.
  fatalError("expected at least one negative item") // Never — OK.
}

// ============================================================================
// MARK: - OK: throwing function — throw transfers obligation
// ============================================================================

enum TokenError: Error {
  case expired
}

func testThrowPath(_ condition: Bool) throws {
  let token = makeToken()
  if condition {
    token.complete()
  } else {
    // Throwing does NOT consume the token. The token would be implicitly
    // destroyed when unwinding — this IS a discard.
    throw TokenError.expired
    // expected-error @-1 {{implicit discard of non-discardable value 'token' by throwing}}
  }
}

func testThrowAfterConsume(_ condition: Bool) throws {
  let token = makeToken()
  token.complete()
  if !condition {
    throw TokenError.expired // OK: token already consumed before throw.
  }
}
