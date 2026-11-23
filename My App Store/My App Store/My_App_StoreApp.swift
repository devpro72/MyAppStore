import SwiftUI

@main
struct My_App_StoreApp: App {
    @State private var store = StoreModel()
    
    var body: some Scene {
        WindowGroup {
            StoreView()
                .environment(store)
                .task { await store.load() }
        }
    }
}
