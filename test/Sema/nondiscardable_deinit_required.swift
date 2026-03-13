// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature NonDiscardableTypes %s

// Tests that types containing non-discardable stored properties must have
// an explicit deinit. This applies to structs, classes, and actors.

struct Token: ~Discardable, ~Copyable {
  var x = 0
  consuming func complete() {}
}

// MARK: - Structs

// Error: ~Copyable struct with ~Discardable field but no deinit.
struct BadStruct: ~Copyable { // expected-error {{type 'BadStruct' with non-discardable stored property 'token' must have an explicit 'deinit'}}
  var token = Token()
}

// OK: ~Copyable struct with ~Discardable field and explicit deinit.
struct GoodStruct: ~Copyable {
  var token = Token()
  deinit {
    token.complete()
  }
}

// OK: ~Discardable struct — the type itself is ~Discardable, so deinit is
// banned by a different diagnostic. No deinit-required check fires.
struct DiscardableStruct: ~Discardable {
  var token = Token()
}

// OK: Copyable struct can't contain ~Copyable fields, so this doesn't apply.
// (If it did have one, it would be a different error.)

// MARK: - Classes

// Error: Class with ~Discardable field but no explicit deinit.
final class BadClass { // expected-error {{type 'BadClass' with non-discardable stored property 'token' must have an explicit 'deinit'}}
  var token = Token()
}

// OK: Class with ~Discardable field and explicit deinit.
final class GoodClass {
  var token = Token()
  deinit {
    token.complete()
  }
}

// MARK: - Multiple fields

struct MultiFieldBad: ~Copyable {
  // expected-error@-1 {{type 'MultiFieldBad' with non-discardable stored property 'a' must have an explicit 'deinit'}}
  // expected-error@-2 {{type 'MultiFieldBad' with non-discardable stored property 'c' must have an explicit 'deinit'}}
  var a = Token()
  var b: Int = 0
  var c = Token()
}

struct MultiFieldGood: ~Copyable {
  var a = Token()
  var b: Int = 0
  var c = Token()
  deinit {
    a.complete()
    c.complete()
  }
}

actor BadActor { // expected-error {{type 'BadActor' with non-discardable stored property 'token' must have an explicit 'deinit'}}
  var token = Token()
}

actor GoodActor {
  var token = Token()
  deinit {
    token.complete()
  }
}
