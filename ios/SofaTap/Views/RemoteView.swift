import SwiftUI
import UIKit

struct RemoteView: View {
    // Xcode uses the asset catalog; the direct compiler fallback bundles the
    // same PNG as a resource, which SwiftUI's named-image lookup does not read.
    private static let brandImage: UIImage = {
        if let image = UIImage(named: "BrandMark") { return image }
        if let path = Bundle.main.path(forResource: "BrandMark", ofType: "png"),
           let image = UIImage(contentsOfFile: path) { return image }
        return UIImage(systemName: "sofa.fill") ?? UIImage()
    }()
    @ObservedObject var model: ControllerModel
    @ObservedObject private var unlock: ComputerUnlockController
    init(model: ControllerModel) {
        self.model = model; self.unlock = model.unlock
        _tv = StateObject(wrappedValue: WebOSTVController(enabled: !model.demo))
        _androidTV = StateObject(wrappedValue: AndroidTVController(enabled: !model.demo, targetSelected: !model.desktopControlEnabled && UserDefaults.standard.string(forKey: "manualRemoteTarget") == "androidtv"))
        _androidSelected = State(initialValue: !model.demo && UserDefaults.standard.string(forKey: "manualRemoteTarget") == "androidtv")
#if targetEnvironment(simulator)
        // Isolated layout fixtures never create a receiver connection.
        _composerVisible = State(initialValue: model.demo && ProcessInfo.processInfo.arguments.contains("--demo-composer"))
        _keyboardFocused = State(initialValue: model.demo && ProcessInfo.processInfo.arguments.contains("--demo-keyboard"))
#endif
    }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @StateObject private var dictation = SpeechDictationController()
    @StateObject private var tv: WebOSTVController
    @StateObject private var androidTV: AndroidTVController
    @State private var androidSelected: Bool
    @State private var pairingSheet = false
    @State private var tvRemoteSetupSheet = false
    @State private var tvDirectionSheet = false
    @State private var tvKeyboardFocused = false
    @State private var tvWantsDictation = false
    @State private var tvControlModes = UserDefaults.standard.dictionary(forKey: "sofatap.tvControlModes.v1") as? [String: String] ?? [:]
    @State private var incomingPairingLink: String?
    @State private var guideSheet = false
    @State private var gestureSettingsSheet = false
    @State private var volumeSheet = false
    @State private var gestureSettingsTarget = GestureTarget.computer
    @State private var gesturePreferences = GesturePreferences.load(from: .standard)
    @State private var showingSpeechError = false
    @State private var touchControl = TouchSurface.Control()
    @State private var tvNavigationControl = AndroidTVNavigationPad.Control()
    @State private var tvAuxiliaryControl = TVAuxiliaryPager.Control()
    @State private var edgeScrollControl = EdgeScrollStrip.Control()
    @State private var draftEditorControl = NativeDraftEditor.Control()
    @State private var dictationImpact = UIImpactFeedbackGenerator(style: .light)
    @State private var resendAlert = false
    @State private var clearAlert = false
    @State private var composerVisible = false
    @State private var keyboardFocused = false
    @State private var remoteFocus = RemoteTextFocusPolicy()
    @State private var speechBaseDraft = ""
    @State private var speechBaseSnapshot: LiveTextSnapshot?
    @State private var speechRequest: UUID?
    @State private var speechOwnsDraft = false
    @State private var dictationStartTask: Task<Void, Never>?

    private var speechBusy: Bool { dictation.state != .idle }
    private var televisionSelected: Bool {
#if SOFATAP_TV_UI_TESTING
        if model.demo && ProcessInfo.processInfo.arguments.contains("--demo-tv-controls") { return true }
#endif
        return !model.desktopControlEnabled
    }
    private var androidTVSelected: Bool { televisionSelected && androidSelected }
    private var tvMode: AndroidTVControlMode {
#if SOFATAP_TV_UI_TESTING
        if model.demo, let mode = androidTV.fixtureModeSelection { return mode }
#endif
        if let identity = androidTV.saved?.deviceIdentity, let raw = tvControlModes[identity], let mode = AndroidTVControlMode(rawValue: raw) { return mode }
        return androidTV.status?.tvControls == nil ? .pointer : .navigation
    }
    private var tvNavigationSelected: Bool { androidTVSelected && tvMode == .navigation }
    private var currentStatusTitle: String { androidTVSelected ? androidTV.title : televisionSelected ? tv.title : model.statusTitle }
    private var inputSessionAvailable: Bool {
        scenePhase == .active && !pairingSheet && !guideSheet && !gestureSettingsSheet && !volumeSheet &&
        !tvRemoteSetupSheet && !showingSpeechError && !resendAlert && !clearAlert
    }
    // The direction sheet contains TV controls; keep its session available while
    // disabling the touch surface behind it. Other modals block both paths.
    private var interfaceAvailable: Bool { inputSessionAvailable && !tvDirectionSheet }
    private var inputEnabled: Bool {
        (androidTVSelected ? androidTV.canControl : televisionSelected ? tv.canControl : model.canControl) && interfaceAvailable
    }

    private var gestureTarget: GestureTarget { televisionSelected ? .television : .computer }
    private var gestureConfiguration: GestureConfiguration { gesturePreferences[gestureTarget] }
    private var gestureAvailableActions: Set<GestureAction>? {
        guard androidTVSelected else { return nil }
        guard let capabilities = androidTV.status?.capabilities else { return [.none] }
        var actions: Set<GestureAction> = [.none]
        if capabilities.overlayCursor { actions.insert(.movePointer) }
        if capabilities.nodeClick { actions.insert(.leftClick) }
        if capabilities.scroll { actions.insert(.scroll) }
        if capabilities.directionalFocus { actions.insert(.confirm) }
        if capabilities.back { actions.insert(.back) }
        if capabilities.home { actions.insert(.home) }
        return actions
    }

    private var guideContext: DeviceGuideContext {
        if androidTVSelected {
            return DeviceGuideContext(kind: .androidTV, deviceName: currentDeviceName,
                                      connected: androidTV.phase == .ready,
                                      availableActions: androidTV.status == nil ? nil : gestureAvailableActions,
                                      tvNavigation: tvNavigationSelected,
                                      tvNavigationReady: androidTV.status?.tvControls?.navigationStatus == .ready,
                                      tvTextStatus: androidTV.status?.tvControls?.textStatus.rawValue)
        }
        if televisionSelected {
            return DeviceGuideContext(kind: .webOS, deviceName: currentDeviceName,
                                      connected: tv.phase == .ready,
                                      availableActions: tv.phase == .ready ? [.movePointer, .leftClick, .scroll, .confirm, .back, .home] : nil)
        }
        let platform = model.connected ? model.receiverState.platform.rawValue :
            model.savedDevices.first(where: { $0.id == model.selectedDeviceID })?.platform
        return DeviceGuideContext(kind: .computer(platform: platform), deviceName: currentDeviceName,
                                  connected: model.connected,
                                  availableActions: model.connected ? (model.inputAvailable ? Set(GestureAction.allCases) : []) : nil)
    }

    var body: some View { dictationEvents }

    // Keep each opaque view expression small enough for the CI Swift compiler.
    // The modifier order remains layout -> presentation -> lifecycle -> dictation.
    private var layout: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                touchpad
                    .frame(maxWidth: .infinity, minHeight: min(170, geometry.size.height * 0.4), maxHeight: .infinity)
                if androidTVSelected, let feedback = androidTV.inputFeedback {
                    Text(feedback)
                        .font(.footnote).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .accessibilityIdentifier("androidTVInputFeedback")
                }
                if composerVisible && androidTVSelected {
                    AndroidTVComposer(tv: androidTV, keyboardFocused: $tvKeyboardFocused, wantsDictation: $tvWantsDictation,
                                      active: inputEnabled, height: geometry.size.height < 500 ? 76 : 92)
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                } else if composerVisible && !televisionSelected {
                    composer(height: geometry.size.height < 500 ? 76 : 92)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .background(Palette.background)
    }

    private var presentation: some View {
        layout
        .sheet(isPresented: $pairingSheet) {
            PairingView(model: model, tv: tv, androidTV: androidTV, selectAndroidTV: selectAndroidTelevision,
                        selectTV: selectTelevision, selectComputer: { selectComputer(reconnect: false) },
                        androidSelected: androidTVSelected, incomingLink: $incomingPairingLink)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $tvRemoteSetupSheet) {
            AndroidTVRemoteSetupView(tv: androidTV).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $tvDirectionSheet) {
            AndroidTVDirectionButtons(tv: androidTV).presentationDetents([.height(300)]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $guideSheet) { RemoteGuideView(configuration: gestureConfiguration, context: guideContext) }
        .sheet(isPresented: $volumeSheet) {
            SystemVolumeSheet(model: model)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $gestureSettingsSheet) {
            GestureSettingsView(configuration: Binding(
                get: { gesturePreferences[gestureSettingsTarget] },
                set: { gesturePreferences[gestureSettingsTarget] = $0.sanitized(for: gestureSettingsTarget) }
            ), target: gestureSettingsTarget, availableActions: gestureSettingsTarget == gestureTarget ? gestureAvailableActions : nil,
                                guideContext: gestureSettingsTarget == gestureTarget ? guideContext : nil)
        }
        .alert(String(localized: "语音输入暂不可用"), isPresented: $showingSpeechError) {
            Button(String(localized: "使用键盘")) { toggleKeyboard() }
            Button(String(localized: "好"), role: .cancel) {}
        } message: { Text(dictation.errorMessage ?? String(localized: "请尝试键盘或 Typeless。")) }
        .alert(String(localized: "允许再次发送这段文字？"), isPresented: $resendAlert) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "已查看屏幕，允许重发")) { model.allowManualResend() }
        } message: {
            Text(String(localized: "上一次的文字可能已经输入。请先检查电脑屏幕，再手动按发送；重复文字无法自动撤销。"))
        }
        .alert(model.usesLiveText ? String(localized: "清空电脑当前输入框？") : String(localized: "清空手机上的草稿？"), isPresented: $clearAlert) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "清空草稿"), role: .destructive) { model.clearDraft() }
        } message: {
            Text(model.usesLiveText ? String(localized: "这会同步删除当前输入框中的文字。") : String(localized: "不会删除电脑里已经输入的文字。"))
        }
    }

    private var connectionEvents: some View {
        presentation
        .onAppear {
            model.setPointerSpeed(gesturePreferences[.computer].pointerSpeed)
            model.becameActive()
#if SOFATAP_TV_UI_TESTING
            if model.demo && ProcessInfo.processInfo.arguments.contains("--demo-tv-controls") {
                androidSelected = true
                androidTV.configureUIFixture(pairingRequired: ProcessInfo.processInfo.arguments.contains("--demo-tv-pairing"),
                                             editorReady: ProcessInfo.processInfo.arguments.contains("--demo-tv-keyboard"))
                composerVisible = ProcessInfo.processInfo.arguments.contains("--demo-tv-keyboard")
            }
#endif
            androidTV.setTargetSelected(androidTVSelected, reconnect: false)
            if scenePhase == .active { androidTV.becameActive() }
            else { androidTV.becameInactive() }
            if model.textDelivery == .uncertain { composerVisible = true }
            applyRemoteFocus()
#if targetEnvironment(simulator)
            if model.demo {
                gestureSettingsSheet = ProcessInfo.processInfo.arguments.contains("--demo-gestures")
                guideSheet = ProcessInfo.processInfo.arguments.contains("--demo-guide")
                pairingSheet = ProcessInfo.processInfo.arguments.contains("--demo-pairing") || ProcessInfo.processInfo.arguments.contains("--demo-add-device") || ProcessInfo.processInfo.arguments.contains("--demo-added-device")
            }
#endif
        }
        .onDisappear { stopInteraction(); androidTV.becameInactive() }
        .onOpenURL { url in
            // QR scans, pasted links and system links share one routing and
            // naming flow. Parsing happens before selecting any target.
            incomingPairingLink = url.absoluteString
            pairingSheet = true
        }
        .onChange(of: model.focusRevision) { _, _ in applyRemoteFocus() }
        .onChange(of: model.desktopControlEnabled) { _, enabled in
            // Covers explicit computer pairing links delivered by the OS.
            stopInteraction()
            composerVisible = false
            remoteFocus.reset()
            if enabled { tv.disconnect(); androidTV.setTargetSelected(false) }
        }
        .onChange(of: androidTV.acceptedInputFeedback) { _, _ in
            if androidTVSelected && scenePhase == .active { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
        .onChange(of: androidTV.rejectedInputFeedback) { _, _ in
            if androidTVSelected && scenePhase == .active { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
        .onChange(of: androidTV.selectedDeviceID) { _, _ in
            tvWantsDictation = false; tvKeyboardFocused = false; composerVisible = false
        }
        .onChange(of: androidTV.status?.tvControls?.editorEpoch) { old, new in
            guard androidTVSelected, scenePhase == .active else { return }
            tvWantsDictation = false
            if new != nil && old != new && !pairingSheet && !guideSheet && !gestureSettingsSheet && !tvRemoteSetupSheet && !tvDirectionSheet {
                composerVisible = true; tvKeyboardFocused = true
            } else if new == nil { tvKeyboardFocused = false }
        }
        .onChange(of: androidTV.phase) { _, phase in
            if androidTVSelected && phase != .ready { touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel() }
            if androidTVSelected && phase == .ready && scenePhase == .active && !pairingSheet && !guideSheet && !gestureSettingsSheet && !tvRemoteSetupSheet { androidTV.resumeInput() }
        }
        .onChange(of: androidTV.canControl) { _, available in
            if androidTVSelected && !available { touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel() }
        }
        .onChange(of: tv.phase) { _, phase in
            if televisionSelected && !androidTVSelected && phase != .ready { touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel() }
            if televisionSelected && !androidTVSelected && phase == .ready && scenePhase == .active && !pairingSheet && !guideSheet && !gestureSettingsSheet { tv.resumeInput() }
        }
    }

    private var desktopEvents: some View {
        connectionEvents
        .onChange(of: model.liveTextStatus) { _, _ in
            if model.liveTextPaused || (model.usesLiveText && model.liveTextStatus == .idle && speechRequest != nil) {
                cancelSpeech()
            }
        }
        .onChange(of: model.dragging) { _, dragging in
            if !dragging { applyRemoteFocus() }
        }
        .onChange(of: model.canControl) { _, enabled in
            if enabled { applyRemoteFocus() }
        }
        .onChange(of: model.controlAvailable) { _, available in
            // A pending drag release blocks new input without disconnecting or
            // stopping dictation. Only session/permission loss resets UI state.
            if !available && !televisionSelected { remoteFocus.reset(); stopInteraction() }
        }
    }

    private var interactionEvents: some View {
        desktopEvents
        .onChange(of: tvRemoteSetupSheet) { _, shown in
            if shown { stopInteraction() } else { resumeCurrentInput() }
        }
        .onChange(of: pairingSheet) { _, shown in
            if shown { stopInteraction() }
            else { resumeCurrentInput() }
        }
        .onChange(of: guideSheet) { _, shown in
            if shown { stopInteraction() }
            else { resumeCurrentInput() }
        }
        .onChange(of: gestureSettingsSheet) { _, shown in
            if shown { stopInteraction() }
            else { resumeCurrentInput() }
        }
        .onChange(of: volumeSheet) { _, shown in
            if shown { stopInteraction() }
            else { resumeCurrentInput() }
        }
        .onChange(of: gesturePreferences) { _, preferences in
            touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel()
            model.setPointerSpeed(preferences[.computer].pointerSpeed)
            if !model.demo { _ = preferences.save(to: .standard) }
        }
        .onChange(of: model.pairingError) { _, error in
            if !televisionSelected && error != nil && !pairingSheet { stopInteraction(); pairingSheet = true }
        }
        .onChange(of: dictation.errorMessage) { _, error in
            if error != nil { interruptTouch(); showingSpeechError = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { stopInteraction(); tv.disconnect(); androidTV.becameInactive() }
            else if phase == .inactive {
                interruptTouch()
                keyboardFocused = false
                if dictation.state != .requestingPermission { cancelSpeech() }
            } else {
                androidTV.setTargetSelected(androidTVSelected, reconnect: false)
                androidTV.becameActive()
                resumeCurrentInput()
            }
        }
    }

    private var dictationEvents: some View {
        interactionEvents
        .onReceive(dictation.$transcript) { transcript in
            guard !televisionSelected else { return }
            // @Published replays its current value when SwiftUI subscribes. Ignore
            // an idle session's previous result and a new session's empty reset.
            guard let draft = DictationTranscript.draft(base: speechBaseDraft, transcript: transcript,
                                                       ownsDraft: speechOwnsDraft,
                                                       sessionIsActive: dictation.state != .idle) else { return }
            if let base = speechBaseSnapshot {
                guard let snapshot = base.replacingSelection(with: transcript) else { return }
                model.editText(snapshot.text, selection: snapshot.selection, marked: false)
            } else { model.draft = draft }
        }
        .onChange(of: dictation.state) { _, state in
            if state == .idle { speechOwnsDraft = false; speechRequest = nil }
        }
    }

    private var currentDeviceName: String {
#if SOFATAP_TV_UI_TESTING
        if model.demo && androidTVSelected { return androidTV.name }
#endif
        if androidTVSelected { return androidTV.saved == nil ? String(localized: "选择设备") : androidTV.currentDisplayName }
        if televisionSelected { return tv.saved == nil ? String(localized: "选择设备") : tv.currentDisplayName }
        if model.selectedDeviceID == nil { return String(localized: "选择设备") }
        return model.currentDisplayName
    }

    private var connectionLabel: String {
        if androidTVSelected { return androidTV.title }
        if televisionSelected { return tv.title }
        if model.demo { return String(localized: "界面演示") }
        if model.connecting { return String(localized: "正在安全连接…") }
        if model.connected && model.inputAvailable && model.usesPeerTransport { return String(localized: "已连接 · 设备直连") }
        if model.connected { return model.inputAvailable ? String(localized: "已连接 · 普通 Wi-Fi") : model.receiverState.unavailableTitle }
        return String(localized: "未连接")
    }

    private var deviceSymbol: String {
        if televisionSelected { return "tv" }
        let platform = model.savedDevices.first(where: { $0.id == model.selectedDeviceID })?.platform
        return platform == "macos" ? "laptopcomputer" : "desktopcomputer"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                stopInteraction()
                UISelectionFeedbackGenerator().selectionChanged()
                pairingSheet = true
            } label: {
                HStack(spacing: 9) {
                    Image(uiImage: Self.brandImage)
                        .resizable().scaledToFit().frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: deviceSymbol).font(.system(size: 12))
                            Text(currentDeviceName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        HStack(spacing: 4) {
                            Image(systemName: statusSymbol).font(.system(size: 8, weight: .bold))
                            Text(connectionLabel).font(.system(size: 11)).lineLimit(2)
                        }.foregroundStyle(statusColor)
                    }
                }
                .foregroundStyle(.white)
                .frame(minHeight: 44, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Palette.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(RemoteIconButtonStyle())
            .accessibilityLabel(String(localized: "配对设备与连接设置"))
            .accessibilityValue(currentDeviceName + ", " + connectionLabel)
            .accessibilityIdentifier("pairingButton")
            Spacer(minLength: 0)
            Button {
                stopInteraction()
                UISelectionFeedbackGenerator().selectionChanged()
                gestureSettingsTarget = gestureTarget
                gestureSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 21))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .foregroundStyle(Palette.mint.opacity(0.88))
            }
            .buttonStyle(RemoteIconButtonStyle())
            .accessibilityLabel(String(localized: "手势设置"))
            .accessibilityIdentifier("gestureSettingsButton")
            Button {
                stopInteraction()
                UISelectionFeedbackGenerator().selectionChanged()
                guideSheet = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 22, weight: .regular))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .foregroundStyle(Palette.mint.opacity(0.88))
            }
            .buttonStyle(RemoteIconButtonStyle())
            .accessibilityLabel(String(localized: "使用指南"))
            .accessibilityIdentifier("guideButton")
        }
    }

    private var touchpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.064, green: 0.095, blue: 0.104),
                                               Color(red: 0.032, green: 0.048, blue: 0.059)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
            TouchSurface(enabled: inputEnabled && !tvNavigationSelected, control: touchControl,
                         profile: televisionSelected ? .tvPointer : .desktop,
                         configuration: gestureConfiguration,
                         onMove: { dx, dy in
                             if androidTVSelected { androidTV.move(dx: dx, dy: dy) }
                             else if televisionSelected { tv.move(dx: dx, dy: dy) }
                             else { model.moveFromTouch(dx: dx, dy: dy) }
                         },
                         onLeftTap: { if androidTVSelected { androidTV.click() } else if televisionSelected { tv.click() } else { model.click("left") } },
                         onRightTap: { if !televisionSelected { model.click("right") } },
                         onDraggingChanged: { if !televisionSelected { model.setDragging($0) } },
                         onScroll: scrollCurrentDevice,
                         onShortcut: performGestureShortcut,
                         onInteractionBegan: { tvAuxiliaryControl.cancel() })
                .allowsHitTesting(!tvNavigationSelected)
            if tvNavigationSelected {
                tvNavigationSurface
                if !androidTV.canNavigate { tvNavigationSetupPrompt }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Palette.mint.opacity(0.24), Palette.mint.opacity(0.045), Palette.mint.opacity(0.13)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if televisionSelected {
                if !tvNavigationSelected {
                    GeometryReader { geometry in
                        let toolsLayout = TVAuxiliaryLayout(cardWidth: geometry.size.width)
                        if let frame = toolsLayout.scrollFrame(cardWidth: geometry.size.width, cardHeight: geometry.size.height) {
                            edgeScrollStrip
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
            } else {
                edgeScrollStrip
                    .frame(width: EdgeScrollStrip.minimumHitWidth)
                    .frame(maxWidth: .infinity, alignment: layoutDirection == .rightToLeft ? .leading : .trailing)
                    .padding(.top, 80).padding(.bottom, 16)
                    .padding(layoutDirection == .rightToLeft ? .leading : .trailing, 8)
            }
        }
        .overlay(alignment: .top) { header.padding(.horizontal, 20).padding(.top, 20) }
        .overlay(alignment: .bottom) {
            // Physical control positions reserve the right edge for scrolling.
            // Text elsewhere continues to follow the selected language's direction.
            bottomBar.environment(\.layoutDirection, .leftToRight)
                .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .overlay {
            if televisionSelected {
                GeometryReader { geometry in
                    let toolsLayout = TVAuxiliaryLayout(cardWidth: geometry.size.width)
                    let toolsFrame = toolsLayout.frame(cardWidth: geometry.size.width, cardHeight: geometry.size.height)
                    televisionAuxiliaryPager(layout: toolsLayout)
                        .frame(width: toolsLayout.width, height: toolsLayout.height)
                        .position(x: toolsFrame.midX, y: toolsFrame.midY)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
    }

    private var edgeScrollStrip: some View {
        EdgeScrollStrip(enabled: inputEnabled && (!androidTVSelected || androidTV.status?.capabilities.scroll == true),
                        control: edgeScrollControl,
                        interactionID: androidTVSelected ? "androidtv" : televisionSelected ? "webos" : "computer",
                        onInteractionBegan: { touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel() },
                        onScroll: scrollCurrentDevice)
    }

    private var tvNavigationSurface: some View {
        let surface = AndroidTVNavigationPad(enabled: inputEnabled && androidTV.canNavigate, control: tvNavigationControl, onInteractionBegan: { tvAuxiliaryControl.cancel() }) { _ = androidTV.remoteKey($0) }
#if SOFATAP_TV_UI_TESTING
        return surface.accessibilityValue(androidTV.fixtureActionSummary)
#else
        return surface
#endif
    }

    private var tvNavigationSetupPrompt: some View {
        VStack(spacing: 10) {
            Text(String(localized: "电视遥控")).font(.headline)
            if androidTV.connectionReady && androidTV.status?.tvControls != nil && androidTV.status?.tvControls?.navigationStatus != .unsupported {
                Button(String(localized: "连接电视遥控")) { tvRemoteSetupSheet = true }
                    .buttonStyle(.borderedProminent).tint(Palette.mint).foregroundStyle(Palette.background)
                    .accessibilityIdentifier("tvRemoteSetup")
            } else {
                Text(String(localized: "此接收器暂不提供系统遥控，请更新接收器或使用光标模式。"))
                    .font(.footnote).multilineTextAlignment(.center)
            }
        }
        .padding(14).frame(maxWidth: 260)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private var bottomBar: some View {
        Group {
            if televisionSelected { televisionInputBar }
            else { computerBottomBar }
        }
    }
    private func televisionAuxiliaryPager(layout: TVAuxiliaryLayout) -> some View {
        TVAuxiliaryPager(pages: televisionAuxiliaryPages,
                         identity: androidTVSelected ? "android:" + (androidTV.selectedDeviceID?.uuidString ?? "none") : "webos:" + (tv.selectedDeviceID?.uuidString ?? "none"),
                         layout: layout, interactionEnabled: interfaceAvailable, control: tvAuxiliaryControl) {
            touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel(); edgeScrollControl.cancel()
        }
    }
    private var televisionAuxiliaryPages: [[TVAuxiliaryPager.Action]] {
        let back = TVAuxiliaryPager.Action(symbol: "chevron.backward", label: String(localized: "返回"), identifier: "tvBackButton",
                                           enabled: inputEnabled && (!androidTVSelected || (tvNavigationSelected ? androidTV.canNavigate : androidTV.status?.capabilities.back == true))) {
            if androidTVSelected {
                if tvNavigationSelected { _ = androidTV.remoteKey(.back) } else { _ = androidTV.key(.back) }
            } else { UIImpactFeedbackGenerator(style: .light).impactOccurred(); tv.button(.back) }
        }
        let home = TVAuxiliaryPager.Action(symbol: "house", label: String(localized: "电视主页"), identifier: "tvHomeButton",
                                           enabled: inputEnabled && (!androidTVSelected || (tvNavigationSelected ? androidTV.canNavigate : androidTV.status?.capabilities.home == true))) {
            if androidTVSelected {
                if tvNavigationSelected { _ = androidTV.remoteKey(.home) } else { _ = androidTV.key(.home) }
            } else { UIImpactFeedbackGenerator(style: .light).impactOccurred(); tv.button(.home) }
        }
        guard androidTVSelected else { return [[back, home]] }
        let directions = TVAuxiliaryPager.Action(symbol: "dpad", label: String(localized: "方向键与确认"), identifier: "tvDirectionButtons",
                                                 enabled: inputEnabled && androidTV.canNavigate) {
            tvKeyboardFocused = false; tvWantsDictation = false
            UISelectionFeedbackGenerator().selectionChanged(); tvDirectionSheet = true
        }
        let mode = TVAuxiliaryPager.Action(symbol: tvMode == .navigation ? "hand.draw" : "cursorarrow", label: String(localized: "切换电视遥控与光标模式"),
                                           identifier: "tvControlMode", value: tvMode == .navigation ? String(localized: "电视遥控") : String(localized: "光标模式")) {
            toggleTVControlMode()
        }
        return [[back, home], [directions, mode]]
    }
    private func toggleTVControlMode() {
        touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel(); edgeScrollControl.cancel(); tvWantsDictation = false
        let next: AndroidTVControlMode = tvMode == .navigation ? .pointer : .navigation
        if let identity = androidTV.saved?.deviceIdentity {
            tvControlModes[identity] = next.rawValue
            if !model.demo { UserDefaults.standard.set(tvControlModes, forKey: "sofatap.tvControlModes.v1") }
        }
#if SOFATAP_TV_UI_TESTING
        if model.demo { androidTV.fixtureModeSelection = next }
#endif
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private var televisionInputBar: some View {
        // Match the desktop card's physical keyboard and microphone anchors.
        HStack(spacing: 13) {
            Button {
                touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel(); edgeScrollControl.cancel()
                tvWantsDictation = false; composerVisible = true
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { tvKeyboardFocused.toggle() }
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                Image(systemName: tvKeyboardFocused ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 20)).frame(width: 48, height: 52)
                    .contentShape(Rectangle())
                    .foregroundStyle(Palette.mint.opacity(tvKeyboardFocused ? 1 : 0.65))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: tvKeyboardFocused)
                    .background(tvKeyboardFocused ? Palette.mint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(RemoteIconButtonStyle())
            .disabled(!androidTVSelected || !androidTV.connectionReady || androidTV.status?.tvControls == nil)
            .accessibilityValue(tvKeyboardFocused ? String(localized: "键盘已展开") : String(localized: "键盘已收起"))
            .accessibilityLabel(tvKeyboardFocused ? String(localized: "收起键盘") : String(localized: "打开键盘输入"))
            .accessibilityIdentifier("tvKeyboardButton")
            Spacer(minLength: 0)
            Button {
                touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel(); edgeScrollControl.cancel()
                composerVisible = true; tvKeyboardFocused = false
                dictationImpact.impactOccurred(); tvWantsDictation.toggle()
            } label: {
                ZStack {
                    Circle().fill(tvWantsDictation ? Color(red: 0.99, green: 0.64, blue: 0.47) : Palette.mint)
                    Circle().stroke(Palette.mint.opacity(0.18), lineWidth: 1).padding(-6)
                    Image(systemName: tvWantsDictation ? "stop.fill" : "mic.fill")
                        .font(.system(size: tvWantsDictation ? 19 : 25, weight: .medium))
                }
                .frame(width: 64, height: 64).contentShape(Circle()).foregroundStyle(Palette.background)
                .shadow(color: Palette.mint.opacity(0.13), radius: 18, y: 1)
            }
            .buttonStyle(MicrophoneButtonStyle(prepareFeedback: { dictationImpact.prepare() }))
            .disabled(!androidTVSelected || !inputEnabled || !androidTV.canEditTVText)
            .opacity(androidTVSelected && androidTV.canEditTVText ? 1 : 0.45)
            .accessibilityLabel(tvWantsDictation ? String(localized: "取消语音输入") : String(localized: "开始语音输入"))
            .accessibilityIdentifier("tvDictationButton")
            Spacer(minLength: 0)
            Color.clear.frame(width: 48, height: 52).allowsHitTesting(false)
        }
    }
    private var computerBottomBar: some View {
        HStack(spacing: 13) {
            Button { toggleKeyboard() } label: {
                Image(systemName: keyboardFocused ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 20)).frame(width: 48, height: 52)
                    .contentShape(Rectangle())
                    .foregroundStyle(Palette.mint.opacity(keyboardFocused ? 1 : 0.65))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: keyboardFocused)
                    .background(keyboardFocused ? Palette.mint.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(RemoteIconButtonStyle())
            .accessibilityValue(keyboardFocused ? String(localized: "键盘已展开") : String(localized: "键盘已收起"))
            .accessibilityLabel(keyboardFocused ? String(localized: "收起键盘") : String(localized: "打开键盘输入"))
            .accessibilityIdentifier("keyboardButton")
            Spacer(minLength: 0)
            Button { toggleDictation() } label: {
                ZStack {
                    Circle().fill(dictation.isRecording ? Color(red: 0.99, green: 0.64, blue: 0.47) : Palette.mint)
                    Circle().stroke(Palette.mint.opacity(0.18), lineWidth: 1).padding(-6)
                    if dictation.state == .requestingPermission || dictation.state == .finishing || (speechRequest != nil && model.editorLoading) {
                        ProgressView().tint(Palette.background)
                    } else {
                        Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: dictation.isRecording ? 19 : 25, weight: .medium))
                    }
                }
                .frame(width: 64, height: 64)
                .contentShape(Circle())
                .foregroundStyle(Palette.background)
                .shadow(color: Palette.mint.opacity(0.13), radius: 18, y: 1)
            }
            .buttonStyle(MicrophoneButtonStyle(prepareFeedback: { dictationImpact.prepare() }))
            .disabled(!model.controlAvailable || model.sendingText || model.composing || model.remoteTextFocus == .protected)
            .opacity(model.controlAvailable ? 1 : 0.45)
            .accessibilityLabel(dictation.isRecording ? String(localized: "结束听写") : speechBusy || speechRequest != nil ? String(localized: "取消语音输入") : String(localized: "开始语音输入"))
            .accessibilityValue(dictation.isRecording ? String(localized: "麦克风正在录音") : dictation.state == .finishing ? String(localized: "正在整理听写结果") : "")
            .accessibilityIdentifier("dictationButton")
            Spacer(minLength: 0)
            Button { volumeSheet = true } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 20)).frame(width: 48, height: 52)
                    .contentShape(Rectangle()).foregroundStyle(Palette.mint.opacity(0.65))
            }
            .buttonStyle(RemoteIconButtonStyle())
            .disabled(!interfaceAvailable)
            .accessibilityLabel(String(localized: "电脑系统音量"))
            .accessibilityIdentifier("systemVolumeButton")
        }
    }

    private var statusSymbol: String {
        if androidTVSelected {
            if androidTV.phase == .failed { return "exclamationmark" }
            return androidTV.canControl ? "checkmark" : androidTV.busy ? "ellipsis" : "tv"
        }
        if televisionSelected {
            if tv.phase == .failed { return "exclamationmark" }
            return tv.phase == .ready ? "checkmark" : tv.busy ? "ellipsis" : "tv"
        }
        if model.pairingError != nil { return "exclamationmark" }
        if model.demo { return "play.fill" }
        if model.connecting { return "ellipsis" }
        if model.canControl { return "checkmark" }
        return model.connected ? "pause.fill" : "link"
    }

    private var statusColor: Color {
        if androidTVSelected { return androidTV.phase == .failed ? .orange : androidTV.canControl ? Palette.mint : Palette.muted }
        if televisionSelected { return tv.phase == .failed ? .orange : tv.phase == .ready ? Palette.mint : Palette.muted }
        if model.pairingError != nil || model.demo || (model.connected && !model.inputAvailable) { return .orange }
        return model.canControl ? Palette.mint : Palette.muted
    }

    private func composer(height: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text(dictation.isRecording ? String(localized: "正在听…") : model.usesLiveText ? String(localized: "输入或听写，自动同步到电脑") : String(localized: "输入或听写，确认后发送到电脑"))
                            .font(.system(size: 16)).foregroundStyle(Palette.muted.opacity(0.7))
                            .padding(14).allowsHitTesting(false)
                    }
                    NativeDraftEditor(text: $model.draft, composing: $model.composing,
                                      isFocused: $keyboardFocused,
                                      disabled: speechBusy || model.editorLoading || (model.usesLiveText && !model.liveTextReady),
                                      selection: model.usesLiveText ? $model.draftSelection : nil,
                                      onEdit: { text, selection, marked in model.editText(text, selection: selection, marked: marked) },
                                      preservesFocusWhileLoading: model.editorLoading,
                                      liveEditing: model.usesLiveText,
                                      control: draftEditorControl,
                                      onEmptyBackspace: { model.keyboardBackspaceFromEmptyDraft() })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A separate column reserves room for Send, including while the
                // native editor scrolls or wraps text. Nothing overlays its text.
                composerSendButton
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
            .frame(height: height)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
            composerActions
        }
    }

    @ViewBuilder
    private var composerNotice: some View {
        if let message = composerMessage {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(model.textDelivery == .uncertain ? Color.orange : Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 8)
                .accessibilityIdentifier("textDeliveryStatus")
        }
    }

    private var composerMessage: String? {
        // Keep actionable delivery/connection states, without a permanent
        // capability label under the editor.
        if model.textDelivery == .uncertain || model.liveTextPaused { return model.textStatus }
        if !model.controlAvailable { return String(localized: "未连接电脑，草稿会保留在手机上。") }
        if model.remoteTextFocus == .protected || model.editorLoading || speechBusy || model.composing || !model.draftWithinLimit || model.sentTextWasEdited || model.textDelivery != .ready {
            return composerStatus
        }
        return nil
    }

    private var composerActions: some View {
        HStack(spacing: 2) {
            composerIcon("trash", label: String(localized: "清空草稿"), identifier: "clearTextDraft") {
                interruptTouch(); clearAlert = true
            }
            .disabled(model.draft.isEmpty || model.composing || model.sendingText || speechBusy || (model.usesLiveText && !model.liveTextReady))
            composerIcon(keyboardFocused ? "arrow.down" : "arrow.up",
                         label: keyboardFocused ? String(localized: "收起键盘") : String(localized: "打开键盘输入"),
                         identifier: "hideKeyboard") { toggleKeyboard() }
                .accessibilityValue(keyboardFocused ? String(localized: "键盘已展开") : String(localized: "键盘已收起"))
            composerIcon("delete.left", label: String(localized: "电脑退格"), identifier: "remoteBackspace") {
                guard draftEditorControl.flushForSend() else { return }
                interruptTouch()
                model.remoteBackspace()
            }
            .disabled(!model.canRemoteBackspace || speechBusy)
            if model.liveTextPaused {
                composerIcon("arrow.clockwise", label: String(localized: "检查电脑后重新读取输入框"), identifier: "resumeLiveText") {
                    model.restartLiveTextEditing()
                }
            } else if !model.usesLiveText && (model.textDelivery == .uncertain || model.textDelivery == .sent || model.sentTextWasEdited) {
                composerIcon("arrow.clockwise", label: String(localized: "检查电脑后允许重发"), identifier: "allowTextResend") {
                    interruptTouch(); resendAlert = true
                }
                .disabled(model.sendingText || speechBusy)
            }
            Spacer(minLength: 0)
            composerNotice
        }
        .frame(minHeight: 44)
    }

    private var composerSendButton: some View {
        Button(action: sendCurrentDraft) {
            Group {
                if model.sendingText || model.liveTextStatus == .syncing { ProgressView().tint(Palette.background) }
                else { Image(systemName: model.liveTextReady ? "checkmark" : "arrow.up").font(.system(size: 19, weight: .semibold)) }
            }
            .frame(width: 44, height: 44)
            .foregroundStyle(Palette.background)
            .background(Palette.mint, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canAttemptSend)
        .opacity(canAttemptSend || model.sendingText ? 1 : 0.45)
        .accessibilityLabel(model.usesLiveText ? String(localized: "实时同步") : String(localized: "发送"))
        .accessibilityIdentifier("sendText")
    }

    private func composerIcon(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: keyboardFocused)
                .frame(width: 44, height: 44)
                .foregroundStyle(Palette.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(RemoteIconButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var canAttemptSend: Bool {
        // Keep the control stable, including after an ACK. A native keyboard can
        // update its text storage before publishing the binding; flush it first.
        !model.usesLiveText && inputEnabled && !model.sendingText && !speechBusy && model.textDelivery != .uncertain
    }

    private func sendCurrentDraft() {
        guard canAttemptSend, draftEditorControl.flushForSend() else { return }
        model.sendText()
    }

    private var composerStatus: String {
        if dictation.isRecording { return model.usesLiveText ? String(localized: "正在听写并实时同步…") : String(localized: "正在听写，结束后确认文字再发送。") }
        if dictation.state == .finishing { return String(localized: "正在整理听写结果…") }
        if model.remoteTextFocus == .protected { return String(localized: "电脑当前为安全输入框，不会自动听写。") }
        if model.demo && model.textDelivery == .sent { return String(localized: "演示反馈：文字没有发送到电脑。") }
        return model.textStatus
    }

    private func toggleKeyboard() {
        guard !televisionSelected else { return }
        interruptTouch()
        cancelSpeech()
        UISelectionFeedbackGenerator().selectionChanged()
        // Keep the draft and its toggle visible after dismissing the keyboard.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
            composerVisible = true
            keyboardFocused.toggle()
        }
        if keyboardFocused { model.openTextEditor() }
    }
    private func toggleDictation() {
        guard !televisionSelected, model.controlAvailable, !model.sendingText, !model.composing, model.remoteTextFocus != .protected else { return }
        let releasedDrag = model.dragging
        interruptTouch()
        if dictation.isRecording {
            // Recording suppresses haptics. Stop capture and release its audio
            // session before acknowledging the explicit stop tap.
            dictation.stop()
            dictationImpact.impactOccurred()
            return
        }
        if speechBusy || speechRequest != nil {
            cancelSpeech()
            if !releasedDrag { dictationImpact.impactOccurred() }
            return
        }
        // A drag release already supplies feedback. This confirms the tap,
        // not microphone authorization or a successful recording start.
        if !releasedDrag { dictationImpact.impactOccurred() }
        keyboardFocused = false
        composerVisible = true
        let request = UUID(); speechRequest = request
        model.openTextEditor {
            guard !televisionSelected, speechRequest == request, model.controlAvailable, scenePhase == .active else { return }
            speechBaseDraft = model.draft
            speechBaseSnapshot = model.liveTextReady ? LiveTextSnapshot(text: model.draft, selection: model.draftSelection) : nil
            speechOwnsDraft = true
            dictationStartTask?.cancel()
            dictationStartTask = Task {
                guard !Task.isCancelled, !televisionSelected, speechRequest == request, model.controlAvailable, scenePhase == .active else { return }
                await dictation.start()
            }
        }
    }
    private func applyRemoteFocus() {
        guard let focus = remoteFocus.next(revision: model.focusRevision, focus: model.remoteTextFocus,
                                          interactionAvailable: !televisionSelected && model.canControl && interfaceAvailable,
                                          dragging: model.dragging, speechBusy: speechBusy) else { return }
        switch focus {
        case .editable:
            interruptTouch()
            composerVisible = true
            keyboardFocused = true
            model.openTextEditor()
        case .other, .protected:
            keyboardFocused = false
            cancelSpeech()
        case .unknown:
            break // Unsupported desktop focus detection leaves manual input available.
        }
    }
    private func stopInteraction() {
        interruptTouch()
        keyboardFocused = false
        tvKeyboardFocused = false; tvWantsDictation = false
        cancelSpeech()
        model.endLiveTextEditing()
    }
    private func cancelSpeech() {
        speechRequest = nil
        dictationStartTask?.cancel()
        dictation.cancel()
        speechOwnsDraft = false
    }
    private func interruptTouch() {
        edgeScrollControl.cancel()
        touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel()
        model.pauseInput()
        tv.pauseInput()
        androidTV.pauseInput()
    }
    private func selectTelevision() {
        stopInteraction()
        androidTV.setTargetSelected(false)
        androidSelected = false
        composerVisible = false
        model.setDesktopControlEnabled(false)
        tv.disconnect()
    }
    private func selectAndroidTelevision() {
        stopInteraction()
        composerVisible = false
        tv.disconnect()
        androidTV.disconnect()
        androidTV.setTargetSelected(true, reconnect: false)
        androidSelected = true
        model.setDesktopControlEnabled(false, televisionTarget: "androidtv")
    }
    private func selectComputer(reconnect: Bool = true) {
        stopInteraction()
        tv.disconnect()
        androidTV.setTargetSelected(false)
        androidSelected = false
        composerVisible = false
        remoteFocus.reset()
        model.setDesktopControlEnabled(true, reconnect: reconnect)
    }
    private func resumeCurrentInput() {
        guard inputSessionAvailable else { return }
        if androidTVSelected { androidTV.resumeInput() }
        else if televisionSelected { tv.resumeInput() }
        else { applyRemoteFocus() }
    }
    private func performGestureShortcut(_ action: GestureAction) {
        guard inputEnabled else { return }
        switch action {
        case .confirm:
            if androidTVSelected { androidTV.key(.confirm) }
            else if televisionSelected { tv.button(.enter) }
            else { model.key("enter") }
        case .back:
            if androidTVSelected { androidTV.key(.back) }
            else if televisionSelected { tv.button(.back) }
            else { model.key("escape") }
        case .home:
            if androidTVSelected { androidTV.key(.home) }
            else if televisionSelected { tv.button(.home) }
        case .toggleKeyboard:
            if !televisionSelected { toggleKeyboard() }
        case .toggleDictation:
            if !televisionSelected { toggleDictation() }
        default: break
        }
    }
    private func scrollCurrentDevice(_ delta: Double) {
        if androidTVSelected { androidTV.scroll(dy: delta) }
        else if televisionSelected { tv.scroll(dy: delta) }
        else { model.scroll(dy: delta) }
    }
}

private struct MicrophoneButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let prepareFeedback: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? 0.90 : 1)
            .brightness(pressed ? -0.12 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: pressed ? 0.10 : 0.16), value: pressed)
            // Keep the full target while its visible surface compresses.
            .frame(width: 64, height: 64)
            .contentShape(Circle())
            .onChange(of: pressed) { _, down in
                if down { prepareFeedback() }
            }
    }
}

private struct SystemVolumeSheet: View {
    @ObservedObject var model: ControllerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var unavailableMessage: String? {
        if model.demo { return String(localized: "界面演示：按钮只展示反馈，没有连接或操作电脑。") }
        if !model.connected { return String(localized: "连接电脑后即可调节系统音量。") }
        if !model.inputAvailable { return model.receiverState.unavailableMessage }
        if !model.receiverState.supportsSystemVolume {
            return String(localized: "当前接收器或输出设备不支持音量控制。请更新电脑接收器或切换输出设备。")
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    volumeButton(.down, title: String(localized: "音量减"), symbol: "speaker.wave.1")
                    volumeButton(.up, title: String(localized: "音量加"), symbol: "speaker.wave.3")
                    volumeButton(.mute, title: String(localized: "静音切换"), symbol: "speaker.slash")
                } header: {
                    Text(model.computerName)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "调节电脑默认输出设备的音量。"))
                        if let message = unavailableMessage ?? model.volumeFeedback { Text(message) }
                        if model.volumeBusy { ProgressView() }
                    }
                }
                .listRowBackground(Palette.panel)
            }
            .scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle(String(localized: "电脑系统音量"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .tint(Palette.mint).preferredColorScheme(.dark)
    }

    private func volumeButton(_ command: SystemVolumeCommand, title: String, symbol: String) -> some View {
        Button { model.changeSystemVolume(command) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .disabled(!model.canChangeSystemVolume || scenePhase != .active)
        .accessibilityIdentifier("systemVolume_\(command.rawValue)")
    }
}

#Preview { RemoteView(model: ControllerModel(demo: true)).preferredColorScheme(.dark) }
