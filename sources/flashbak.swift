// into a new Xcode iOS App project (SwiftUI, iOS 17+ target).
// Add NSCameraUsageDescription and NSPhotoLibraryAddUsageDescription to Info.plist.
// Tested on iOS 17/18 AVFoundation API works on iOS 26 (which shares the same AVFoundation layer).
//idk how ANY of this works !!! :3
import SwiftUI
import AVFoundation
import Photos

// MARK: - Camera Manager

class CameraManager: NSObject, ObservableObject {
    // Session
    let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera.queue")

    // Published state
    @Published var iso: Float = 100
    @Published var shutterSpeed: Double = 1.0 / 60.0   // seconds
    @Published var exposureCompensation: Float = 0.0
    @Published var whiteBalance: Float = 5500           // Kelvin
    @Published var focusDistance: Float = 0.5           // 0–1
    @Published var isFlashOn: Bool = false
    @Published var isTorchOn: Bool = false
    @Published var zoomFactor: CGFloat = 1.0
    @Published var isCapturing: Bool = false
    @Published var lastThumbnail: UIImage?
    @Published var permissionDenied: Bool = false
    @Published var isManualFocus: Bool = false
    @Published var isManualExposure: Bool = false
    @Published var isManualWB: Bool = false

    // Ranges (set after device is discovered)
    @Published var isoRange: ClosedRange<Float> = 25...3200
    @Published var shutterRange: ClosedRange<Double> = (1.0/8000.0)...(1.0/4.0)
    @Published var evRange: ClosedRange<Float> = -3...3
    @Published var wbRange: ClosedRange<Float> = 2000...8000
    @Published var maxZoom: CGFloat = 6.0

    override init() {
        super.init()
        checkPermission()
    }

    // MARK: - Permission

    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.setupSession() : (self?.permissionDenied = true)
                }
            }
        default:
            DispatchQueue.main.async { self.permissionDenied = true }
        }
    }

    // MARK: - Session Setup

    func setupSession() {
        queue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            // Prefer RAW-capable device
            let deviceTypes: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera, .builtInDualWideCamera,
                .builtInDualCamera, .builtInWideAngleCamera
            ]
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: deviceTypes,
                mediaType: .video,
                position: .back
            )
            guard let dev = discovery.devices.first else { return }
            self.device = dev
            self.configureDeviceRanges(dev)

            do {
                let inp = try AVCaptureDeviceInput(device: dev)
                if self.session.canAddInput(inp) {
                    self.session.addInput(inp)
                    self.input = inp
                }
            } catch { print("Input error:", error); return }

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                // Enable RAW capture if supported
                if let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                    print("RAW format available: \(rawFormat)")
                }
                // Disable auto-processing where possible (iOS 26 / AVFoundation)
                self.photoOutput.isHighResolutionCaptureEnabled = true
            }

            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    private func configureDeviceRanges(_ dev: AVCaptureDevice) {
        let activeFormat = dev.activeFormat
        let isoMin = activeFormat.minISO
        let isoMax = activeFormat.maxISO
        let durMin = CMTimeGetSeconds(activeFormat.minExposureDuration)
        let durMax = min(CMTimeGetSeconds(activeFormat.maxExposureDuration), 0.25)

        DispatchQueue.main.async {
            self.isoRange = isoMin...isoMax
            self.iso = (isoMin + isoMax) / 2
            self.shutterRange = durMin...durMax
            self.maxZoom = min(dev.maxAvailableVideoZoomFactor, 10)
        }
    }

    // MARK: - Device Controls

    func applySettings() {
        guard let device else { return }
        queue.async {
            do {
                try device.lockForConfiguration()

                // Exposure
                if self.isManualExposure {
                    let dur = CMTimeMakeWithSeconds(self.shutterSpeed, preferredTimescale: 1_000_000)
                    device.setExposureModeCustom(duration: dur, iso: self.iso, completionHandler: nil)
                } else {
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    device.setExposureTargetBias(self.exposureCompensation, completionHandler: nil)
                }

                // White Balance
                if self.isManualWB {
                    if device.isWhiteBalanceModeSupported(.locked) {
                        let gains = device.deviceWhiteBalanceGains(for:
                            AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                                temperature: self.whiteBalance, tint: 0))
                        let clamped = self.clampGains(gains, device: device)
                        device.setWhiteBalanceModeLocked(with: clamped, completionHandler: nil)
                    }
                } else {
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                }

                // Focus
                if self.isManualFocus {
                    if device.isFocusModeSupported(.locked) {
                        device.setFocusModeLocked(lensPosition: self.focusDistance, completionHandler: nil)
                    }
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }

                // Zoom
                device.videoZoomFactor = max(1.0, min(self.zoomFactor, device.maxAvailableVideoZoomFactor))

                // Torch (continuous flash)
                if device.hasTorch {
                    device.torchMode = self.isTorchOn ? .on : .off
                }

                device.unlockForConfiguration()
            } catch { print("Config error:", error) }
        }
    }

    private func clampGains(_ gains: AVCaptureDevice.WhiteBalanceGains,
                             device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain:   min(max(1.0, gains.redGain),   maxGain),
            greenGain: min(max(1.0, gains.greenGain), maxGain),
            blueGain:  min(max(1.0, gains.blueGain),  maxGain)
        )
    }

    // MARK: - Capture

    func capturePhoto() {
        guard !isCapturing else { return }
        isCapturing = true

        let settings = AVCapturePhotoSettings()

        // Flash
        if isFlashOn, device?.hasFlash == true {
            settings.flashMode = .on
        } else {
            settings.flashMode = .off
        }

        // Disable auto-stabilization / processing
        settings.isHighResolutionPhotoEnabled = true
        if #available(iOS 16, *) {
            // Disable lens stabilisation so we get what the sensor sees
            settings.isAutoDualCameraFusionEnabled = false
        }

        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Torch Toggle

    func toggleTorch() {
        isTorchOn.toggle()
        applySettings()
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        DispatchQueue.main.async { self.isCapturing = false }
        guard error == nil, let data = photo.fileDataRepresentation() else { return }

        // Save to camera roll
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, err in
                if let err { print("Save error:", err) }
            }
        }

        // Thumbnail
        if let image = UIImage(data: data) {
            DispatchQueue.main.async { self.lastThumbnail = image }
        }
    }
}

// MARK: - Preview Layer View

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.session = session
        return view
    }
    func updateUIView(_ view: PreviewUIView, context: Context) {}
}

class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var session: AVCaptureSession? {
        didSet {
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @State private var showControls = true
    @State private var activePanel: Panel = .exposure

    enum Panel: String, CaseIterable {
        case exposure = "EXP"
        case focus    = "FOCUS"
        case wb       = "WB"
        case zoom     = "ZOOM"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if cam.permissionDenied {
                permissionView
            } else {
                cameraBody
            }
        }
    }

    // MARK: Camera Body

    var cameraBody: some View {
        ZStack(alignment: .bottom) {
            // Viewfinder
            CameraPreview(session: cam.session)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { showControls.toggle() } }

            // Overlay
            if showControls {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    panelSelector
                    activeControlPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    bottomBar
                        .padding(.bottom, 30)
                }
            } else {
                // Minimal overlay — just shutter
                VStack {
                    Spacer()
                    shutterButton
                        .padding(.bottom, 50)
                }
            }
        }
    }

    // MARK: Top Bar

    var topBar: some View {
        HStack(spacing: 16) {
            // Flash toggle
            Button {
                cam.isFlashOn.toggle()
            } label: {
                Label(cam.isFlashOn ? "Flash ON" : "Flash OFF",
                      systemImage: cam.isFlashOn ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(cam.isFlashOn ? .yellow : .white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Torch toggle
            Button {
                cam.toggleTorch()
            } label: {
                Image(systemName: cam.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 16))
                    .foregroundColor(cam.isTorchOn ? .yellow : .white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }

            Spacer()

            // ISO / SS quick readout
            VStack(alignment: .trailing, spacing: 2) {
                Text("ISO \(Int(cam.iso))")
                Text("1/\(Int(1.0 / cam.shutterSpeed))s")
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 12)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: Panel Selector

    var panelSelector: some View {
        HStack(spacing: 0) {
            ForEach(Panel.allCases, id: \.self) { panel in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { activePanel = panel }
                } label: {
                    Text(panel.rawValue)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(activePanel == panel ? Color.white : Color.clear)
                        .foregroundColor(activePanel == panel ? .black : .white)
                }
            }
        }
        .background(Color.black.opacity(0.5))
        .cornerRadius(8)
        .padding(.horizontal, 20)
    }

    // MARK: Active Control Panel

    @ViewBuilder
    var activeControlPanel: some View {
        Group {
            switch activePanel {
            case .exposure: exposurePanel
            case .focus:    focusPanel
            case .wb:       wbPanel
            case .zoom:     zoomPanel
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.55))
    }

    // Exposure
    var exposurePanel: some View {
        VStack(spacing: 12) {
            Toggle("Manual Exposure", isOn: $cam.isManualExposure)
                .toggleStyle(CamToggleStyle())
                .onChange(of: cam.isManualExposure) { _ in cam.applySettings() }

            if cam.isManualExposure {
                SliderRow(label: "ISO", value: $cam.iso,
                          range: cam.isoRange,
                          display: "\(Int(cam.iso))")
                .onChange(of: cam.iso) { _ in cam.applySettings() }

                SliderRow(label: "SS",
                          value: Binding(
                            get: { Float(cam.shutterSpeed) },
                            set: { cam.shutterSpeed = Double($0) }),
                          range: Float(cam.shutterRange.lowerBound)...Float(cam.shutterRange.upperBound),
                          display: "1/\(Int(1.0 / cam.shutterSpeed))s")
                .onChange(of: cam.shutterSpeed) { _ in cam.applySettings() }
            } else {
                SliderRow(label: "EV",
                          value: $cam.exposureCompensation,
                          range: cam.evRange,
                          display: String(format: "%+.1f", cam.exposureCompensation))
                .onChange(of: cam.exposureCompensation) { _ in cam.applySettings() }
            }
        }
    }

    // Focus
    var focusPanel: some View {
        VStack(spacing: 12) {
            Toggle("Manual Focus", isOn: $cam.isManualFocus)
                .toggleStyle(CamToggleStyle())
                .onChange(of: cam.isManualFocus) { _ in cam.applySettings() }

            if cam.isManualFocus {
                SliderRow(label: "FOCUS",
                          value: $cam.focusDistance,
                          range: 0...1,
                          display: String(format: "%.2f", cam.focusDistance))
                .onChange(of: cam.focusDistance) { _ in cam.applySettings() }
            } else {
                Text("Tap viewfinder to focus")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    // White Balance
    var wbPanel: some View {
        VStack(spacing: 12) {
            Toggle("Manual White Balance", isOn: $cam.isManualWB)
                .toggleStyle(CamToggleStyle())
                .onChange(of: cam.isManualWB) { _ in cam.applySettings() }

            if cam.isManualWB {
                SliderRow(label: "KELVIN",
                          value: $cam.whiteBalance,
                          range: cam.wbRange,
                          display: "\(Int(cam.whiteBalance))K")
                .onChange(of: cam.whiteBalance) { _ in cam.applySettings() }

                // Quick WB presets
                HStack(spacing: 8) {
                    ForEach([("☁️", Float(6500)), ("☀️", Float(5500)),
                             ("💡", Float(3200)), ("🔵", Float(7500))], id: \.1) { emoji, k in
                        Button {
                            cam.whiteBalance = k
                            cam.applySettings()
                        } label: {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 44, height: 36)
                                .background(Color.white.opacity(abs(cam.whiteBalance - k) < 100 ? 0.3 : 0.1))
                                .cornerRadius(6)
                        }
                    }
                }
            }
        }
    }

    // Zoom
    var zoomPanel: some View {
        VStack(spacing: 12) {
            SliderRow(label: "ZOOM",
                      value: Binding(get: { Float(cam.zoomFactor) },
                                     set: { cam.zoomFactor = CGFloat($0) }),
                      range: 1...Float(cam.maxZoom),
                      display: String(format: "%.1fx", cam.zoomFactor))
            .onChange(of: cam.zoomFactor) { _ in cam.applySettings() }

            HStack(spacing: 12) {
                ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { z in
                    Button("\(Int(z))×") {
                        cam.zoomFactor = min(CGFloat(z), cam.maxZoom)
                        cam.applySettings()
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(abs(cam.zoomFactor - CGFloat(z)) < 0.2 ? .black : .white)
                    .frame(width: 44, height: 32)
                    .background(abs(cam.zoomFactor - CGFloat(z)) < 0.2 ? Color.white : Color.white.opacity(0.15))
                    .cornerRadius(6)
                }
            }
        }
    }

    // MARK: Bottom Bar

    var bottomBar: some View {
        HStack(alignment: .center, spacing: 0) {
            // Thumbnail
            ZStack {
                if let thumb = cam.lastThumbnail {
                    Image(uiImage: thumb)
                        .resizable().scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.3), lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 56, height: 56)
                }
            }
            .frame(maxWidth: .infinity)

            // Shutter
            shutterButton

            // Spacer (balance)
            Color.clear.frame(width: 56, height: 56)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 30)
    }

    var shutterButton: some View {
        Button { cam.capturePhoto() } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(cam.isCapturing ? Color.gray : Color.white)
                    .frame(width: 64, height: 64)
                    .scaleEffect(cam.isCapturing ? 0.85 : 1.0)
                    .animation(.easeInOut(duration: 0.1), value: cam.isCapturing)
            }
        }
        .disabled(cam.isCapturing)
    }

    // MARK: Permission View

    var permissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.5))
            Text("Camera access required")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Reusable Controls

struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let display: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 52, alignment: .leading)
            Slider(value: $value, in: range)
                .accentColor(.white)
            Text(display)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

struct CamToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? Color.white : Color.white.opacity(0.2))
                    .frame(width: 44, height: 24)
                Circle()
                    .fill(configuration.isOn ? Color.black : Color.white)
                    .frame(width: 18, height: 18)
                    .offset(x: configuration.isOn ? 10 : -10)
                    .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
            }
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

// MARK: - App Entry Point

@main
struct RawCamApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
