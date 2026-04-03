// CameraManager.swift — управление AVFoundation сессией

import AVFoundation
import UIKit
import Combine

@MainActor
final class CameraManager: NSObject, ObservableObject {

    // MARK: - Публикуемое состояние для UI
    @Published var isSessionRunning   = false
    @Published var isCapturing        = false
    @Published var captureProgress: Float = 0.0
    @Published var currentISO: Float  = 100
    @Published var currentShutter: Double = 1.0 / 60.0
    @Published var currentAperture: Double = 1.8
    @Published var lightLevel: Float  = 0.5
    @Published var nightModeSuggested = false
    @Published var zoomFactor: CGFloat = 1.0
    @Published var availableZoomStops: [CGFloat] = [1.0]
    /// Зум-фактор устройства, соответствующий оптическому 1× (главный модуль)
    @Published var baseZoomFactor: CGFloat = 1.0

    // MARK: - AVFoundation
    let session = AVCaptureSession()
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private var deviceInput: AVCaptureDeviceInput?
    let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()

    // Безопасное хранилище для делегата видеопотока (nonisolated-контекст)
    nonisolated(unsafe) private var liveDevice: AVCaptureDevice?

    // MARK: - Внутренние очереди
    private let sessionQueue  = DispatchQueue(label: "lcam.session",  qos: .userInitiated)
    private let metaQueue     = DispatchQueue(label: "lcam.meta",     qos: .utility)

    // MARK: - Зависимости
    private let pipeline: PostProcessingPipeline
    var settings: CameraSettings?

    // Коллбэк — вызывается когда фото готово
    var onPhoto: ((PhotoResult) -> Void)?
    var onError: ((String) -> Void)?

    // Текущий бёрст-захват
    private var activeBurst: BurstCapture?

    // MARK: - Init
    init(settings: CameraSettings, pipeline: PostProcessingPipeline) {
        self.settings = settings
        self.pipeline = pipeline
        super.init()
    }

    // MARK: - Настройка сессии
    func configure() {
        // Сначала запрашиваем разрешение — без него сессия стартует "вхолостую"
        // и prevIEW остаётся чёрным (даже если OS показывает зелёную точку)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                self.configureAndStart()
            }
        }
    }

    private func configureAndStart() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        addCameraInput(position: .back)
        addPhotoOutput()
        addVideoDataOutput()

        session.commitConfiguration()
        session.startRunning()

        Task { @MainActor in
            self.isSessionRunning = self.session.isRunning
            self.detectZoomStops() // устанавливает baseZoomFactor и setZoom внутри
        }
    }

    // Выбираем лучшую доступную камеру: Triple → Dual Wide → Dual → Wide
    private func addCameraInput(position: AVCaptureDevice.Position) {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]

        guard let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: position
        ).devices.first else {
            onError?("Camera not found")
            return
        }

        configureDevice(device)
        liveDevice = device

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                deviceInput = input
            }
        } catch {
            onError?("Input error: \(error.localizedDescription)")
        }
    }

    // Базовая конфигурация устройства при старте
    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        } catch {}
    }

    private func addPhotoOutput() {
        guard session.canAddOutput(photoOutput) else { return }
        session.addOutput(photoOutput)
        photoOutput.isHighResolutionCaptureEnabled = true
        photoOutput.maxPhotoQualityPrioritization = .quality

        // Активируем LivePhoto и Portrait если поддерживаются
        if photoOutput.isLivePhotoCaptureSupported {
            photoOutput.isLivePhotoCaptureEnabled = false // отключаем для скорости бёрста
        }
    }

    private func addVideoDataOutput() {
        videoDataOutput.setSampleBufferDelegate(self, queue: metaQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }
    }

    // Определяем стопы зума и координату 1× через constituentDevices —
    // единственный надёжный API: каждый физический модуль имеет deviceType,
    // по которому находим builtInWideAngleCamera = "главный = 1×".
    // constituentDevices упорядочены от широкого к узкому, как switchFactors.
    private func detectZoomStops() {
        guard let device = deviceInput?.device else { return }

        let minZoom       = device.minAvailableVideoZoomFactor
        let maxZoom       = device.maxAvailableVideoZoomFactor
        let switchFactors = device.virtualDeviceSwitchOverVideoZoomFactors
            .map { CGFloat($0.doubleValue) }

        let constituents  = device.constituentDevices

        // Строим таблицу: физический модуль → зум-фактор старта
        // constituent[0] стартует на minZoom, [1] на switchFactors[0], [2] на switchFactors[1]…
        var zoomForIndex: [CGFloat] = [minZoom]
        zoomForIndex += switchFactors

        // Ищем индекс буiltInWideAngleCamera в отсортированном массиве
        let wideIdx = constituents.firstIndex { $0.deviceType == .builtInWideAngleCamera }

        let wideZoom: CGFloat
        if let idx = wideIdx, idx < zoomForIndex.count {
            wideZoom = zoomForIndex[idx]
        } else {
            // Fallback: нет составных устройств (одиночная камера)
            wideZoom = 1.0
        }

        // Стопы = minZoom + все switchFactors, обрезанные до maxZoom
        var stops: [CGFloat] = [minZoom] + switchFactors.filter { $0 <= maxZoom }
        // Дедупликация и сортировка
        stops = Array(Set(stops)).sorted()

        availableZoomStops = stops
        baseZoomFactor     = wideZoom
        // animated: false — мгновенно, иначе ramp() занимает секунды
        // и фото снимается до окончания анимации (= на 0.5x UW)
        setZoom(wideZoom, animated: false)
    }

    // MARK: - Зум
    func setZoom(_ factor: CGFloat, animated: Bool = true) {
        guard let device = deviceInput?.device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minAvailableVideoZoomFactor,
                                  min(factor, device.maxAvailableVideoZoomFactor))
                if animated {
                    device.ramp(toVideoZoomFactor: clamped, withRate: 16.0)
                } else {
                    device.videoZoomFactor = clamped
                }
                device.unlockForConfiguration()
                Task { @MainActor in self.zoomFactor = factor }
            } catch {}
        }
    }

    func zoomIn()  { setZoom(zoomFactor * 1.5) }
    func zoomOut() { setZoom(zoomFactor / 1.5) }

    // Пинч-жест → плавное изменение зума
    func handlePinch(scale: CGFloat, baseZoom: CGFloat) {
        setZoom(baseZoom * scale, animated: false)
    }

    // MARK: - Фокус и экспозиция по касанию
    func focusAndExpose(at viewPoint: CGPoint, layerSize: CGSize) {
        guard let device = deviceInput?.device,
              let layer = previewLayer else { return }

        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: viewPoint)

        sessionQueue.async {
            do {
                try device.lockForConfiguration()

                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }

                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }

                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Экспокоррекция
    func setExposureBias(_ bias: Float) {
        guard let device = deviceInput?.device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minExposureTargetBias,
                                  min(bias, device.maxExposureTargetBias))
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Переключение камеры
    func switchCamera() {
        let newPos: AVCaptureDevice.Position = deviceInput?.device.position == .back ? .front : .back
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let current = self.deviceInput { self.session.removeInput(current) }
            self.addCameraInput(position: newPos)
            self.session.commitConfiguration()
        }
    }

    // MARK: - Съёмка
    func capturePhoto() {
        guard !isCapturing, let settings else { return }

        isCapturing     = true
        captureProgress = 0.0

        let frameCount = settings.captureMode.burstFrameCount(lightLevel: lightLevel)

        // BurstCapture — захватывает N кадров, возвращает CVPixelBuffer[]
        let burst = BurstCapture(
            photoOutput: photoOutput,
            targetFrames: frameCount,
            settings: settings
        )
        activeBurst = burst

        burst.start(
            progress: { [weak self] p in
                Task { @MainActor in self?.captureProgress = p }
            },
            completion: { [weak self] frames, exif in
                guard let self else { return }
                Task { await self.runPipeline(frames: frames, exif: exif, settings: settings) }
            }
        )
    }

    private func runPipeline(frames: [CVPixelBuffer], exif: ExifMetadata, settings: CameraSettings) async {
        let result = await pipeline.process(frames: frames, exif: exif, settings: settings)
        await MainActor.run {
            self.isCapturing     = false
            self.captureProgress = 0.0
            self.activeBurst     = nil
            if let result { self.onPhoto?(result) }
        }
    }

    // MARK: - Жизненный цикл
    func stop() {
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }

    func resume() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            Task { @MainActor in self.isSessionRunning = self.session.isRunning }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
// Извлекаем метаданные из видеопотока: ISO, выдержка → уровень освещённости
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let device = liveDevice else { return }

        let iso        = device.iso
        let duration   = device.exposureDuration
        let shutterSec = CMTimeGetSeconds(duration)
        let aperture   = Double(device.lensAperture)

        // Оцениваем освещённость: EV₁₀₀ = log2(f² / t / (ISO/100))
        let ev100 = log2(aperture * aperture / max(shutterSec, 1e-6)) - log2(Double(iso) / 100.0)
        // EV100 диапазон: -4 (ночь) .. 16 (яркое солнце) → нормализуем к [0..1]
        let normalised = Float(min(max((ev100 + 4.0) / 20.0, 0.0), 1.0))

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentISO     = iso
            self.currentShutter = shutterSec
            self.currentAperture = aperture
            self.lightLevel      = normalised
            self.nightModeSuggested = normalised < 0.18
            self.settings?.currentLightLevel  = normalised
            self.settings?.nightModeSuggested = normalised < 0.18
        }
    }
}
