// SettingsView.swift — настройки LCAM (Liquid Glass iOS 26)

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var settings: CameraSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {

                // MARK: Обработка
                Section {
                    LabeledSlider(
                        label:  "Мощность обработки",
                        symbol: "cpu",
                        value:  $settings.processingStrength,
                        range:  0...1,
                        format: "%.0f%%",
                        scale:  100
                    )
                    LabeledSlider(
                        label:  "Резкость",
                        symbol: "sparkle.magnifyingglass",
                        value:  $settings.sharpeningStrength,
                        range:  0...1,
                        format: "%.0f%%",
                        scale:  100
                    )
                    LabeledSlider(
                        label:  "Шумоподавление",
                        symbol: "waveform",
                        value:  $settings.noiseReductionStrength,
                        range:  0...1,
                        format: "%.0f%%",
                        scale:  100
                    )
                } header: {
                    Text("Вычислительная обработка")
                }

                // MARK: Цвет
                Section {
                    LabeledSlider(
                        label:  "Насыщенность",
                        symbol: "paintpalette",
                        value:  $settings.saturationBoost,
                        range:  0...0.5,
                        format: "+%.0f%%",
                        scale:  200
                    )
                    LabeledSlider(
                        label:  "Подъём теней",
                        symbol: "shadow",
                        value:  $settings.shadowLift,
                        range:  0...0.3,
                        format: "%.0f%%",
                        scale:  333
                    )
                    LabeledSlider(
                        label:  "Восстановление светов",
                        symbol: "sun.max",
                        value:  $settings.highlightRecovery,
                        range:  0...1,
                        format: "%.0f%%",
                        scale:  100
                    )
                } header: {
                    Text("Цветовая наука")
                }

                // MARK: Форматы
                Section {
                    Toggle(isOn: $settings.useHEIF) {
                        Label("Формат HEIF", systemImage: "photo")
                    }
                    Toggle(isOn: $settings.saveOriginalFrame) {
                        Label("Сохранять оригинал", systemImage: "doc.on.doc")
                    }
                    Toggle(isOn: $settings.enableRAWCapture) {
                        Label("RAW захват (BETA)", systemImage: "camera.aperture")
                    }
                } header: {
                    Text("Форматы и сохранение")
                }

                // MARK: Видео
                Section {
                    Picker("Разрешение", selection: $settings.videoResolution) {
                        ForEach(VideoResolution.allCases, id: \.self) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    Picker("Частота кадров", selection: $settings.videoFrameRate) {
                        ForEach(VideoFrameRate.allCases, id: \.self) { fps in
                            Text(fps.displayName).tag(fps)
                        }
                    }
                    Toggle(isOn: $settings.videoStabilization) {
                        Label("Стабилизация", systemImage: "video.badge.waveform")
                    }
                } header: {
                    Text("Видео")
                }

                // MARK: UI
                Section {
                    Toggle(isOn: $settings.isGridEnabled) {
                        Label("Сетка компоновки", systemImage: "grid")
                    }
                    Toggle(isOn: $settings.isLevelEnabled) {
                        Label("Горизонт", systemImage: "level")
                    }
                    Toggle(isOn: $settings.mirrorFrontCamera) {
                        Label("Зеркалить фронт", systemImage: "arrow.left.and.right")
                    }
                } header: {
                    Text("Интерфейс")
                }

                // MARK: Сброс
                Section {
                    Button(role: .destructive, action: resetToDefaults) {
                        Label("Сбросить к стандартным", systemImage: "arrow.counterclockwise")
                    }
                }

                // MARK: О приложении
                Section {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Движок")
                        Spacer()
                        Text("LCAM Computational Engine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Алгоритм")
                        Spacer()
                        Text("HDR+ Multi-Frame")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("О приложении")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        settings.persist()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func resetToDefaults() {
        settings.processingStrength    = 0.85
        settings.sharpeningStrength    = 0.5
        settings.noiseReductionStrength = 0.7
        settings.saturationBoost       = 0.12
        settings.shadowLift            = 0.08
        settings.highlightRecovery     = 0.6
    }
}

// MARK: - Слайдер с меткой

struct LabeledSlider: View {
    let label:  String
    let symbol: String
    @Binding var value: Float
    let range:  ClosedRange<Float>
    let format: String
    let scale:  Float           // множитель для отображения (например, 100 → проценты)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: symbol)
                    .font(.system(size: 14))
                Spacer()
                Text(String(format: format, value * scale))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            Slider(value: $value, in: range)
        }
        .padding(.vertical, 4)
    }
}
