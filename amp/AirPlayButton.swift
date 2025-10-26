import SwiftUI
import AVKit

// This struct wraps the UIKit AVRoutePickerView so it can be used in SwiftUI.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        routePickerView.activeTintColor = UIColor.clear
        routePickerView.tintColor = UIColor.clear
        routePickerView.backgroundColor = .clear
        return routePickerView
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // This view doesn't need to be updated.
    }
}
