//
//  File.swift
//  ThatCamThing
//
//  Created by angel zambrano on 7/2/25.
//

import Foundation
import SwiftUI
import PhotosUI
import AVFoundation
import AVKit

// MARK: - Camera Manager Core

public class CameraManager: NSObject, ObservableObject, @unchecked Sendable {
    
    // MARK: - Public Properties
    public var session = AVCaptureSession()
    public var output = AVCapturePhotoOutput()
    public var preview: AVCaptureVideoPreviewLayer
    
    @Published public var cameraErrors: CameraError? = nil
    @Published public var containsErrors = false
    @Published public var attributes = CameraManagerAttributes()
    @Published public var capturedMedia: CameraMedia? = nil
    
    // MARK: - Private Properties
    private let sessionQueue = DispatchQueue(label: Constants.dispatchQueueName)
    private var currentInput: AVCaptureDeviceInput?
    
    private var zoomObservation: NSKeyValueObservation?
    private var lensObservation: NSKeyValueObservation?
    
    deinit {
        zoomObservation?.invalidate()
        lensObservation?.invalidate()
    }
    
    // MARK: - Initialization
    public override init() {
        self.preview = AVCaptureVideoPreviewLayer()
        super.init()
    }
}

// MARK: - Setup & Permissions

extension CameraManager {
    
    public func requestCameraPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUp()
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { status in
                DispatchQueue.main.async {
                    if status {
                        self.setUp()
                    } else {
                        self.containsErrors = true
                        self.cameraErrors = .cameraPermissionsNotGranted
                    }
                }
            }
        case .denied, .restricted:
            print("Denied")
            self.containsErrors = true
            self.cameraErrors = .cameraPermissionsNotGranted
            return
        default:
            self.containsErrors = true
            self.cameraErrors = .cameraPermissionsNotGranted
            return
        }
    }
    
    private func updateUltraWideAvailability(for position: AVCaptureDevice.Position) {
        let isAvailable = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) != nil
        
        DispatchQueue.main.async {
            self.attributes.isUltraWideAvailable = isAvailable
        }
    }
    
    private func observeDevice(_ device: AVCaptureDevice) {
        zoomObservation?.invalidate()
        lensObservation?.invalidate()
        
        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] observedDevice, change in
            guard let self = self, let factor = change.newValue else { return }
            
            let uiZoom = self.getUIZoomFactor(from: factor, for: observedDevice)
            
            DispatchQueue.main.async {
                self.attributes.zoomFactor = uiZoom
            }
        }
        
        lensObservation = device.observe(\.activePrimaryConstituent, options: [.new]) { [weak self] device, _ in
            guard let activeDevice = device.activePrimaryConstituent else { return }
            let newLensType: CameraLensType
            
            if activeDevice.deviceType == .builtInUltraWideCamera {
                newLensType = .ultraWide
            } else if activeDevice.deviceType == .builtInTelephotoCamera {
                newLensType = .telephoto
            } else {
                newLensType = .wide
            }
            
            DispatchQueue.main.async {
                self?.attributes.lensType = newLensType
                print("Physical lens changed to: \(newLensType)")
            }
        }
    }
    
    func findDevice(position: AVCaptureDevice.Position) throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: position
        )
        
        if let device = discovery.devices.first {
            return device
        }
        
        throw NSError(domain: "Camera", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not find a camera."])
    }
    
    func setUp() {
        sessionQueue.async { [weak self] in
            self?.setUpSessionOnQueue()
        }
    }
    
    private func setUpSessionOnQueue() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        let cameraPosition: AVCaptureDevice.Position = attributes.cameraPosition == .back ? .back : .front

        guard let device = try? findDevice(position: cameraPosition) else {
            DispatchQueue.main.async {
                self.cameraErrors = .cannotSetupInput
            }
            return
        }
            
        do {
            try setDeviceInput(device)
            setZoom(1)
        } catch {
            print("Error setting up camera: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.cameraErrors = .cannotSetupInput
            }
        }
    }
    
    private func setDeviceInput(_ device: AVCaptureDevice) throws {
        let newInput = try AVCaptureDeviceInput(device: device)
        
        let oldInput = self.currentInput
        // Remove existing input
        if let currentInput = oldInput {
            self.session.removeInput(currentInput)
        }
        
        if self.session.canAddInput(newInput) {
            // Add new input
            self.session.addInput(newInput)
            self.currentInput = newInput
            
            // Add output if it is not already in the session
            if !self.session.outputs.contains(self.output) {
                if self.session.canAddOutput(self.output) {
                    self.session.addOutput(self.output)
                    self.output.maxPhotoQualityPrioritization = self.attributes.qualityPrioritization
                } else {
                    DispatchQueue.main.async {
                        self.cameraErrors = .cannotSetupOutput
                    }
                }
            }
            
            // Apply resolution preset after the new input is added
            if self.session.canSetSessionPreset(self.attributes.resolution) {
                self.session.sessionPreset = self.attributes.resolution
            } else {
                self.session.sessionPreset = .high
                print("Desired resolution not supported, using .high instead.")
            }
            
            if attributes.mirrorFrontOutput {
                // Mirror the photo output connection for the front camera
                if let connection = self.output.connection(with: .video) {
                    if connection.isVideoMirroringSupported && device.position == .front {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = true
                    }
                }
            }
            
            // Update state and observers
            self.updateUltraWideAvailability(for: device.position)
            self.observeDevice(device)
            
            do {
                try self.configureFrameRate(device: device, frameRate: self.attributes.frameRate)
            } catch {
                print("Error configuring frame rate: \(error.localizedDescription)")
            }
            
        } else {
            // Failure: Roll back to the old input to prevent a black screen
            if let oldInput = oldInput, self.session.canAddInput(oldInput) {
                self.session.addInput(oldInput)
            }
            
            DispatchQueue.main.async {
                self.cameraErrors = .cannotSetupInput
            }
            throw NSError(domain: "CameraManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add input to session."])
        }
    }}

// MARK: - Camera Controls

extension CameraManager {
    
    public func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            
            let newPositionEnum = self.attributes.cameraPosition == .back ? CameraPosition.front : .back
            let avPosition: AVCaptureDevice.Position = newPositionEnum == .back ? .back : .front
            
            DispatchQueue.main.async {
                self.attributes.cameraPosition = newPositionEnum
            }
            
            guard let newDevice = try? self.findDevice(position: avPosition) else {
                print("Could not find camera for the new position.")
                return
            }
            
            do {
                try self.setDeviceInput(newDevice)
                self.setZoom(1)
            } catch {
                print("Error setting up new camera input: \(error.localizedDescription)")
            }
        }
    }
    
    internal func switchLensType() {
        let newLensType = self.attributes.lensType == .wide ? CameraLensType.ultraWide : .wide
        switchLensType(to: newLensType)
    }
    
    internal func switchLensType(to newLensType: CameraLensType) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 1.0 is ultra-wide and 2.0 is wide on a hybrid device
            let targetZoom: CGFloat = newLensType == .ultraWide ? 1.0 : 2.0
            
            // Try automatic switching via zoom if the current device is a hybrid
            if let device = self.currentInput?.device,
               device.activeFormat.videoMaxZoomFactor >= targetZoom {
                
                self.setZoom(targetZoom)
                print("Switched to \(newLensType.displayName) lens using hybrid zoom")
                return
            }
            
            // Fallback to manual device switching if zoom is not supported
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            
            if let currentInput = self.currentInput {
                self.session.removeInput(currentInput)
            }
            
            DispatchQueue.main.async {
                self.attributes.lensType = newLensType
            }
            
            let position: AVCaptureDevice.Position = self.attributes.cameraPosition == .back ? .back : .front
            let deviceType = newLensType.deviceType
            
            guard let newDevice = AVCaptureDevice.default(deviceType, for: .video, position: position) else {
                print("\(newLensType.displayName) camera not available, reverting to previous lens")
                let revertedLensType = newLensType == .wide ? CameraLensType.ultraWide : .wide
                DispatchQueue.main.async {
                    self.attributes.lensType = revertedLensType
                }
                
                let fallbackDeviceType = revertedLensType.deviceType
                guard let fallbackDevice = AVCaptureDevice.default(fallbackDeviceType, for: .video, position: position) else {
                    return
                }
                
                do {
                    let newInput = try AVCaptureDeviceInput(device: fallbackDevice)
                    if self.session.canAddInput(newInput) {
                        self.session.addInput(newInput)
                        self.currentInput = newInput
                    }
                } catch {
                    print("Error reverting camera: \(error.localizedDescription)")
                }
                return
            }
            
            do {
                let newInput = try AVCaptureDeviceInput(device: newDevice)
                
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.currentInput = newInput
                    print("Switched to \(newLensType.displayName) camera device")
                }
            } catch {
                print("Error switching lens: \(error.localizedDescription)")
            }
        }
    }
    
    public func pauseCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
                DispatchQueue.main.async {
                    self.attributes.isPaused = true
                    print("Camera session paused.")
                }
            }
        }
    }
    
    public func resumeCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning {
                // Restore camera input if it was lost (e.g. after interruption),
                // preserving the saved front/back position from attributes
                if self.currentInput == nil {
                    self.setUpSessionOnQueue()
                }
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.attributes.isPaused = false
                    print("Camera session resumed.")
                }
            }
        }
    }
    
    public nonisolated func stopCamera() {
        sessionQueue.async { [weak self] in
            if self?.session.isRunning == true {
                self?.session.stopRunning()
            }
            self?.zoomObservation?.invalidate()
            self?.lensObservation?.invalidate()
        }
    }
    
    public func startCamera() {
        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }
}

// MARK: - Zoom Conversion Helpers

extension CameraManager {
    
    private func getAVZoomFactor(from uiZoom: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            let multiplier = device.displayVideoZoomFactorMultiplier
            if multiplier > 0 {
                return uiZoom / multiplier
            }
        }
        
        if device.deviceType == .builtInDualWideCamera || device.deviceType == .builtInTripleCamera {
            return uiZoom * 2.0
        }
        return uiZoom
    }
    
    private func getUIZoomFactor(from avZoom: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            return avZoom * device.displayVideoZoomFactorMultiplier
        }
        
        if device.deviceType == .builtInDualWideCamera || device.deviceType == .builtInTripleCamera {
            return avZoom / 2.0
        }
        return avZoom
    }
}

// MARK: - Capture Operations

extension CameraManager {
    
    public func takePicture() {
        guard session.isRunning else {
            print("Attempted to take picture while session is not running.")
            return
        }
        
        guard let connection = output.connection(with: .video), connection.isActive else {
            print("No active video connection, skipping photo capture to avoid crash.")
            return
        }
        
        let settings = AVCapturePhotoSettings()
        
        if let device = currentInput?.device {
            if device.hasFlash {
                switch attributes.flashMode {
                case .off:
                    settings.flashMode = .off
                case .on:
                    settings.flashMode = .on
                case .auto:
                    settings.flashMode = .auto
                }
            }
        }
        
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        
        if #available(iOS 18.0, *) {
            settings.isShutterSoundSuppressionEnabled = attributes.suppressShutterSound
        }
        
        output.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - Configuration

extension CameraManager {
    
    public func switchFlash() {
        switch attributes.flashMode {
        case .off:
            attributes.flashMode = .auto
        case .auto:
            attributes.flashMode = .on
        case .on:
            attributes.flashMode = .off
        }
    }
    
    public func switchFlash(to mode: CameraFlashMode) {
        attributes.flashMode = mode
    }
    
    public func toggleFlash() {
        if attributes.flashMode == .on {
            attributes.flashMode = .off
        } else {
            attributes.flashMode = .on
        }
    }
    
    public func setZoom(_ uiFactor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentInput?.device else { return }
            
            let targetVideoZoom = getAVZoomFactor(from: uiFactor, for: device)

            let configuredMaxFactor = getAVZoomFactor(from: attributes.maxZoomFactor, for: device)

            let hardwareLimit = device.activeFormat.videoMaxZoomFactor
            let effectiveMaxFactor = min(hardwareLimit, configuredMaxFactor)

            let finalClampedFactor = min(max(targetVideoZoom, device.minAvailableVideoZoomFactor), effectiveMaxFactor)

            do {
                try device.lockForConfiguration()

                device.videoZoomFactor = finalClampedFactor
                device.unlockForConfiguration()
            } catch {
                print("Error setting zoom: \(error.localizedDescription)")
            }
        }
    }
    
    public func setZoomAnimated(_ uiFactor: CGFloat, duration: TimeInterval = 0.001) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentInput?.device else { return }
            
            let targetVideoZoom = getAVZoomFactor(from: uiFactor, for: device)

            let configuredMaxFactor = getAVZoomFactor(from: attributes.maxZoomFactor, for: device)

            let hardwareLimit = device.activeFormat.videoMaxZoomFactor
            let effectiveMaxFactor = min(hardwareLimit, configuredMaxFactor)

            let finalClampedFactor = min(max(targetVideoZoom, device.minAvailableVideoZoomFactor), effectiveMaxFactor)

            do {
                try device.lockForConfiguration()

                if duration <= 0 {
                    device.videoZoomFactor = finalClampedFactor
                } else {
                    let difference = abs(Float(finalClampedFactor - device.videoZoomFactor))
                    let rate = difference / Float(duration)
                    
                    if rate > 0 {
                        device.ramp(toVideoZoomFactor: finalClampedFactor, withRate: rate)
                    }
                }
                
                device.unlockForConfiguration()
            } catch {
                print("Error setting animated zoom: \(error.localizedDescription)")
            }
        }
    }
    
    public func setFrameRate(_ frameRate: Int32) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentInput?.device else { return }
            
            do {
                try self.configureFrameRate(device: device, frameRate: frameRate)
                DispatchQueue.main.async {
                    self.attributes.frameRate = device.activeVideoMinFrameDuration.timescale
                }
            } catch {
                print("Error setting frame rate: \(error.localizedDescription)")
            }
        }
    }
    
    private func configureFrameRate(device: AVCaptureDevice, frameRate: Int32) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        
        print("Attempting to set frame rate to \(frameRate) fps...")
        
        var bestFormat: AVCaptureDevice.Format?
        let currentDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        
        if let format = device.formats.first(where: { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == currentDimensions.width &&
            dimensions.height == currentDimensions.height &&
            format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= Double(frameRate) })
        }) {
            bestFormat = format
        }
        else if let format = device.formats
            .sorted(by: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width > CMVideoFormatDescriptionGetDimensions($1.formatDescription).width })
            .first(where: { $0.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= Double(frameRate) })
            }) {
            bestFormat = format
        }
        
        if let format = bestFormat {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            print("Selected format: \(dimensions.width)x\(dimensions.height) for \(frameRate) fps")
            
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            
            print("Frame rate successfully set.")
        } else {
            print("No format found that supports \(frameRate) fps. The device may not support this frame rate. Current format will be kept.")
        }
    }
}

// MARK: - Utilities

extension CameraManager {
    
    internal func checkUltraWideAvailable() -> Bool {
        let position: AVCaptureDevice.Position = attributes.cameraPosition == .back ? .back : .front
        return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) != nil
    }
}

// MARK: - Photo Capture Delegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        
        guard let imageData = photo.fileDataRepresentation() else {
            print("Error getting image data")
            return
        }
        
        guard let image = UIImage(data: imageData) else {
            print("Error creating UIImage from data")
            return
        }
        
        let metadata = photo.metadata
        let cameraMedia = CameraMedia(
            image: image,
            metadata: metadata,
            timestamp: Date()
        )
        capturedMedia = cameraMedia
    }
}

// MARK: - Computed Properties

extension CameraManager {
    
    public var flashMode: CameraFlashMode {
        get { attributes.flashMode }
        set { attributes.flashMode = newValue }
    }
    
    private var isFrontCamera: Bool {
        attributes.cameraPosition == .front
    }
    
    public var isUltraWideAvailable: Bool {
        attributes.isUltraWideAvailable
    }
    
    public var zoomFactor: CGFloat {
        attributes.zoomFactor
    }
    
    public var lensType: CameraLensType {
        attributes.lensType
    }
    
    public var maxZoomFactor: CGFloat {
        get { attributes.maxZoomFactor }
        set { attributes.maxZoomFactor = newValue }
    }
}
