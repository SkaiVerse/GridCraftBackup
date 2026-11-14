import SwiftUI

@main
struct GridCraftApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()
                GridCraftHost()
            }
            .statusBarHidden(true)
        }
    }
}

struct GridCraftHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> GridCraftViewController { GridCraftViewController() }
    func updateUIViewController(_ vc: GridCraftViewController, context: Context) {}
}
