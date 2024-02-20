// RUN: %target-swift-emit-module-interface(%t.swiftinterface) %s -module-name conformances
// RUN: %target-swift-typecheck-module-from-interface(%t.swiftinterface) -module-name conformances
// RUN: %FileCheck %s < %t.swiftinterface

// REQUIRES: concurrency, OS=macosx

// CHECK: @available(
// CHECK-NEXT: public struct SequenceAdapte
@available(SwiftStdlib 5.1, *)
public struct SequenceAdapter<Base: AsyncSequence>: AsyncSequence {
  // CHECK-LABEL: public struct AsyncIterator
  // CHECK: @available{{.*}}macOS 10.15
  // CHECK-NEXT: public typealias Element = Base.Element
  // CHECK: @available(
  // CHECK-NEXT: public typealias Failure = Base.Failure
  public typealias Element = Base.Element

  public struct AsyncIterator: AsyncIteratorProtocol {
    public mutating func next() async rethrows -> Base.Element? { nil }
  }

  // CHECK-LABEL: public func makeAsyncIterator
  public func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }

  // CHECK: @available(
  // CHECK-NEXT: public typealias Failure = Base.Failure
}
