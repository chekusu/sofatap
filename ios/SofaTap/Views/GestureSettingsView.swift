import SwiftUI
import UIKit

/// Changes remain local to this target's profile. The caller owns persistence.
struct GestureSettingsView: View {
    @Binding var configuration: GestureConfiguration
    let target: GestureTarget
    var availableActions: Set<GestureAction>? = nil
    var guideContext: DeviceGuideContext? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var pendingPreset: GesturePreset?
    @State private var showPresetConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showPractice = false

    private var selectedPreset: GesturePreset? {
        GesturePreset.allCases.first { configuration == GestureConfiguration(preset: $0, target: target) }
    }

    private var replacementDescription: String {
        target == .computer
            ? String(localized: "这会替换当前电脑的手势和时间设置，并将指针速度恢复为默认值。")
            : String(localized: "这会替换当前设备类型的手势和时间设置。")
    }

    var body: some View {
        NavigationStack {
            Form {
                presetSection
                mappingSection
                timingSection
                Section {
                    Button { showPractice = true } label: {
                        Label(String(localized: "试试这些手势"), systemImage: "hand.draw")
                            .frame(minHeight: 28)
                    }.accessibilityIdentifier("gesturePractice")
                    Button(String(localized: "恢复默认手势"), role: .destructive) { showResetConfirmation = true }
                        .frame(minHeight: 28)
                }
                .listRowBackground(Palette.panel)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle(String(localized: "手势设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
            .confirmationDialog(String(localized: "替换自定义手势？"), isPresented: $showPresetConfirmation, titleVisibility: .visible) {
                if let preset = pendingPreset {
                    Button(String(localized: "应用预设")) { apply(preset) }
                }
                Button(String(localized: "取消"), role: .cancel) { pendingPreset = nil }
            } message: {
                Text(replacementDescription)
            }
            .confirmationDialog(String(localized: "恢复默认手势？"), isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button(String(localized: "恢复默认手势"), role: .destructive) { apply(.sofatap) }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(replacementDescription)
            }
            .sheet(isPresented: $showPractice) {
                GesturePracticeView(configuration: configuration, target: target, availableActions: availableActions, guideContext: guideContext)
            }
        }
        .tint(Palette.mint)
        .preferredColorScheme(.dark)
#if targetEnvironment(simulator)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--demo") && ProcessInfo.processInfo.arguments.contains("--demo-gesture-practice") {
                showPractice = true
            }
        }
#endif
    }

    private var presetSection: some View {
        Section {
            ForEach(GesturePreset.allCases, id: \.self) { preset in
                Button { choose(preset) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(preset.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text(preset.detail(for: target)).font(.footnote).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: selectedPreset == preset ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(selectedPreset == preset ? Palette.mint : Palette.muted)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedPreset == preset ? .isSelected : [])
                .accessibilityIdentifier("gesturePreset_\(preset.rawValue)")
            }
        } header: {
            HStack {
                Text(String(localized: "行为预设"))
                Spacer()
                Text(target.title)
            }
        } footer: {
            if guideContext?.tvNavigation == true {
                Text(String(localized: "在右下角的小区域左右滑动，找到模式按钮即可切换到光标。手势设置只影响光标模式，电脑的设置不会改变。"))
            }
            Text(selectedPreset == nil ? String(localized: "已自定义。电脑和电视分别保存设置。") : String(localized: "选择一套预设，也可以逐项修改。电脑和电视分别保存设置。"))
        }
        .listRowBackground(Palette.panel)
    }

    private var mappingSection: some View {
        Section {
            ForEach(GestureID.allCases, id: \.self) { gesture in
                Menu {
                    let allowed = GestureConfiguration.allowedActions(for: gesture, target: target).filter {
                        $0 == .none || availableActions?.contains($0) != false || $0 == configuration.action(for: gesture)
                    }
                    ForEach(allowed, id: \.self) { action in
                        Button {
                            configuration.setAction(action, for: gesture)
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            if configuration.action(for: gesture) == action {
                                Label(action.title(for: target), systemImage: "checkmark")
                            } else {
                                Text(action.title(for: target))
                            }
                        }
                        .disabled(action != .none && availableActions?.contains(action) == false)
                    }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Text(gesture.title).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(configuration.action(for: gesture).title(for: target))
                                .foregroundStyle(Palette.mint)
                            if configuration.action(for: gesture) != .none,
                               availableActions?.contains(configuration.action(for: gesture)) == false {
                                Text(String(localized: "当前设备暂不支持此操作"))
                                    .font(.caption).foregroundStyle(Palette.muted)
                            }
                        }.multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                            .accessibilityHidden(true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(gesture.title)
                .accessibilityValue(configuration.action(for: gesture).title(for: target))
                .accessibilityIdentifier("gestureBinding_\(gesture.rawValue)")
            }
        } header: {
            Text(String(localized: "手势与操作"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "点选操作即可修改。左右分区固定对应触控区的物理左右侧。"))
                Text(String(localized: "未设置双击动作时，每次轻点仍执行单击动作。"))
            }
        }
        .listRowBackground(Palette.panel)
    }

    private var timingSection: some View {
        Section {
            if target == .computer {
                pointerSpeedSlider
            }
            timingSlider(String(localized: "长按等待时间"), value: $configuration.holdDuration,
                         range: GestureConfiguration.holdDurationRange, step: 0.05, identifier: "gestureHoldDuration")
            timingSlider(String(localized: "双击间隔"), value: $configuration.doubleTapInterval,
                         range: GestureConfiguration.doubleTapIntervalRange, step: 0.01, identifier: "gestureDoubleTapInterval")
            Toggle(String(localized: "自然滚动"), isOn: $configuration.naturalScrolling)
                .accessibilityIdentifier("gestureNaturalScrolling")
        } header: {
            Text(String(localized: "触控手感"))
        } footer: {
            Text(String(localized: "双击间隔越长，单击可能等待越久。自然滚动让内容跟随手指；右侧滚动条方向保持不变。"))
        }
        .listRowBackground(Palette.panel)
    }

    private var pointerSpeedSlider: some View {
        let value = configuration.pointerSpeed.formatted(.number.precision(.fractionLength(0...2)))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "指针速度"))
                Spacer()
                Text(verbatim: "\(value)×")
                    .monospacedDigit().foregroundStyle(Palette.muted)
            }
            Slider(value: $configuration.pointerSpeed, in: GestureConfiguration.pointerSpeedRange, step: 0.25)
                .accessibilityLabel(String(localized: "指针速度"))
                .accessibilityValue(String.localizedStringWithFormat(String(localized: "%@ 倍"), value))
                .accessibilityIdentifier("gesturePointerSpeed")
            Text(String(localized: "调整从手机遥控时的指针移动距离，不会更改电脑系统的鼠标设置。"))
                .font(.footnote).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 5)
    }

    private func timingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: "\(Int((value.wrappedValue * 1000).rounded())) ms")
                    .monospacedDigit().foregroundStyle(Palette.muted)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 1000).rounded())) ms")
                .accessibilityIdentifier(identifier)
        }.padding(.vertical, 5)
    }

    private func choose(_ preset: GesturePreset) {
        guard selectedPreset != preset else { return }
        if selectedPreset == nil {
            pendingPreset = preset
            showPresetConfirmation = true
        } else {
            apply(preset)
        }
    }

    private func apply(_ preset: GesturePreset) {
        configuration = GestureConfiguration(preset: preset, target: target)
        pendingPreset = nil
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// Uses the production recognizer, with local feedback instead of remote callbacks.
struct GesturePracticeView: View {
    let configuration: GestureConfiguration
    let target: GestureTarget
    var availableActions: Set<GestureAction>? = nil
    var guideContext: DeviceGuideContext? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var result = String(localized: "在下方触控区试一试")
    @State private var control = TouchSurface.Control()
    @State private var dragging = false
    @State private var lastClick: (action: GestureAction, time: Double)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(result).font(.title2.weight(.semibold)).foregroundStyle(Palette.mint)
                        .multilineTextAlignment(.center).contentTransition(.numericText())
                        .accessibilityIdentifier("gesturePracticeResult")
                    Text(String(localized: "练习只在手机内显示反馈，不会操作已连接的设备。"))
                        .font(.footnote).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                }
                .frame(minHeight: 100)
                TouchSurface(enabled: true, control: control,
                             profile: target == .computer ? .desktop : .tvPointer,
                             configuration: configuration,
                             onMove: { _, _ in show(dragging ? .drag : .movePointer) },
                             onLeftTap: { showClick(.leftClick) },
                             onRightTap: { showClick(.rightClick) },
                             onDraggingChanged: { active in
                                 dragging = active
                                 if active { show(.drag) }
                                 else { result = String(localized: "已松开") }
                             },
                             onScroll: { _ in show(.scroll) },
                             onShortcut: { show($0) })
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 30))
                    .overlay(RoundedRectangle(cornerRadius: 30).stroke(Palette.mint.opacity(0.22), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                    .accessibilityIdentifier("gesturePracticePad")
                Text(String(localized: "双击并按住：轻点一次，再次按下后保持不动。"))
                    .font(.footnote).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .background(Palette.background)
            .navigationTitle(String(localized: "手势练习"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { control.cancel(); dismiss() }
                }
            }
            .onDisappear { control.cancel() }
        }.tint(Palette.mint).preferredColorScheme(.dark)
    }

    private func show(_ action: GestureAction) {
        if guideContext?.availability(of: action) == .unknown {
            result = action.title(for: target) + "\n" + String(localized: "等待设备报告")
        } else if guideContext?.availability(of: action) == .unsupported || availableActions?.contains(action) == false {
            result = action.title(for: target) + "\n" + String(localized: "当前设备暂不支持此操作")
        } else {
            result = action.title(for: target)
        }
    }

    private func showClick(_ action: GestureAction) {
        let now = ProcessInfo.processInfo.systemUptime
        // A double-click callback is delivered as two clicks in the same dispatch.
        if let lastClick, lastClick.action == action, now - lastClick.time < 0.06 {
            show(action == .leftClick ? .doubleLeftClick : .doubleRightClick)
            self.lastClick = nil
        } else {
            show(action)
            lastClick = (action, now)
        }
    }
}
