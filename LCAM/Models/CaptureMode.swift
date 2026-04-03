// CaptureMode.swift — режимы съёмки LCAM

import Foundation

// Режимы съёмки: от автомата до полного ручного
enum CaptureMode: String, CaseIterable, Identifiable {
    case auto     = "AUTO"
    case hdrPlus  = "HDR+"
    case night    = "NIGHT"
    case portrait = "PORTRAIT"
    case pro      = "PRO"
    case video    = "VIDEO"

    var id: String { rawValue }

    // Иконка SF Symbols для каждого режима
    var symbol: String {
        switch self {
        case .auto:     return "sparkles"
        case .hdrPlus:  return "sun.max.trianglebadge.exclamationmark"
        case .night:    return "moon.stars.fill"
        case .portrait: return "person.crop.circle"
        case .pro:      return "slider.horizontal.3"
        case .video:    return "video.fill"
        }
    }

    // Сколько кадров захватывать в бёрст-режиме
    func burstFrameCount(lightLevel: Float) -> Int {
        switch self {
        case .auto:
            // Меньше кадров в светлое время = меньше риска смаза от неточного alignment
            switch lightLevel {
            case 0.0..<0.05:  return 20
            case 0.05..<0.15: return 12
            case 0.15..<0.3:  return 6
            case 0.3..<0.6:   return 4
            default:          return 2
            }
        case .hdrPlus:  return 12
        case .night:    return 30
        case .portrait: return 6
        case .pro:      return 1
        case .video:    return 1
        }
    }

    // Нужен ли ночной режим обработки
    var requiresNightProcessing: Bool {
        self == .night
    }

    // Использовать максимальное качество обработки
    var maximumQuality: Bool {
        self == .hdrPlus || self == .night || self == .portrait
    }
}

// Мощность ISO-независимого шума: модель для взвешивания кадров при слиянии
struct NoiseModel {
    // σ² = readNoise² + shotNoiseFactor * signal
    // Параметры откалиброваны под типичный iPhone сенсор
    let readNoiseSigmaSquared: Float  // постоянный шум считывания
    let shotNoiseFactor: Float        // фотонный (дробовой) шум

    static let iPhoneDefault = NoiseModel(
        readNoiseSigmaSquared: 1.5e-4,
        shotNoiseFactor: 3.0e-4
    )

    // Ожидаемая дисперсия пикселя с данным значением [0..1]
    func variance(for signal: Float) -> Float {
        return readNoiseSigmaSquared + shotNoiseFactor * signal
    }

    // Вес кадра для слияния — обратно пропорционален дисперсии
    func mergeWeight(signal: Float, delta: Float) -> Float {
        let sigma2 = variance(for: signal)
        // Дополнительный штраф за разницу с опорным кадром (детекция движения)
        let motionPenalty = delta * delta / (2.0 * sigma2 * 4.0)
        return exp(-motionPenalty) / sigma2
    }
}
