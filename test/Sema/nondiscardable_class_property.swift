// RUN: %target-typecheck-verify-swift -enable-experimental-feature NonDiscardableTypes

// REQUIRES: swift_feature_NonDiscardableTypes

// Phase 3e: Verify that ~Discardable stored properties are allowed in
// final root classes and actors, but rejected elsewhere.

struct Token: ~Discardable {
  consuming func complete() {}
}

// ============================================================
// OK cases: ~Discardable fields in final root classes
// ============================================================

final class GoodFinalClass {
  var token: Token

  init(token: Token) {
    self.token = token
  }

  deinit {}
}

// ============================================================
// OK cases: ~Discardable fields in actors (implicitly final, no superclass)
// ============================================================

// TODO: Uncomment once actor support is fully wired up
// actor GoodActor {
//   var token: Token
//
//   init(token: Token) {
//     self.token = token
//   }
// }

// ============================================================
// ERROR cases: ~Discardable fields in non-final classes
// ============================================================

class BadNonFinalClass { // expected-note {{consider adding '~Discardable' to}}
  var token: Token // expected-error {{stored property 'token' of 'Discardable'-conforming generic class 'BadNonFinalClass' has non-Discardable type 'Token'}}

  init(token: Token) {
    self.token = token
  }
}

// ============================================================
// ERROR cases: ~Discardable fields in classes with superclass
// ============================================================

class Base {}

final class BadSubclass: Base { // expected-note {{consider adding '~Discardable' to}}
  var token: Token // expected-error {{stored property 'token' of 'Discardable'-conforming generic class 'BadSubclass' has non-Discardable type 'Token'}}

  init(token: Token) {
    super.init()
    self.token = token
  }
}

// ============================================================
// ERROR cases: ~Discardable fields in regular Copyable structs
// ============================================================

struct BadCopyableStruct { // expected-note {{consider adding '~Discardable' to}}
  var token: Token // expected-error {{stored property 'token' of 'Discardable'-conforming generic struct 'BadCopyableStruct' has non-Discardable type 'Token'}}
}

// ============================================================
// OK cases: ~Discardable fields in ~Copyable structs (Phase 3b)
// ============================================================

struct GoodNonCopyableStruct: ~Copyable {
  var token: Token

  deinit {}
}
