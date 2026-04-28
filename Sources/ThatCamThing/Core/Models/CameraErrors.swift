//
//  File.swift
//  ThatCamThing
//
//  Created by angel zambrano on 7/3/25.
//
import Foundation
import SwiftUI
import PhotosUI
import AVFoundation
import AVKit

// MARK: - Core Models and Enums

public enum CameraError: Error, Equatable {
    case cameraPermissionsNotGranted
    case cannotSetupInput, cannotSetupOutput
    /// The device doesn't support simultaneous camera use across multiple windows.
    /// The camera will resume automatically when the competing window is closed.
    case multitaskingNotSupported
}
