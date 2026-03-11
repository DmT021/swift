// RUN: %target-swift-frontend -emit-sil -verify %s -enable-experimental-feature NonDiscardableTypes

struct Token: ~Discardable {
  mutating func mut() {}
}

func takeConsuming(_ t: consuming Token) {} // expected-error {{non-discardable value 't' must be consumed before it goes out of scope}}
struct Foo: ~Copyable {
  var token = Token()

  deinit {
  } // expected-error {{non-discardable stored property 'token' must be consumed before deinit exits}}
}

struct Bar: ~Copyable {
  var token = Token()

  deinit {
    takeConsuming(token)
  }

  mutating func update() {
    token.mut()
  }
}
