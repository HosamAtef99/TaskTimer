import SwiftUI
import Combine

/// View-local state, same job as SwiftUI's @State.
/// On newer SDKs @State is a compiler macro that only ships with full Xcode, so
/// building with just the Command Line Tools fails. This wrapper is built on
/// @StateObject, which needs no macro.
final class LocalBox<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

@propertyWrapper
struct Local<Value>: DynamicProperty {
    @StateObject private var box: LocalBox<Value>

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: LocalBox(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        let b = box
        return Binding(get: { b.value }, set: { b.value = $0 })
    }
}
