Here is a draft for a Swift Evolution pitch introducing the `~Discardable` protocol. It is structured to be highly technical, addressing the exact language design nuances we discussed, while keeping the scope tightly focused on an MVP (Minimum Viable Product) for linear typing.

***

# [Pitch] `~Discardable`: Strict Linear Types (Must-Use Values)

* **Status:** Pitch
* **Authors:** [Your Name]
* **Related Proposals:** [SE-0390: Noncopyable structs and enums](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md)

## Summary

Swift's introduction of `~Copyable` provided the language with *affine* types: values that can be used *at most* once. However, Swift currently lacks true *linear* types: values that must be used *exactly* once. 

We propose a new suppressible protocol, `~Discardable`, which prevents a value from being implicitly destroyed. A `~Discardable` value must be explicitly consumed on all execution paths. This allows library authors to statically guarantee that resources are cleanly shut down, continuations are explicitly resumed, and state machines reach their terminal states, shifting safety checks from runtime traps (via `deinit` `fatalError`s) to compile-time guarantees.

## Motivation

Currently, when a `~Copyable` value falls out of scope or its enclosing object is deallocated, Swift implicitly calls its `deinit`. For types representing absolute obligations—such as `UnsafeContinuation` or a file descriptor requiring a guaranteed flush—falling out of scope without an explicit action is a critical programmer error.

To catch these errors today, authors must fall back to dynamic runtime checks:

```swift
struct ContinuationWrapper: ~Copyable {
    private var consumed = false
    // ...
    deinit {
        if !consumed { fatalError("Leaked continuation!") }
    }
}
```

This dynamic approach forces unrecoverable runtime crashes, removes user control over error handling, and limits the compiler's ability to reason about program correctness.

## Proposed Solution

We propose a new suppressible protocol: `~Discardable`. Types that suppress `Discardable` cannot be implicitly destroyed. The compiler will emit an error if a `~Discardable` binding reaches the end of its lifetime without being explicitly passed to a `consuming` function or destructured.

```swift
struct TaskToken: ~Discardable {
    consuming func complete() { ... }
}

func doWork() {
    let token = TaskToken()
    // ERROR: 'token' is unconsumed. It cannot be implicitly discarded.
}
```

## Detailed Design

Introducing `~Discardable` requires precise rules across the type system, control flow, and object lifecycles.

### 1. The `~Discardable` Protocol

`Discardable` is a suppressible (invertible) protocol, alongside `Copyable` and `Escapable`. In the standard library, **`Copyable` refines `Discardable`**:

```swift
@_marker public protocol Discardable {}
@_marker public protocol Copyable: Discardable {}
```

This refinement means:
- Every `Copyable` type is automatically `Discardable`. This is sound because copyable values can always be freely duplicated and discarded — there is no unique obligation to enforce.
- Writing `~Discardable` on a type **automatically implies `~Copyable`**. Since `Copyable` refines `Discardable`, opting out of `Discardable` necessarily opts out of `Copyable` too. Users never need to write both `~Copyable` and `~Discardable`.

This is the correct semantic hierarchy: linear tracking (must-use) requires unique ownership (can't copy), so removing discardability removes copyability as a direct consequence.

### 2. End of Scope Handling (Local Bindings)
When a local variable of a `~Discardable` type is declared, the compiler enforces that the binding is explicitly consumed on **all** execution paths before the scope exits.

```swift
func process(condition: Bool) throws {
    let token = TaskToken()

    guard condition else {
        // ERROR: 'token' is unconsumed on this execution path.
        throw Error.invalid
    }

    token.complete() // Consumes 'token'
    // OK: token is consumed on the success path.
}
```
*Note: Paths that terminate in `Never` (e.g., `fatalError()`) trivially satisfy this requirement, as the scope never explicitly exits.*

### 3. Type System Restrictions (Stored Properties)
Because a `~Discardable` value cannot be implicitly destroyed, any type that stores a `~Discardable` property must itself have a definitive end-of-life where the compiler can enforce consumption. 

Therefore, a `~Discardable` stored property may **only** appear inside:
1. `~Copyable` structs and enums.
2. `class` types.
3. `actor` types.

If a normal `Copyable` struct attempts to store a `~Discardable` property, the compiler will emit an error, as copying the struct would silently duplicate the linear obligation without a central point of destruction.

### 4. Virality and Composition (`Optional` and Generics)
Linearity is viral. If a generic wrapper holds a `~Discardable` type, the wrapper itself must conditionally become `~Discardable`. 

For the standard library, `Optional` and `Result` must be updated to conditionally suppress `Discardable`:

```swift
// Standard library update:
enum Optional<Wrapped: ~Copyable & ~Discardable>: ~Copyable, ~Discardable { ... }
```

When destructuring a `~Discardable` enum (like `Optional`), the linear obligation transfers to the extracted payload. If the payload is `.none`, the obligation is safely discharged.

```swift
var token: TaskToken? = TaskToken()

// ERROR: Cannot reassign 'token' to nil, because the previous value 
// would be implicitly discarded.
token = nil 

// OK: Destructuring transfers the obligation.
switch consume token {
case .some(let t):
    t.complete() // Explicitly consumed
case .none:
    break // Safely discarded (no payload)
}
```

### 5. `deinit` Handling

A `~Discardable` type **cannot have a `deinit`**. The entire point of `~Discardable` is that the value cannot be silently destroyed; having a `deinit` would provide a silent destruction path that contradicts the linear type guarantee. Instead, all consumption must go through explicit `consuming` methods.

For classes, actors, and `~Copyable` structs that **store** `~Discardable` properties, the type's `deinit` acts as the absolute boundary. The compiler will enforce that all `~Discardable` stored properties are explicitly consumed **before the `deinit` block finishes executing**.

```swift
actor LegacyBridge {
    var continuation: Continuation?

    deinit {
        // COMPILER ERROR: 'continuation' was not consumed before deinit finished.
    }
}
```

To satisfy the compiler, the developer must explicitly consume the property:

```swift
deinit {
    if let cont = consume continuation {
        cont.resume(throwing: CancellationError())
    }
}
```
This elegantly shifts the burden of deciding *how* to handle unconsumed state (e.g., whether to trap, log, or gracefully cancel) onto the user at the exact point of the object's death.

### 6. `consuming` Methods and `discard self`
If a `~Copyable` struct defines a `consuming` method that utilizes `discard self`, that method bypasses the `deinit` block. Therefore, the compiler transfers the consumption requirement to that method.

```swift
struct FileWrapper: ~Copyable {
    var token: TaskToken // ~Discardable

    consuming func close() {
        token.complete() // Must consume the property
        discard self     // Bypasses deinit
    }
}
```
If `token.complete()` were omitted in the method above, the compiler would emit an error stating that the `~Discardable` property `token` was leaked by a method discarding `self`.

## Source Compatibility
This feature is purely additive. Existing code does not use `~Discardable` types and will compile exactly as it does today. Standard library changes (like updating `Optional` to support `~Discardable` payloads) are backward-compatible.

## ABI Compatibility
Purely additive. The enforcement of `~Discardable` is entirely a compile-time static analysis feature. It does not alter the memory layout or runtime behavior of existing types.

## Future Directions

#### `discard self` with Non-Trivially-Destroyed Stored Properties

Currently, `discard self` requires all stored properties of the type to be trivially destroyed (SE-0390). This means `~Discardable` types can use `discard self` when their stored properties are trivial (integers, pointers, `@frozen` value types like `UnsafeContinuation`), but not when they contain reference types or other `~Copyable` types.

Lifting this restriction is an orthogonal concern that requires resolving the open design questions from SE-0390's future directions ("Generalizing `discard self` for types with component cleanups"): specifically, whether `discard self` immediately destroys remaining fields, or only disables the deinit while leaving fields alive for later consumption. Once that generalization is adopted, `~Discardable` types would automatically benefit from it.

#### State-Machine Method Restrictions
This proposal intentionally focuses on the lifecycle of values (end-of-scope and `deinit`). It does not propose complex static tracking for specific "called-once" method sets or arbitrary type-state transitions. By keeping the enforcement boundary at `deinit`, we provide a highly capable MVP for linear types that seamlessly integrates with Swift's existing ownership model without requiring a "morass of language complexity" for tracking arbitrary state machines.
