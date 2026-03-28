//
//  CameraError.swift
//  ThatCamThing
//
//  Created by angel zambrano on 7/2/25.
//
import Foundation
import SwiftUI
import PhotosUI
import AVFoundation
import AVKit


public enum CameraOutputType: CaseIterable {
    case photo
}

public enum CameraPosition: CaseIterable, Sendable {
    case back
    case front
}

public enum CameraFlashMode: CaseIterable {
    case off
    case on
    case auto
}

public enum CameraHDRMode: CaseIterable {
    case off
    case on
    case auto
}

public enum CameraLensType: CaseIterable, Sendable {
    case wide
    case ultraWide
    case telephoto
    
    public var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide:
            return .builtInWideAngleCamera
        case .ultraWide:
            return .builtInUltraWideCamera
        case .telephoto:
            return .builtInTelephotoCamera
        }
    }
    
    public var displayName: String {
        switch self {
        case .wide:
            return "Wide"
        case .ultraWide:
            return "Ultra Wide"
        case .telephoto:
            return "Telephoto"
        }
    }
}

public enum FrameRate {
    case fps15
    case fps24
    case fps30
    case fps60
    case fps120

   public var asInt32: Int32 {
        switch self {
        case .fps15: return 15
        case .fps24: return 24
        case .fps30: return 30
        case .fps60: return 60
        case .fps120: return 120
        }
    }
}

public struct CameraManagerAttributes {
    public var outputType = CameraOutputType.photo
    public var cameraPosition = CameraPosition.back
    public var zoomFactor: CGFloat = 1.0
    public var frameRate: Int32 = 30
    public var flashMode = CameraFlashMode.off
    public var resolution = AVCaptureSession.Preset.hd1920x1080
    public var lensType = CameraLensType.wide
    public var isPaused = false
    public var isUltraWideAvailable = false
    public var maxZoomFactor: CGFloat = 10
    public var suppressShutterSound = false
    public var mirrorFrontOutput = false
    public var qualityPrioritization: AVCapturePhotoOutput.QualityPrioritization = .quality
    
    public init(
        outputType: CameraOutputType = .photo,
        cameraPosition: CameraPosition = .back,
        zoomFactor: CGFloat = 1.0,
        frameRate: FrameRate = .fps30,
        flashMode: CameraFlashMode = .off,
        resolution: AVCaptureSession.Preset = .hd1920x1080,
        lensType: CameraLensType = .wide,
        isPaused: Bool = false,
        isUltraWideAvailable: Bool = false,
        maxZoomFactor: CGFloat = 10,
        suppressShutterSound: Bool = false,
        mirrorFrontOutput: Bool = false,
        qualityPrioritization: AVCapturePhotoOutput.QualityPrioritization = .quality
    ) {
        self.outputType = outputType
        self.cameraPosition = cameraPosition
        self.zoomFactor = zoomFactor
        self.frameRate = frameRate.asInt32
        self.flashMode = flashMode
        self.resolution = resolution
        self.lensType = lensType
        self.isPaused = isPaused
        self.isUltraWideAvailable = false
        self.maxZoomFactor = maxZoomFactor
        self.suppressShutterSound = suppressShutterSound
        self.mirrorFrontOutput = mirrorFrontOutput
        self.qualityPrioritization = qualityPrioritization
    }
}
