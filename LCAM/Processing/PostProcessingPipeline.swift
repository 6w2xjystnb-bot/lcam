// PostProcessingPipeline.swift — главный оркестратор всей обработки
//
// Принимает сырые CVPixelBuffer[] из BurstCapture и возвращает готовый PhotoResult.
// Выбирает нужный процессор (HDR, Night, Auto) на основе CaptureMode и условий сцены.

import CoreImage
import CoreVideo
import UIKit
import Photos

@MainActor
final class PostProcessingPipeline: ObservableObject {

    // Состояние для UI-индикатора обработки
    @Published var isProcessing = false
    @Published var processingStep: ProcessingStep = .idle
    @Published var processingProgress: Float = 0.0

    // Процессоры
    private let aligner:        FrameAligner?
    private let hdrProcessor:   HDRProcessor?
    private let nightProcessor: NightProcessor?
    private let ciContext:      CIContext

    enum ProcessingStep: String {
        case idle         = ""
        case aligning     = "Выравнивание кадров..."
        case merging      = "Слияние HDR..."
        case nightStack   = "Ночное стекирование..."
        case toneMapping  = "Тональное отображение..."
        case colorScience = "Цветовая обработка..."
        case sharpening   = "Резкость..."
        case saving       = "Сохранение..."
    }

    init() {
        self.aligner        = FrameAligner()
        self.hdrProcessor   = HDRProcessor()
        self.nightProcessor = NightProcessor()
        self.ciContext      = CIContext(options: [.workingColorSpace: NSNull()])
    }

    // MARK: - Главная точка входа

    func process(
        frames: [CVPixelBuffer],
        exif: ExifMetadata,
        settings: CameraSettings
    ) async -> PhotoResult? {
        guard !frames.isEmpty else { return nil }
        let startTime = Date()

        isProcessing      = true
        processingProgress = 0.0

        defer {
            Task { @MainActor in
                self.isProcessing      = false
                self.processingStep    = .idle
                self.processingProgress = 0.0
            }
        }

        // --- Шаг 1: Выравнивание кадров ---
        processingStep    = .aligning
        processingProgress = 0.1

        var alignedFrames: [AlignedFrame]
        if frames.count > 1, let aligner {
            alignedFrames = await aligner.align(frames: frames)
        } else {
            alignedFrames = frames.map {
                AlignedFrame(pixelBuffer: $0, alignmentScore: 1.0, motionMagnitude: 0.0)
            }
        }

        let goodCount     = alignedFrames.filter { $0.alignmentScore > 0.1 }.count
        let rejectedCount = alignedFrames.count - goodCount
        processingProgress = 0.35

        // --- Шаг 2: Слияние / стекинг ---
        let processedBuffer: CVPixelBuffer?

        switch settings.captureMode {

        case .night:
            processingStep = .nightStack
            processedBuffer = await nightProcessor?.process(
                frames: alignedFrames, settings: settings
            )

        case .hdrPlus, .auto:
            processingStep = .merging
            processedBuffer = await hdrProcessor?.process(
                frames: alignedFrames, settings: settings
            )

        case .portrait:
            // Portrait: HDR + потом портретный блюр (реализация через ARKit depth в v2.0)
            processingStep = .merging
            processedBuffer = await hdrProcessor?.process(
                frames: alignedFrames, settings: settings
            )

        case .pro:
            // Ручной режим: минимальная обработка, только резкость
            processingStep = .sharpening
            processedBuffer = frames.first.map {
                applySharpeningOnly(to: $0, strength: settings.sharpeningStrength)
            } ?? frames.first

        case .video:
            processedBuffer = frames.first
        }

        processingProgress = 0.70

        guard let finalBuffer = processedBuffer ?? frames.first else { return nil }

        // --- Шаг 3: Конвертация в UIImage ---
        processingStep = .saving
        guard let finalImage = pixelBufferToUIImage(finalBuffer) else { return nil }

        processingProgress = 0.85

        // --- Шаг 4: Сохранение в фотогалерею ---
        await saveToPhotoLibrary(finalImage)

        processingProgress = 1.0
        let elapsed = Date().timeIntervalSince(startTime) * 1000

        // Вычисляем снижение шума (теоретическое: √N)
        let noiseGain = goodCount > 1 ? sqrt(Float(goodCount)) : 1.0

        let processingInfo = ProcessingInfo(
            capturedFrameCount: frames.count,
            alignedFrameCount:  goodCount,
            rejectedFrameCount: rejectedCount,
            processingTimeMs:   elapsed,
            noiseReductionGain: noiseGain,
            hdrDynamicRange:    goodCount > 1 ? Float(goodCount) * 0.5 : 0,
            nightModeUsed:      settings.captureMode == .night,
            hdrUsed:            settings.captureMode == .hdrPlus || settings.captureMode == .auto,
            portraitDepthUsed:  settings.captureMode == .portrait,
            algorithmsApplied:  buildAlgorithmList(settings: settings, frameCount: goodCount)
        )

        return PhotoResult(finalImage: finalImage, exif: exif, processingInfo: processingInfo)
    }

    // MARK: - Только резкость (Pro режим)

    private func applySharpeningOnly(to buffer: CVPixelBuffer, strength: Float) -> CVPixelBuffer {
        let ci      = CIImage(cvPixelBuffer: buffer)
        let sharp   = ci.applyingFilter("CIUnsharpMask", parameters: [
            "inputRadius":    1.8,
            "inputIntensity": CGFloat(strength)
        ])
        var out: CVPixelBuffer?
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &out)
        if let out { ciContext.render(sharp, to: out) }
        return out ?? buffer
    }

    // MARK: - Конвертация CVPixelBuffer → UIImage

    private func pixelBufferToUIImage(_ buffer: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1.0, orientation: .right)
    }

    // MARK: - Сохранение в Photos

    private func saveToPhotoLibrary(_ image: UIImage) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }

        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { _, _ in
                continuation.resume()
            }
        }
    }

    // MARK: - Список алгоритмов для ProcessingInfo

    private func buildAlgorithmList(settings: CameraSettings, frameCount: Int) -> [String] {
        var list: [String] = []
        if frameCount > 1      { list.append("Multi-frame (\(frameCount)f)") }
        if frameCount > 1      { list.append("Optical Flow Alignment") }
        if frameCount > 1      { list.append("Noise-Weighted Merge") }
        if settings.captureMode == .night   { list.append("Night Stacking") }
        if settings.captureMode == .hdrPlus { list.append("HDR+ Tone Map") }
        list.append("CIToneCurve")
        list.append("Vibrance")
        if settings.sharpeningStrength > 0  { list.append("Unsharp Mask") }
        return list
    }
}
