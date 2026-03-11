// RUN: %target-swift-frontend -Xllvm -sil-print-types -emit-silgen -enable-experimental-feature NonDiscardableTypes %s | %FileCheck %s
// RUN: %target-swift-frontend -Xllvm -sil-print-types -emit-sil -enable-experimental-feature NonDiscardableTypes %s -verify

// REQUIRES: swift_feature_NonDiscardableTypes

// This test validates:
// 1. SILGen emits mark_unresolved_non_copyable_value [must_consume] for ~Discardable bindings.
// 2. After the mandatory pass pipeline, these are lowered away.

// ============================================================================
// MARK: - Declarations
// ============================================================================

struct TaskToken: ~Discardable {
  var id: Int

  consuming func complete() {
    _ = id // consume self
  }
}

// ============================================================================
// MARK: - Test: local let binding of ~Discardable type
// ============================================================================

// CHECK-LABEL: sil hidden [ossa] @$s14nondiscardable13testLocalBindyyF : $@convention(thin) () -> () {
// CHECK:   [[TOKEN:%.*]] = struct $TaskToken
// CHECK:   [[MARKED:%.*]] = mark_unresolved_non_copyable_value [consumable_and_assignable] [[TOKEN]]
// The non-discardable checker should additionally mark this as must-consume,
// or the mark should carry that information from the start.
// CHECK: } // end sil function '$s14nondiscardable13testLocalBindyyF'
func testLocalBind() {
  let token = TaskToken(id: 1)
  token.complete()
}

// ============================================================================
// MARK: - Test: consuming function parameter
// ============================================================================

// CHECK-LABEL: sil hidden [ossa] @$s14nondiscardable12testConsumingyyAA9TaskTokenVnF : $@convention(thin) (@owned TaskToken) -> () {
// CHECK: bb0([[ARG:%.*]] : @owned $TaskToken):
// CHECK:   [[MARKED:%.*]] = mark_unresolved_non_copyable_value [consumable_and_assignable] [[ARG]]
// CHECK: } // end sil function '$s14nondiscardable12testConsumingyyAA9TaskTokenVnF'
func testConsuming(_ token: consuming TaskToken) {
  token.complete()
}

// ============================================================================
// MARK: - Test: returning a ~Discardable value (transfers obligation to caller)
// ============================================================================

// CHECK-LABEL: sil hidden [ossa] @$s14nondiscardable10makeTokensAA9TaskTokenVyF : $@convention(thin) () -> @owned TaskToken {
// CHECK:   [[TOKEN:%.*]] = struct $TaskToken
// CHECK:   return
// CHECK: } // end sil function '$s14nondiscardable10makeTokensAA9TaskTokenVyF'
func makeTokens() -> TaskToken {
  return TaskToken(id: 42)
}

// ============================================================================
// MARK: - Test: var binding with reassignment
// ============================================================================

// CHECK-LABEL: sil hidden [ossa] @$s14nondiscardable13testVarAssignyyF : $@convention(thin) () -> () {
// CHECK:   alloc_stack {{.*}} $TaskToken
// CHECK:   mark_unresolved_non_copyable_value [consumable_and_assignable]
// CHECK: } // end sil function '$s14nondiscardable13testVarAssignyyF'
func testVarAssign() {
  var token = TaskToken(id: 1)
  token = TaskToken(id: 2) // Old value implicitly destroyed — error in mandatory pass!
  token.complete()
}

// ============================================================================
// MARK: - Test: consuming via switch
// ============================================================================

enum TokenOrError: ~Discardable {
  case token(TaskToken)
  case error(Int)

  consuming func handle() {
    switch consume self {
    case .token(let t):
      t.complete()
    case .error(_):
      break // error is Discardable (Int), OK
    }
  }
}

// CHECK-LABEL: sil hidden [ossa] @$s14nondiscardable9testSwitchyyAA12TokenOrErrorOnF : $@convention(thin) (@owned TokenOrError) -> () {
// CHECK: bb0([[ARG:%.*]] : @owned $TokenOrError):
// CHECK:   mark_unresolved_non_copyable_value [consumable_and_assignable]
// CHECK: } // end sil function '$s14nondiscardable9testSwitchyyAA12TokenOrErrorOnF'
func testSwitch(_ value: consuming TokenOrError) {
  value.handle()
}
