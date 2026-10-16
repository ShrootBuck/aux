import SwiftUI

// Use the public property wrapper explicitly, including on SDKs that also
// expose a State macro requiring an Xcode-only compiler plugin.
typealias ViewState<Value> = SwiftUI.State<Value>
