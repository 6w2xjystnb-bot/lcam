// CameraView.swift — главный экран камеры
// Вьюфайндер + верхняя строка инфо + нижняя панель управления
// Дизайн: Liquid Glass iOS 26

import SwiftUI
import AVFoundation

struct CameraView: View {

    @EnvironmentObject var settings:  CameraSettings
    @EnvironmentObject var pipeline:  PostProcessingPipeline
    @EnvironmentObject var gallery:   GalleryStore

    // CameraManager создаётся здесь и живёт вместе с CameraView
    @StateObject private var camera: CameraManager = {
        let s = CameraSettings()
        let p = PostProcessingPipeline()
        return CameraManager(settings: s, pipeline: p)
    }()

    // UI состояние
    @State private var focusPoint:       CGPoint? = nil
    @State private var showFocusSquare  = false
    @State private var showGallery      = false
    @State private var showSettings     = false
    @State private var baseZoomForPinch: CGFloat = 1.0
    @State private var nightModeBanner  = false

    // Доступ к реальному размеру экрана
    @State private var viewSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {

                // ── ВЬЮФАЙНДЕР ──────────────────────────────────────────
                ViewfinderView(session: camera.session) { tapPoint in
                    handleTap(at: tapPoint, size: geo.size)
                }
                .ignoresSafeArea()

                // Фокусировочный квадрат
                if showFocusSquare, let fp = focusPoint {
                    FocusSquareView(point: fp, isVisible: $showFocusSquare)
                }

                // ── ВЕРХНЯЯ СТРОКА INFO ──────────────────────────────────
                VStack {
                    topBar
                        .padding(.top, geo.safeAreaInsets.top + 8)
                        .padding(.horizontal, 20)

                    // Баннер "Ночной режим"
                    if nightModeBanner {
                        NightModeBanner()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer()

                    // Баннер обработки
                    if pipeline.isProcessing {
                        ProcessingBanner(
                            step:     pipeline.processingStep,
                            progress: pipeline.processingProgress
                        )
                        .padding(.bottom, 12)
                        .transition(.opacity)
                    }
                }

                // ── НИЖНЯЯ ПАНЕЛЬ УПРАВЛЕНИЯ ─────────────────────────────
                ControlsView(camera: camera) {
                    showGallery = true
                }
                .environmentObject(settings)
                .environmentObject(gallery)
            }
            .onAppear {
                viewSize = geo.size
                setupCamera()
            }
            .onChange(of: geo.size) { _, s in viewSize = s }
            // Пинч-зум
            .gesture(
                MagnificationGesture()
                    .onChanged { scale in
                        camera.handlePinch(scale: scale, baseZoom: baseZoomForPinch)
                    }
                    .onEnded { scale in
                        baseZoomForPinch = min(max(baseZoomForPinch * scale, 0.5), 15.0)
                    }
            )
            .onChange(of: camera.baseZoomFactor) { _, base in
                // Первый раз когда detectZoomStops() выставил базу — синхронизируем
                // стартовую точку для pinch-жеста, иначе первый щипок начинается
                // с 1.0 (ультраширик) вместо реального положения главного модуля
                baseZoomForPinch = base
            }
            .onChange(of: settings.nightModeSuggested) { _, suggested in
                withAnimation(.spring(duration: 0.4)) {
                    nightModeBanner = suggested && settings.captureMode == .auto
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // Галерея
        .sheet(isPresented: $showGallery) {
            GalleryView()
                .environmentObject(gallery)
        }
        // Настройки
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
        }
    }

    // MARK: - Верхняя строка: вспышка | режим | настройки

    private var topBar: some View {
        HStack {
            // Вспышка
            FlashButton(mode: $settings.flashMode)

            Spacer()

            // Подсказка режима + метаданные
            VStack(spacing: 2) {
                Text(settings.captureMode.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.yellow)

                HStack(spacing: 6) {
                    MetaLabel(text: "ISO \(Int(camera.currentISO))")
                    MetaLabel(text: shutterString)
                    MetaLabel(text: String(format: "f/%.1f", camera.currentAperture))
                }
            }

            Spacer()

            // Настройки
            Button(action: { showSettings = true }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.ultraThinMaterial))
            }
        }
    }

    // MARK: - Вспомогательные

    private var shutterString: String {
        let s = camera.currentShutter
        if s >= 1.0 { return String(format: "%.1fs", s) }
        let den = Int(1.0 / s)
        return "1/\(den)"
    }

    private func setupCamera() {
        // Передаём общий объект настроек из окружения, чтобы камера и UI
        // работали с одним экземпляром (и чтобы settings не освободился раньше времени)
        camera.settings = settings
        camera.onPhoto = { [weak gallery] result in
            Task { @MainActor in gallery?.add(result) }
        }
        camera.configure()
    }

    private func handleTap(at point: CGPoint, size: CGSize) {
        focusPoint    = point
        showFocusSquare = true

        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()

        camera.focusAndExpose(at: point, layerSize: size)
    }
}

// MARK: - Кнопка вспышки (циклически: auto → on → off)

struct FlashButton: View {
    @Binding var mode: AVCaptureDevice.FlashMode

    var body: some View {
        Button(action: cycleMode) {
            Image(systemName: iconName)
                .font(.system(size: 22))
                .foregroundStyle(mode == .off ? .white.opacity(0.5) : .yellow)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
        }
    }

    private var iconName: String {
        switch mode {
        case .auto: return "bolt.badge.a.fill"
        case .on:   return "bolt.fill"
        case .off:  return "bolt.slash.fill"
        @unknown default: return "bolt.fill"
        }
    }

    private func cycleMode() {
        switch mode {
        case .auto: mode = .on
        case .on:   mode = .off
        case .off:  mode = .auto
        @unknown default: mode = .auto
        }
    }
}

// MARK: - Маленькая метка с данными (ISO, выдержка, диафрагма)

struct MetaLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.4)))
    }
}

// MARK: - Баннер ночного режима

struct NightModeBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.stars.fill")
                .foregroundStyle(.white)
            Text("Рекомендуется ночной режим")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(red: 0.1, green: 0.1, blue: 0.45).opacity(0.85))
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        )
    }
}

// MARK: - Баннер прогресса обработки (Liquid Glass)

struct ProcessingBanner: View {
    let step:     PostProcessingPipeline.ProcessingStep
    let progress: Float

    var body: some View {
        VStack(spacing: 6) {
            Text(step.rawValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: CGFloat(progress) * geo.size.width)
                        .animation(.linear(duration: 0.15), value: progress)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 40)
    }
}
