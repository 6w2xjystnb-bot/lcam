// CameraSettings.swift — настройки камеры, синхронизированные с UI

import SwiftUI
import AVFoundation
import Combine

// Главная модель настроек — ObservableObject для привязки к SwiftUI
@MainActor
final class CameraSettings: ObservableObject {

    // --- Режим съёмки ---
    @Published var captureMode: CaptureMode = .auto

    // --- Базовые управляющие параметры ---
    @Published var zoomFactor: CGFloat = 1.0           // текущий зум
    @Published var exposureBias: Float = 0.0           // экспокоррекция [-3..+3 EV]
    @Published var focusPoint: CGPoint? = nil          // nil = автофокус по центру

    // --- Ручной режим (PRO) ---
    @Published var manualISO: Float = 100              // ISO [25..6400]
    @Published var manualShutterSpeed: Double = 1/60   // выдержка в секундах
    @Published var manualWhiteBalance: Float = 5500    // температура в Кельвинах
    @Published var manualFocusDistance: Float = 0.5    // [0..1] (inf → near)

    // --- Параметры обработки ---
    @Published var processingStrength: Float = 0.85    // агрессивность обработки [0..1]
    @Published var sharpeningStrength: Float = 0.5
    @Published var noiseReductionStrength: Float = 0.7
    @Published var saturationBoost: Float = 0.12       // небольшой буст насыщенности как в GCam
    @Published var shadowLift: Float = 0.08            // подъём теней
    @Published var highlightRecovery: Float = 0.6      // восстановление пересвета

    // --- Вспышка и вспомогательное ---
    @Published var flashMode: AVCaptureDevice.FlashMode = .auto
    @Published var torchEnabled: Bool = false
    @Published var isGridEnabled: Bool = false
    @Published var isLevelEnabled: Bool = false
    @Published var mirrorFrontCamera: Bool = true

    // --- Видео ---
    @Published var videoResolution: VideoResolution = .uhd4K
    @Published var videoFrameRate: VideoFrameRate = .fps30
    @Published var videoStabilization: Bool = true

    // --- Выбор камеры ---
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var lensType: LensType = .mainWide

    // Доступные зум-стопы (зависят от устройства, заполняются при старте)
    @Published var availableZoomStops: [CGFloat] = [0.5, 1.0, 2.0, 5.0]

    // Текущий уровень освещённости (0..1), измеряется из AVCaptureDevice
    @Published var currentLightLevel: Float = 0.5

    // Предложение ночного режима
    @Published var nightModeSuggested: Bool = false

    // --- Постоянные пользовательские настройки (сохраняются в UserDefaults) ---
    @AppStorage("savedSaturationBoost") var savedSaturationBoost: Double = 0.12
    @AppStorage("savedProcessingStrength") var savedProcessingStrength: Double = 0.85
    @AppStorage("savedSharpeningStrength") var savedSharpeningStrength: Double = 0.5
    @AppStorage("enableRAWCapture") var enableRAWCapture: Bool = false
    @AppStorage("saveOriginalFrame") var saveOriginalFrame: Bool = false
    @AppStorage("heifFormat") var useHEIF: Bool = true

    // Загрузить сохранённые настройки
    func loadPersisted() {
        saturationBoost = Float(savedSaturationBoost)
        processingStrength = Float(savedProcessingStrength)
        sharpeningStrength = Float(savedSharpeningStrength)
    }

    // Сохранить текущие настройки
    func persist() {
        savedSaturationBoost = Double(saturationBoost)
        savedProcessingStrength = Double(processingStrength)
        savedSharpeningStrength = Double(sharpeningStrength)
    }
}

// Разрешение видео
enum VideoResolution: String, CaseIterable {
    case hd1080p  = "1080p"
    case uhd4K    = "4K"
    case uhd4K60  = "4K 60fps"
    case hd720p   = "720p"

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd720p:  return .hd1280x720
        case .hd1080p: return .hd1920x1080
        case .uhd4K, .uhd4K60: return .hd4K3840x2160
        }
    }
}

// Частота кадров видео
enum VideoFrameRate: Int, CaseIterable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var displayName: String { "\(rawValue) fps" }
}

// Тип линзы / угол обзора
enum LensType: String, CaseIterable {
    case ultraWide = "Ultra Wide"
    case mainWide  = "Wide"
    case tele2x    = "2×"
    case tele5x    = "5×"

    var zoomFactor: CGFloat {
        switch self {
        case .ultraWide: return 0.5
        case .mainWide:  return 1.0
        case .tele2x:    return 2.0
        case .tele5x:    return 5.0
        }
    }

    var symbol: String {
        switch self {
        case .ultraWide: return "0.5×"
        case .mainWide:  return "1×"
        case .tele2x:    return "2×"
        case .tele5x:    return "5×"
        }
    }
}
