import SwiftUI
import AVKit

// This struct wraps the UIKit AVRoutePickerView so it can be used in SwiftUI.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        routePickerView.activeTintColor = UIColor(.white)
        routePickerView.tintColor = UIColor(.white)
        return routePickerView
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // This view doesn't need to be updated.
    }
}
