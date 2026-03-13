// RUN: %target-swift-frontend -emit-sil -verify -enable-experimental-feature NonDiscardableTypes %s

struct Token: ~Discardable {
  var x = 0
  consuming func complete() {}
  consuming func complete2() {
    self.complete()
  }
  mutating func mut() {
    x += 1
  }
  mutating func mut2() { // expected-error {{non-discardable value 'self' must be consumed before it goes out of scope}}
    self = Token()
  }
  mutating func mut3() {
    self.complete()
    self = Token()
  }
}

struct ND: ~Discardable {
  var t = Token()

  consuming func complete() {} // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}
  consuming func complete2() {
    self.complete()
  }
  consuming func complete3() {
    t.complete()
  }
}

struct NC: ~Copyable {
  var t = Token()

  consuming func complete() {} // OK — NC has a deinit that handles field consumption
  consuming func complete2() {
    self.complete()
  }

  deinit {
    t.complete()
  }
}

struct NC2: ~Copyable {
  var t = Token()

  deinit {} // expected-error {{non-discardable stored property 't' must be consumed before deinit exits}}
}

struct NC3: ~Copyable {
  var t = Token()

  deinit {
    t.complete()
  }
}


func testNC() {
  let nc = NC()
  _ = nc // OK — NC has a proper deinit
}

func consume(_ t: consuming Token) {} // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}

func testImplicitDiscard() {
  let t = Token() // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}
  _ = t
}

func testExplicitConsume() {
  let t = Token()
  consume(t) // OK — explicitly consumed via free function
}

func testConsumingMethod() {
  let t = Token()
  t.complete() // OK — consuming method on self
}

func testParameterConsume(_ t: consuming Token) {
  consume(t) // OK
}

func testFatalErrorPath() {
  let t = Token()
  if Bool.random() {
    t.complete()
  } else {
    fatalError("unreachable")
  }
}

func testControlFlowBothPaths(cond: Bool) {
  let t = Token()
  if cond {
    t.complete()
  } else {
    consume(t)
  }
}

// borrowing: the caller retains ownership, so no discard here.
func testBorrowing(_ t: borrowing Token) {
  // OK — borrowing doesn't consume, caller still owns it
}

func testInout(_ t: inout Token) {
  _ = t // expected-error {{non-discardable value '<anonymous>' must be consumed before it goes out of scope}}
  t = Token()
}

func testInout2(_ t: inout Token) { // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}
  t = Token()
}

func testInout3(_ t: inout Token) {
  t.mut()
}

func testInout4(_ t: inout Token) {
  t.x -= 1
}

func testReassign() {
  var t = Token() // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}
  t = Token()
  consume(t)
}


func testReinitAfterConsume() {
  var t = Token() // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}
  consume(t) // first consume — OK
  t = Token() // reinitialized value never consumed
}

func testReinitAfterConsume2() {
  var t = Token()
  consume(t) // first consume — OK
  t = Token() // reinitialized value
  consume(t) // second consume — OK
}

func testOneBranchMissing(cond: Bool) {
  let t = Token() // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}
  if cond {
    consume(t)
  }
  // else: t goes out of scope unconsumed
}

func testDoBlock() {
  let t = Token()
  do {
    consume(t)
  }
}

func testDoBlock2() {
  do {
    let t = Token()
    consume(t)
  }
}

func testWhileLoop() {
  var t = Token()
  while Bool.random() {
    consume(t)
    t = Token()
  }
  consume(t)
}

func testForLoop() {
  let t = Token()
  for _ in 0..<5 {
  }
  consume(t)
}

// do/catch — consumed in try block.
struct MyError: Error {}
func throwing() throws { throw MyError() }

func testDoCatch() {
  do {
    let t = Token() // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}
    try throwing()
    consume(t)
  } catch {
  }
}

func testDoCatch2() {
  do {
    try throwing()
    let t = Token()
    consume(t)
  } catch {
    // OK
  }
}
