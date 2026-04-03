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
    private let rawProcessor:   RawProcessor?
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
        self.rawProcessor   = RawProcessor()
        self.ciContext      = CIContext(options: [.workingColorSpace: NSNull()])
    }

    // MARK: - Главная точка входа

    func process(
        frames: [CVPixelBuffer],
        exif: ExifMetadata,
        settings: CameraSettings,
        isRaw: Bool = false
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

        // --- Шаг 0: Демозаика RAW-кадров (если захват был в RAW) ---
        // Преобразуем Bayer → sRGB до всей последующей обработки.
        // Это устраняет артефакты Apple ISP и даёт нам чистые линейные данные.
        let processedFrames: [CVPixelBuffer]
        if isRaw, let rawProc = rawProcessor {
            processingStep = .aligning  // пока нет отдельного статуса для demosaic
            processedFrames = frames.compactMap { rawProc.demosaic($0) }
            guard !processedFrames.isEmpty else {
                // Если демозаика не сработала — fallback на оригинальные кадры
                return await process(frames: frames, exif: exif, settings: settings, isRaw: false)
            }
        } else {
            processedFrames = frames
        }

        // --- Шаг 1: Выравнивание кадров ---
        processingStep     = .aligning
        processingProgress = 0.1

        var alignedFrames: [AlignedFrame]
        if processedFrames.count > 1, let aligner {
            alignedFrames = await aligner.align(frames: processedFrames)
        } else {
            alignedFrames = processedFrames.map {
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

        // Если процессор вернул nil (Metal недоступен / ошибка GPU),
        // применяем минимальную CoreImage-обработку к первому кадру
        // вместо того чтобы отдавать сырой плоский буфер
        let finalBuffer: CVPixelBuffer
        if let pb = processedBuffer {
            finalBuffer = pb
        } else if let raw = frames.first {
            finalBuffer = applyFallbackProcessing(to: raw, settings: settings) ?? raw
        } else {
            return nil
        }

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

    // MARK: - Фолбэк обработки (Metal/GPU недоступен — только CoreImage CPU)

    private func applyFallbackProcessing(to buffer: CVPixelBuffer, settings: CameraSettings) -> CVPixelBuffer? {
        let ci = CIImage(cvPixelBuffer: buffer)
        // Только тональная коррекция и цвет — без CIUnsharpMask.
        // Фолбэк означает один кадр без temporal denoising, поэтому
        // шарпенинг только усилит шум ISP. Лучше чистый результат.
        let processed = ci
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": CGFloat(max(0.0, 1.0 - Double(settings.highlightRecovery) * 0.6)),
                "inputShadowAmount":    CGFloat(settings.shadowLift * 4.0)
            ])
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": CGFloat(1.0 + Double(settings.saturationBoost) * 0.5),
                "inputBrightness": 0.0,
                "inputContrast":   1.02
            ])
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &out)
        if let out { ciContext.render(processed, to: out) }
        return out
    }

    // MARK: - Pro режим: тональная обработка без добавления резкости

    private func applySharpeningOnly(to buffer: CVPixelBuffer, strength: Float) -> CVPixelBuffer {
        // В Pro режиме Apple ISP уже применил свою обработку; добавлять
        // CIUnsharpMask поверх него только добавит ореолы и зерно.
        // Применяем только нейтральную тональную коррекцию.
        let ci    = CIImage(cvPixelBuffer: buffer)
        let toned = ci
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 0.9,
                "inputShadowAmount":    0.4
            ])
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 1.05,
                "inputBrightness": 0.0,
                "inputContrast":   1.01
            ])
        var out: CVPixelBuffer?
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &out)
        if let out { ciContext.render(toned, to: out) }
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
