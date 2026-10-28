import SwiftUI

// The macOS 26+/27 SDKs turn the `@State` attribute into a compiler macro whose plugin ships only
// inside Xcode. `@Local` wraps the macro-free `State<Value>` struct directly: same semantics.
// (Copied from Dailies, MIT.)
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        storage = SwiftUI.State(wrappedValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
