// RUN: %target-swift-emit-silgen %s -enable-experimental-feature NonDiscardableTypes | %FileCheck %s
// REQUIRES: asserts

struct Resource: ~Discardable {
  var handle: Int
  consuming func close() {}
}

// CHECK-LABEL: sil hidden [ossa] @$s{{.*}}7MyClassCfd
// CHECK: bb0(%0 : @guaranteed $MyClass):
// Verify noncopyable fields get ref_element_addr + mark_unresolved_non_copyable_value
// CHECK: ref_element_addr %0, #MyClass.resource
// CHECK-NEXT: mark_unresolved_non_copyable_value [consumable_and_assignable]
final class MyClass {
  var resource: Resource
  var name: String

  init(resource: consuming Resource, name: String) {
    self.resource = resource
    self.name = name
  }

  deinit {
    resource.close()
  }
}
