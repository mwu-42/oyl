import AVFoundation
import SwiftUI

/// A mirror: you, from the camera, before a call, say. The camera's the one the hand gestures
/// use, and it's on only while this page shows (gestures or no). Turned off on the Oyls tab, the
/// page goes from the tabs.
struct MirrorPage: View {
    @ObservedObject var gestures: GestureWatcher

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.06))
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted:
                VStack(spacing: 6) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                    Button("Allow the camera in Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                }
            default:
                // Until the first frame comes, a camera where you'll be.
                Image(systemName: "camera.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.25))
                if let preview = gestures.preview {
                    CameraPreview(preview: preview)
                }
            }
        }
        .frame(width: Layout.mirrorSize.width, height: Layout.mirrorSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .onAppear { gestures.mirroring = true }
        .onDisappear { gestures.mirroring = false }
    }
}

/// The camera's picture as it comes, mirrored, filling the frame: the one preview the camera
/// made, moved into each new mirror rather than made again.
private struct CameraPreview: NSViewRepresentable {
    let preview: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(preview)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if preview.superlayer !== view.layer { view.layer?.addSublayer(preview) }
    }
}
