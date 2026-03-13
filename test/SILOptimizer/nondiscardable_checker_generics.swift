// RUN: %target-swift-frontend -emit-sil -verify -enable-experimental-feature NonDiscardableTypes %s

// ===================================================================
// Test: generics with ~Discardable bounds
// ===================================================================

struct Token: ~Discardable {
  var id: Int
  consuming func use() {}
}

// === Generic function that accepts ~Discardable ===

func genericConsume<T: ~Copyable & ~Discardable>(_ t: consuming T) {} // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}

func genericConsumeForward<T: ~Copyable & ~Discardable>(_ t: consuming T, to sink: consuming T) {}
// expected-error @-1 {{non-discardable value 't' must be consumed before it goes out of scope}}
// expected-error @-2 {{non-discardable value 'sink' must be consumed before it goes out of scope}}

// === Unconstrained generic (T: Discardable by default) — no errors ===

func genericDiscardable<T>(_ t: consuming T) {
  // T is Discardable by default, so dropping it is fine
}

// === Generic with explicit Discardable constraint — no errors ===

func genericExplicitDiscardable<T: Discardable>(_ t: consuming T) {
  // Explicitly Discardable, dropping is fine
}

// === Generic struct wrapping ~Discardable ===

struct Wrapper<T: ~Copyable & ~Discardable>: ~Copyable, ~Discardable {
  var inner: T

  consuming func take() -> T {
    return inner
  }
}

struct Wrapper2<T: ~Copyable & ~Discardable>: ~Copyable, ~Discardable {
  var a: T // expected-error {{non-discardable value 'a' must be consumed before it goes out of scope}}
  var b: T // expected-error {{non-discardable value 'b' must be consumed before it goes out of scope}}

  consuming func take() -> T {
    if Bool.random() {
      return a
    } else {
      return b
    }
  }
}

struct Wrapper2Good<T: ~Copyable & ~Discardable>: ~Copyable, ~Discardable {
  var a: T
  var b: T

  consuming func take() -> T {
    if Bool.random() {
      genericConsume(b)
      return a
    } else {
      genericConsume(a)
      return b
    }
  }
}

func testWrapperGood() {
  let w = Wrapper(inner: Token(id: 1))
  w.take().use()
}

func testWrapperBad() {
  let w = Wrapper(inner: Token(id: 1)) // expected-error {{non-discardable value 'w' must be consumed before it goes out of scope}}
  _ = w
}

// === Generic function that properly forwards ===

func forwardToUse<T: ~Copyable & ~Discardable>(_ t: consuming T, _ action: (consuming T) -> Void) {
  action(t) // OK — consumed by the closure
}

func testForwardToUse() {
  let t = Token(id: 42)
  forwardToUse(t) { $0.use() }
}

// === Generic with conditional Discardable ===

func maybeDiscard<T: ~Copyable & ~Discardable>(_ t: consuming T, cond: Bool, action: (consuming T) -> Void) { // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}
  if cond {
    action(t)
  }
  // else: t goes out of scope unconsumed
}

// ===================================================================
// Protocol with associated type — Disposable: ~Copyable & ~Discardable
// ===================================================================

protocol Disposable: ~Copyable, ~Discardable {
  consuming func dispose()
}

extension Token: Disposable {
  consuming func dispose() { self.use() }
}

func genericDispose<T: Disposable & ~Copyable & ~Discardable>(_ t: consuming T) {
  t.dispose() // OK — consuming protocol requirement
}

func genericDisposeForget<T: Disposable & ~Copyable & ~Discardable>(_ t: consuming T) {} // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}

func testProtocolDispose() {
  let t = Token(id: 10)
  genericDispose(t)
}

// === Type that is both ~Discardable and Disposable ===

struct FileHandle: ~Discardable, Disposable {
  var fd: Int
  consuming func dispose() {}
  consuming func close() {}
}

func testFileHandleGood() {
  let f = FileHandle(fd: 3)
  f.close() // OK — consuming method
}

func testFileHandleBad() {
  let f = FileHandle(fd: 3) // expected-error {{non-discardable value 'f' must be consumed before it goes out of scope}}
  _ = f
}

func testFileHandleViaProtocol() {
  let f = FileHandle(fd: 4)
  genericDispose(f) // OK — disposed via protocol
}

// === Existential-like usage via consuming closures ===

func withToken(_ action: (consuming Token) -> Void) {
  let t = Token(id: 99)
  action(t)
}

func testWithToken() {
  withToken { $0.use() }
}

// ===================================================================
// Generic struct deinit with ~Discardable field
// ===================================================================

struct GenericStructHolder<T: ~Copyable & ~Discardable>: ~Copyable {
  var value: T // no error is expected here, shouldn't generate `set`

  init(value: consuming T) {
    self.value = value
  }

  deinit {
  } // expected-error {{non-discardable stored property 'value' must be consumed before deinit exits}}
}

struct GenericStructHolderGood<T: ~Copyable & ~Discardable>: ~Copyable {
  var value: T // no error is expected here, shouldn't generate `set`
  let action: (consuming T) -> Void

  init(value: consuming T, action: @escaping (consuming T) -> Void) {
    self.value = value
    self.action = action
  }

  deinit {
    action(value) // Properly consumed via closure
  }
}

// Struct with concrete ~Discardable field

struct ConcreteStructHolder: ~Copyable {
  var token: Token

  deinit {
  } // expected-error {{non-discardable stored property 'token' must be consumed before deinit exits}}
}

struct ConcreteStructHolderGood: ~Copyable {
  var token: Token

  deinit {
    token.use() // Properly consumed
  }
}

// Struct with multiple ~Discardable fields

struct MultiFieldStruct: ~Copyable {
  var t1: Token
  var t2: FileHandle

  deinit {
    t1.use()
    t2.close()
  }
}

struct MultiFieldStructBad: ~Copyable {
  var t1: Token
  var t2: FileHandle

  deinit {
    t1.use()
    // forgot t2
  } // expected-error {{non-discardable stored property 't2' must be consumed before deinit exits}}
}

// ===================================================================
// Generic class deinit with ~Discardable field
// ===================================================================

final class GenericClassHolder<T: ~Copyable & ~Discardable> {
  var value: T // no error is expected here, shouldn't generate `set`

  init(value: consuming T) {
    self.value = value
  }

  deinit { // expected-error {{non-discardable stored property 'value' must be consumed before deinit exits}}
  }
}

final class GenericClassHolderGood<T: ~Copyable & ~Discardable> {
  var value: T
  let action: (consuming T) -> Void

  init(value: consuming T, action: @escaping (consuming T) -> Void) {
    self.value = value
    self.action = action
  }

  deinit {
    action(value) // Properly consumed via closure
  }
}

// === Discardable generic class — no deinit needed ===

final class DiscardableHolder<T> {
  var value: T

  init(value: T) {
    self.value = value
  }
  // No deinit — T is Discardable by default, no errors
}

// === Discardable struct — no deinit needed ===

struct DiscardableStructHolder<T> {
  var value: T
  // No deinit — T is Discardable by default, no errors
}
