// RUN: %target-swift-emit-sil %s -sil-verify-all -verify -enable-experimental-feature NonDiscardableTypes

// REQUIRES: swift_feature_NonDiscardableTypes

// Tests for the mandatory NonDiscardableChecker pass.
// This pass enforces that every ~Discardable value must be explicitly consumed.
// Implicit destroys (end-of-scope drops) are errors.

//////////////////
// Declarations //
//////////////////

public struct TaskToken: ~Discardable {
  var id: Int

  public consuming func complete() {
    _ = id
  }
}

public struct Obligation: ~Discardable {
  var description: Int

  public consuming func fulfill() {
    _ = description
  }
}

public func makeToken() -> TaskToken {
  return TaskToken(id: 1)
}

public func makeObligation() -> Obligation {
  return Obligation(description: 42)
}

// ============================================================================
// MARK: - Error: let binding never consumed
// ============================================================================

func testLetNotConsumed() {
  let token = makeToken()
  // expected-error @-1 {{non-discardable value 'token' must be consumed before it goes out of scope}}
  _ = token.id // borrowing use, not a consume
}

// ============================================================================
// MARK: - Error: var binding never consumed
// ============================================================================

func testVarNotConsumed() {
  var token = makeToken()
  // expected-error @-1 {{non-discardable value 'token' must be consumed before it goes out of scope}}
  // expected-error @-2 {{non-discardable value 'token' must be consumed before it goes out of scope}}
  token = makeToken()
  // Reassigning a var implicitly destroys the old value.
  _ = token.id
}

// ============================================================================
// MARK: - OK: let binding consumed by consuming method
// ============================================================================

func testLetConsumedByMethod() {
  let token = makeToken()
  token.complete() // OK: consumes the value.
}

// ============================================================================
// MARK: - Error: consume operator without passing to a consuming function is still discarding
// ============================================================================

func testConsumeOperatorAloneIsDiscard() {
  let token = makeToken()
  let _ = consume token // expected-error {{non-discardable value '<anonymous>' must be consumed before it goes out of scope}}
  // `consume` moves the value out, but `let _ =` discards it.
}

// ============================================================================
// MARK: - OK: consuming function parameter consumed
// ============================================================================

func testConsumingParam(_ token: consuming TaskToken) {
  token.complete() // OK
}

// ============================================================================
// MARK: - Error: consuming function parameter not consumed
// ============================================================================

func testConsumingParamNotConsumed(_ token: consuming TaskToken) {
  // expected-error @-1 {{non-discardable value 'token' must be consumed before it goes out of scope}}
  _ = token.id
}

// ============================================================================
// MARK: - OK: return transfers obligation to caller
// ============================================================================

func testReturn() -> TaskToken {
  let token = makeToken()
  return token // OK: obligation transferred to caller.
}

// ============================================================================
// MARK: - OK: passing to another consuming function
// ============================================================================

func consumeToken(_ token: consuming TaskToken) {
  token.complete()
}

func testPassToConsuming() {
  let token = makeToken()
  consumeToken(token) // OK: obligation transferred.
}

// ============================================================================
// MARK: - Error: consumed on one path, not on another
// ============================================================================

func testConditionalConsume(_ condition: Bool) {
  let token = makeToken()
  // expected-error @-1 {{non-discardable value 'token' must be consumed before it goes out of scope}}
  if condition {
    token.complete()
  }
  // else: token is implicitly destroyed — error.
}

// ============================================================================
// MARK: - OK: consumed on all paths
// ============================================================================

func testAllPathsConsumed(_ condition: Bool) {
  let token = makeToken()
  if condition {
    token.complete()
  } else {
    consumeToken(token)
  }
  // OK: consumed on both branches.
}

// ============================================================================
// MARK: - Error: consumed in loop body but loop might not execute
// ============================================================================

func testLoopNotGuaranteed(_ items: [Int]) {
  let token = makeToken()
  // expected-error @-1 {{non-discardable value 'token' must be consumed before it goes out of scope}}
  for item in items {
    if item > 0 {
      token.complete()
      return
    }
  }
  // If items is empty, token falls through — error.
}

// ============================================================================
// MARK: - Error: function parameter borrowing (cannot consume)
// ============================================================================

func testBorrowingParam(_ token: borrowing TaskToken) {
  // A borrowing parameter cannot be consumed, so this is fine —
  // the obligation remains with the caller. No error here.
  _ = token.id
}

// ============================================================================
// MARK: - Error: stored in local that is then not consumed
// ============================================================================

func testStoredInLocal() {
  let token = makeToken()
  let local = consume token // move token into local
  // expected-error @-1 {{non-discardable value 'local' must be consumed before it goes out of scope}}
  _ = local.id
}

// ============================================================================
// MARK: - OK: stored in local that IS consumed
// ============================================================================

func testStoredInLocalConsumed() {
  let token = makeToken()
  let local = consume token // move token into local
  local.complete() // OK: local consumed.
}

// ============================================================================
// MARK: - Error: multiple values, one not consumed
// ============================================================================

func testMultipleValues() {
  let a = makeToken()
  let b = makeObligation()
  // expected-error @-1 {{non-discardable value 'b' must be consumed before it goes out of scope}}

  a.complete() // a is consumed
  _ = b.description // b is only borrowed, not consumed
}

// ============================================================================
// MARK: - OK: multiple values, all consumed
// ============================================================================

func testMultipleValuesAllConsumed() {
  let a = makeToken()
  let b = makeObligation()
  a.complete()
  b.fulfill()
}

// ============================================================================
// MARK: - Error: switch without consuming on all cases
// ============================================================================

enum Choice: ~Copyable {
  case left
  case right
}

func testSwitchNotAllPaths(_ c: consuming Choice) {
  let token = makeToken()
  // expected-error @-1 {{non-discardable value 'token' must be consumed before it goes out of scope}}
  switch consume c {
  case .left:
    token.complete()
  case .right:
    break // token not consumed!
  }
}

// ============================================================================
// MARK: - OK: switch consuming on all cases
// ============================================================================

func testSwitchAllPaths(_ c: consuming Choice) {
  let token = makeToken()
  switch consume c {
  case .left:
    token.complete()
  case .right:
    consumeToken(token)
  }
}

// ============================================================================
// MARK: - Error: closure captures ~Discardable value but doesn't consume it
// ============================================================================

func testClosureCapture() {
  let token = makeToken()
  // expected-error @-1 {{non-discardable value 'token' must be consumed before it goes out of scope}}
  let closure = {
    _ = token.id // borrowing capture
  }
  closure()
}

// ============================================================================
// MARK: - Enum with ~Discardable associated values
// ============================================================================

enum TokenOrError: ~Discardable {
  case token(TaskToken)
  case error(Int)
}

func testEnumConsumedBySwitch() {
  let value: TokenOrError = .token(makeToken())
  switch consume value {
  case .token(let t):
    t.complete()
  case .error(_):
    break // Int is Discardable, no issue.
  }
}

func testEnumNotConsumed() {
  let value: TokenOrError = .token(makeToken()) // expected-warning {{immutable value 'value' was never used; consider replacing with '_' or removing it}}
  // expected-error @-1 {{non-discardable value 'value' must be consumed before it goes out of scope}}
}
