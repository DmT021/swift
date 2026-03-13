// RUN: %target-swift-frontend -emit-sil -verify %s -enable-experimental-feature NonDiscardableTypes

// Test: final root class deinit with ~Discardable fields

struct Token: ~Discardable {
  var id: Int
  consuming func use() {}
}

struct AnotherToken: ~Discardable {
  var value: Int
  consuming func dispose() {}
}

// === Good: final root class properly consumes ~Discardable field in deinit ===

final class GoodClass {
  var token: Token
  var name: String

  init(token: consuming Token, name: String) {
    self.token = token
    self.name = name
  }

  deinit {
    token.use()
  }
}

// === Bad: final root class does NOT consume ~Discardable field in deinit ===

final class BadClass {
  var token: Token
  var name: String

  init(token: consuming Token, name: String) {
    self.token = token
    self.name = name
  }

  deinit { // expected-error {{non-discardable stored property 'token' must be consumed before deinit exits}}
    // Missing consumption of token
  }
}

// === Good: multiple ~Discardable fields, all consumed ===

final class MultiFieldGood {
  var token1: Token
  var token2: AnotherToken
  var label: String

  init(t1: consuming Token, t2: consuming AnotherToken, label: String) {
    self.token1 = t1
    self.token2 = t2
    self.label = label
  }

  deinit {
    token1.use()
    token2.dispose()
  }
}

// === Bad: multiple ~Discardable fields, only one consumed ===

final class MultiFieldPartial {
  var token1: Token
  var token2: AnotherToken
  var label: String

  init(t1: consuming Token, t2: consuming AnotherToken, label: String) {
    self.token1 = t1
    self.token2 = t2
    self.label = label
  }

  deinit { // expected-error {{non-discardable stored property 'token1' must be consumed before deinit exits}}
    // Only consume token2, forget token1
    token2.dispose()
  }
}

// === Good: final root class with no deinit but no ~Discardable fields ===

final class NormalClass {
  var x: Int
  var name: String
  init(x: Int, name: String) {
    self.x = x
    self.name = name
  }
  // No deinit needed — no ~Discardable fields
}

// === Good: consume in conditional paths (both branches) ===

final class ConditionalConsume {
  var token: Token
  var flag: Bool

  init(token: consuming Token, flag: Bool) {
    self.token = token
    self.flag = flag
  }

  deinit {
    if flag {
      token.use()
    } else {
      token.use()
    }
  }
}

// === Bad: deinit missing entirely for class with ~Discardable field ===

final class NoDeinit { // expected-error {{non-discardable stored property 'token' must be consumed before deinit exits}}
  var token: Token

  init(token: consuming Token) {
    self.token = token
  }
}
