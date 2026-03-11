// RUN: %target-swift-frontend %s -emit-sil -verify -Onone -assert-config Debug
// RUN: %target-swift-frontend %s -emit-sil -verify -Onone -assert-config Release
// RUN: %target-swift-frontend %s -emit-sil -verify -Onone -assert-config Unchecked
// RUN: %target-swift-frontend %s -emit-sil -verify -O -assert-config Debug
// RUN: %target-swift-frontend %s -emit-sil -verify -O -assert-config Release
// RUN: %target-swift-frontend %s -emit-sil -verify -O -assert-config Unchecked
// RUN: %target-swift-frontend %s -emit-sil -verify -Ounchecked -assert-config Debug
// RUN: %target-swift-frontend %s -emit-sil -verify -Ounchecked -assert-config Release
// RUN: %target-swift-frontend %s -emit-sil -verify -Ounchecked -assert-config Unchecked

// assertionFailure() returns Void (not Never), so a function that ends with it
// must still provide a return value, regardless of -assert-config and -O modes
func assertionFailure_isNotNoreturn() -> Int {
  _ = 0
  assertionFailure()
} // expected-error {{missing return in global function expected to return 'Int'}}

