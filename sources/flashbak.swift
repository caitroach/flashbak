// RawCam.swift
// SwiftUI iOS 17+ camera app with manual controls, camera flip, and photo preview.

import SwiftUI
import AVFoundation
import Photos

// MARK: - Camera Manager

class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera.queue")

    @Published var iso: Float = 100
    @Published var shutterSpeed: Double = 1.0 / 60.0
    @Published var exposureCompensation: Float = 0.0
    @Published var whiteBalance: Float = 5500
    @Published var focusDistance: Float = 0.5
    @Published var isFlashOn: Bool = false
    @Published var isTorchOn: Bool = false
    @Published var zoomFactor: CGFloat = 1.0
    @Published var isCapturing: Bool = false
    @Published var permissionDenied: Bool = false
    @Published var isManualFocus: Bool = false
    @Published var isManualExposure: Bool = false
    @Published var isManualWB: Bool = false
    @Published var currentPosition: AVCaptureDevice.Position = .back
    @Published var isFlipping: Bool = false

    // Recent photos (thumbnails + asset IDs for full preview)
    @Published var recentPhotos: [CapturedPhoto] = []

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

    func setupSession(position: AVCaptureDevice.Position = .back) {
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            // Remove existing inputs
            self.session.inputs.forEach { self.session.removeInput($0) }

            let deviceTypes: [AVCaptureDevice.DeviceType] = position == .back
                ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
                : [.builtInTrueDepthCamera, .builtInWideAngleCamera]

            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: deviceTypes,
                mediaType: .video,
                position: position
            )
            guard let dev = discovery.devices.first else {
                self.session.commitConfiguration()
                return
            }
            self.device = dev
            self.configureDeviceRanges(dev)

            do {
                let inp = try AVCaptureDeviceInput(device: dev)
                if self.session.canAddInput(inp) {
                    self.session.addInput(inp)
                    self.input = inp
                }
            } catch { print("Input error:", error); self.session.commitConfiguration(); return }

            if !self.session.outputs.contains(self.photoOutput) {
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                }
            }

            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }

            DispatchQueue.main.async { self.isFlipping = false }
        }
    }

    // MARK: - Flip Camera

    func flipCamera() {
        isFlipping = true
        isTorchOn = false
        currentPosition = currentPosition == .back ? .front : .back
        // Reset manual modes — front cam has limited manual support
        if currentPosition == .front {
            isManualFocus = false
            isManualExposure = false
            isManualWB = false
        }
        setupSession(position: currentPosition)
    }

    private func configureDeviceRanges(_ dev: AVCaptureDevice) {
        let f = dev.activeFormat
        let isoMin = f.minISO
        let isoMax = f.maxISO
        let durMin = CMTimeGetSeconds(f.minExposureDuration)
        let durMax = min(CMTimeGetSeconds(f.maxExposureDuration), 0.25)
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
                if self.isManualExposure {
                    let dur = CMTimeMakeWithSeconds(self.shutterSpeed, preferredTimescale: 1_000_000)
                    device.setExposureModeCustom(duration: dur, iso: self.iso, completionHandler: nil)
                } else {
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    device.setExposureTargetBias(self.exposureCompensation, completionHandler: nil)
                }
                if self.isManualWB {
                    if device.isWhiteBalanceModeSupported(.locked) {
                        let gains = device.deviceWhiteBalanceGains(for:
                            AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: self.whiteBalance, tint: 0))
                        device.setWhiteBalanceModeLocked(with: self.clampGains(gains, device: device), completionHandler: nil)
                    }
                } else {
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                }
                if self.isManualFocus {
                    if device.isFocusModeSupported(.locked) {
                        device.setFocusModeLocked(lensPosition: self.focusDistance, completionHandler: nil)
                    }
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }
                device.videoZoomFactor = max(1.0, min(self.zoomFactor, device.maxAvailableVideoZoomFactor))
                if device.hasTorch {
                    device.torchMode = self.isTorchOn ? .on : .off
                }
                device.unlockForConfiguration()
            } catch { print("Config error:", error) }
        }
    }

    private func clampGains(_ gains: AVCaptureDevice.WhiteBalanceGains,
                             device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let m = device.maxWhiteBalanceGain
        return .init(redGain: min(max(1, gains.redGain), m),
                     greenGain: min(max(1, gains.greenGain), m),
                     blueGain: min(max(1, gains.blueGain), m))
    }

    // MARK: - Capture

    func capturePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        let settings = AVCapturePhotoSettings()
        settings.flashMode = (isFlashOn && device?.hasFlash == true) ? .on : .off
        settings.isHighResolutionPhotoEnabled = true
        if #available(iOS 16, *) { settings.isAutoDualCameraFusionEnabled = false }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func toggleTorch() {
        isTorchOn.toggle()
        applySettings()
    }
}

// MARK: - Captured Photo Model

struct CapturedPhoto: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    let fullImage: UIImage
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        DispatchQueue.main.async { self.isCapturing = false }
        guard error == nil, let data = photo.fileDataRepresentation(),
              let full = UIImage(data: data) else { return }

        // Save to camera roll
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
        }

        // Make thumbnail
        let thumb = full.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? full
        let captured = CapturedPhoto(thumbnail: thumb, fullImage: full)
        DispatchQueue.main.async {
            self.recentPhotos.insert(captured, at: 0)
            if self.recentPhotos.count > 20 { self.recentPhotos = Array(self.recentPhotos.prefix(20)) }
        }
    }
}

// MARK: - Camera Preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView(); v.session = session; return v
    }
    func updateUIView(_ v: PreviewUIView, context: Context) {}
}

class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var session: AVCaptureSession? {
        didSet { previewLayer.session = session; previewLayer.videoGravity = .resizeAspectFill }
    }
}

// MARK: - Photo Preview Sheet

struct PhotoPreviewSheet: View {
    let photo: CapturedPhoto
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: photo.fullImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                withAnimation { isPresented = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(20)
            }
        }
    }
}

// MARK: - Recent Photos Strip

struct RecentPhotosStrip: View {
    let photos: [CapturedPhoto]
    @Binding var selectedPhoto: CapturedPhoto?
    @Binding var showPreview: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(photos) { photo in
                    Button {
                        selectedPhoto = photo
                        withAnimation { showPreview = true }
                    } label: {
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.25), lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 64)
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @State private var showControls = true
    @State private var activePanel: Panel = .exposure
    @State private var selectedPhoto: CapturedPhoto?
    @State private var showPreview = false

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
        .sheet(isPresented: $showPreview) {
            if let photo = selectedPhoto {
                PhotoPreviewSheet(photo: photo, isPresented: $showPreview)
            }
        }
    }

    var cameraBody: some View {
        ZStack(alignment: .bottom) {
            // Viewfinder
            CameraPreview(session: cam.session)
                .ignoresSafeArea()
                .opacity(cam.isFlipping ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: cam.isFlipping)
                .onTapGesture { withAnimation { showControls.toggle() } }

            if showControls {
                VStack(spacing: 0) {
                    topBar
                    Spacer()

                    // Recent photos strip (only if there are photos)
                    if !cam.recentPhotos.isEmpty {
                        RecentPhotosStrip(photos: cam.recentPhotos,
                                          selectedPhoto: $selectedPhoto,
                                          showPreview: $showPreview)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    panelSelector
                    activeControlPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    bottomBar
                        .padding(.bottom, 30)
                }
            } else {
                VStack {
                    Spacer()
                    HStack(spacing: 40) {
                        flipButton
                        shutterButton
                        Color.clear.frame(width: 48, height: 48)
                    }
                    .padding(.bottom, 50)
                }
            }
        }
    }

    // MARK: Top Bar

    var topBar: some View {
        HStack(spacing: 12) {
            // Flash
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
            // Torch (back cam only)
            if cam.currentPosition == .back {
                Button { cam.toggleTorch() } label: {
                    Image(systemName: cam.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 16))
                        .foregroundColor(cam.isTorchOn ? .yellow : .white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
            }
            Spacer()
            // Quick readout
            VStack(alignment: .trailing, spacing: 2) {
                Text("ISO \(Int(cam.iso))")
                Text("1/\(Int(1.0 / max(cam.shutterSpeed, 0.0001)))s")
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 12)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
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

    var exposurePanel: some View {
        VStack(spacing: 12) {
            Toggle("Manual Exposure", isOn: $cam.isManualExposure)
                .toggleStyle(CamToggleStyle())
                .onChange(of: cam.isManualExposure) { _ in cam.applySettings() }
                .disabled(cam.currentPosition == .front)
            if cam.isManualExposure && cam.currentPosition == .back {
                SliderRow(label: "ISO", value: $cam.iso, range: cam.isoRange, display: "\(Int(cam.iso))")
                    .onChange(of: cam.iso) { _ in cam.applySettings() }
                SliderRow(label: "SS",
                          value: Binding(get: { Float(cam.shutterSpeed) }, set: { cam.shutterSpeed = Double($0) }),
                          range: Float(cam.shutterRange.lowerBound)...Float(cam.shutterRange.upperBound),
                          display: "1/\(Int(1.0 / max(cam.shutterSpeed, 0.0001)))s")
                    .onChange(of: cam.shutterSpeed) { _ in cam.applySettings() }
            } else {
                SliderRow(label: "EV", value: $cam.exposureCompensation, range: cam.evRange,
                          display: String(format: "%+.1f", cam.exposureCompensation))
                    .onChange(of: cam.exposureCompensation) { _ in cam.applySettings() }
            }
        }
    }

    var focusPanel: some View {
        VStack(spacing: 12) {
            Toggle("Manual Focus", isOn: $cam.isManualFocus)
                .toggleStyle(CamToggleStyle())
                .onChange(of: cam.isManualFocus) { _ in cam.applySettings() }
                .disabled(cam.currentPosition == .front)
            if cam.isManualFocus && cam.currentPosition == .back {
                SliderRow(label: "FOCUS", value: $cam.focusDistance, range: 0...1,
                          display: String(format: "%.2f", cam.focusDistance))
                    .onChange(of: cam.focusDistance) { _ in cam.applySettings() }
            } else {
                Text(cam.currentPosition == .front ? "Focus unavailable on front camera" : "Tap viewfinder to focus")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    var wbPanel: some View {
        VStack(spacing: 12) {
            Toggle("Manual White Balance", isOn: $cam.isManualWB)
                .toggleStyle(CamToggleStyle())
                .onChange(of: cam.isManualWB) { _ in cam.applySettings() }
                .disabled(cam.currentPosition == .front)
            if cam.isManualWB && cam.currentPosition == .back {
                SliderRow(label: "KELVIN", value: $cam.whiteBalance, range: cam.wbRange,
                          display: "\(Int(cam.whiteBalance))K")
                    .onChange(of: cam.whiteBalance) { _ in cam.applySettings() }
                HStack(spacing: 8) {
                    ForEach([("☁️", Float(6500)), ("☀️", Float(5500)),
                             ("💡", Float(3200)), ("🔵", Float(7500))], id: \.1) { emoji, k in
                        Button {
                            cam.whiteBalance = k; cam.applySettings()
                        } label: {
                            Text(emoji).font(.system(size: 20))
                                .frame(width: 44, height: 36)
                                .background(Color.white.opacity(abs(cam.whiteBalance - k) < 100 ? 0.3 : 0.1))
                                .cornerRadius(6)
                        }
                    }
                }
            }
        }
    }

    var zoomPanel: some View {
        VStack(spacing: 12) {
            SliderRow(label: "ZOOM",
                      value: Binding(get: { Float(cam.zoomFactor) }, set: { cam.zoomFactor = CGFloat($0) }),
                      range: 1...Float(cam.maxZoom),
                      display: String(format: "%.1fx", cam.zoomFactor))
                .onChange(of: cam.zoomFactor) { _ in cam.applySettings() }
            HStack(spacing: 12) {
                ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { z in
                    Button("\(Int(z))×") {
                        cam.zoomFactor = min(CGFloat(z), cam.maxZoom); cam.applySettings()
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
            // Thumbnail of last photo — tap to preview
            ZStack {
                if let last = cam.recentPhotos.first {
                    Button {
                        selectedPhoto = last
                        withAnimation { showPreview = true }
                    } label: {
                        Image(uiImage: last.thumbnail)
                            .resizable().scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                    }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 56, height: 56)
                }
            }
            .frame(maxWidth: .infinity)

            // Shutter
            shutterButton

            // Flip camera button
            flipButton
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 30)
    }

    var shutterButton: some View {
        Button { cam.capturePhoto() } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 76, height: 76)
                Circle()
                    .fill(cam.isCapturing ? Color.gray : Color.white)
                    .frame(width: 64, height: 64)
                    .scaleEffect(cam.isCapturing ? 0.85 : 1.0)
                    .animation(.easeInOut(duration: 0.1), value: cam.isCapturing)
            }
        }
        .disabled(cam.isCapturing || cam.isFlipping)
    }

    var flipButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { cam.flipCamera() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(cam.isFlipping ? .white.opacity(0.4) : .white)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.15))
                .clipShape(Circle())
                .rotationEffect(.degrees(cam.currentPosition == .front ? 180 : 0))
                .animation(.easeInOut(duration: 0.25), value: cam.currentPosition)
        }
        .disabled(cam.isFlipping)
    }

    // MARK: Permission View

    var permissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill").font(.system(size: 48)).foregroundColor(.white.opacity(0.5))
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
            Slider(value: $value, in: range).accentColor(.white)
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
