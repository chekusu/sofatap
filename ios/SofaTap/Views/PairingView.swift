import SwiftUI

struct PairingView: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var tv: WebOSTVController
    @ObservedObject var androidTV: AndroidTVController
    let selectAndroidTV: () -> Void
    let selectTV: () -> Void
    let selectComputer: () -> Void
    let androidSelected: Bool
    @Binding var incomingLink: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAddDevice = false
    @State private var renameTarget: DeviceTarget?
    @State private var removeTarget: DeviceTarget?
    @State private var editedName = ""

    private struct DeviceTarget: Identifiable {
        enum Kind { case computer, android, webos }
        let id: UUID
        let kind: Kind
        let name: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    savedDevices
                    if model.desktopControlEnabled && model.peerConnectionAvailable { connectionModeSettings }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "添加设备")).font(.headline)
                        Button { showingAddDevice = true } label: {
                            Label(String(localized: "扫描二维码"), systemImage: "qrcode.viewfinder")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(.borderedProminent).foregroundStyle(Palette.background)
                            .accessibilityIdentifier("addDeviceScanner")
                    }
                    if let error = model.pairingError { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if let error = androidTV.managementError { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if let error = tv.managementError { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if !model.desktopControlEnabled && androidSelected &&
                        (androidTV.phase == .failed || (androidTV.phase == .ready && androidTV.status?.available != true)) {
                        Text(androidTV.notice).font(.footnote).foregroundStyle(.orange)
                    }
                    if !model.desktopControlEnabled && !androidSelected && tv.phase == .failed {
                        Text(tv.notice).font(.footnote).foregroundStyle(.orange)
                    }
                    if model.desktopControlEnabled && model.pairing != nil &&
                        (!model.connected || !model.inputAvailable) && model.pairingError == nil {
                        Text(model.notice).font(.footnote).foregroundStyle(Palette.muted)
                    }
                    if model.unlock.savedBinding != nil { LegacyUnlockCredentialRemovalView(unlock: model.unlock) }
                    Text(String(localized: "一次只控制当前选择的设备。切换设备不会自动发送手机草稿。"))
                        .font(.footnote).foregroundStyle(Palette.muted)
                }.padding(20)
            }
            .background(Palette.background)
            .navigationTitle(String(localized: "我的设备"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { dismiss() } } }
            .sheet(isPresented: $showingAddDevice) {
                AddDeviceView(model: model, tv: tv, androidTV: androidTV,
                              selectAndroidTV: selectAndroidTV, selectTV: selectTV, selectComputer: selectComputer,
                              incomingLink: $incomingLink, finishPairing: { showingAddDevice = false; dismiss() })
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: incomingLink) { _, link in if link != nil { showingAddDevice = true } }
            .onDisappear { model.stopPeerAvailabilityMonitoring() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.startPeerAvailabilityMonitoring() }
                else { model.stopPeerAvailabilityMonitoring() }
            }
            .onChange(of: model.pairing) { _, _ in model.startPeerAvailabilityMonitoring() }
            .onChange(of: model.desktopControlEnabled) { _, _ in model.startPeerAvailabilityMonitoring() }
            .onAppear {
                model.startPeerAvailabilityMonitoring()
                if incomingLink != nil { showingAddDevice = true }
#if targetEnvironment(simulator)
                if model.demo { showingAddDevice = (ProcessInfo.processInfo.arguments.contains("--demo-add-device") ||
                                                  ProcessInfo.processInfo.arguments.contains("--demo-added-device")) }
#endif
            }
            .alert(String(localized: "重命名设备"), isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField(String(localized: "设备名称"), text: $editedName)
                Button(String(localized: "取消"), role: .cancel) { renameTarget = nil }
                Button(String(localized: "保存")) { saveName() }
            } message: { Text(String(localized: "名称只在这台 iPhone 上更改。")) }
            .alert(String(localized: "移除此设备？"), isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
                Button(String(localized: "取消"), role: .cancel) { removeTarget = nil }
                Button(String(localized: "移除"), role: .destructive) { removeDevice() }
            } message: { Text(String(localized: "仅从这台 iPhone 移除，不会关闭接收器或影响其他手机。再次连接需要重新配对。")) }
        }
        .tint(Palette.mint).preferredColorScheme(.dark)
    }

    private var connectionModeSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "连接模式")).font(.headline)
            Picker(String(localized: "连接模式"), selection: Binding(
                get: { model.connectionMode }, set: { model.setConnectionMode($0) }
            )) {
                Text(String(localized: "自动（优先直连）")).tag(DesktopConnectionMode.automatic)
                Text(String(localized: "普通 Wi-Fi")).tag(DesktopConnectionMode.wifi)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("desktopConnectionMode")
            Text(String(localized: "自动模式优先使用可用的设备直连，否则使用普通 Wi-Fi。切换模式会重新连接，选择会保留。"))
                .font(.footnote).foregroundStyle(Palette.muted)
            if model.connected {
                Text(model.usesPeerTransport ? String(localized: "已连接 · 设备直连") : String(localized: "已连接 · 普通 Wi-Fi"))
                    .font(.footnote).foregroundStyle(Palette.mint)
            }
        }
    }

    @ViewBuilder private var savedDevices: some View {
        if model.savedDevices.isEmpty && androidTV.savedDevices.isEmpty && tv.savedDevices.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 28)).foregroundStyle(Palette.mint)
                Text(String(localized: "还没有配对设备")).font(.headline)
                Text(String(localized: "添加电脑或电视，之后可在这里快速切换。"))
                    .font(.subheadline).foregroundStyle(Palette.muted)
            }.padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "已保存的设备")).font(.headline)
                ForEach(model.savedDevices) { device in
                    deviceRow(id: device.id, name: device.displayName,
                              detail: computerPlatform(device.platform) + " · " + device.credential.host,
                              symbol: device.platform == "macos" ? "laptopcomputer" : "desktopcomputer",
                              kind: .computer, selected: model.desktopControlEnabled && model.selectedDeviceID == device.id,
                              connected: model.connected, busy: model.connecting) {
                        selectComputer()
                        model.selectDevice(device.id)
                        if model.pairingError == nil && model.selectedDeviceID == device.id { dismiss() }
                    }
                }
                ForEach(androidTV.savedDevices) { device in
                    deviceRow(id: device.id, name: device.displayName, detail: "Android TV · " + device.credential.host,
                              symbol: "tv", kind: .android,
                              selected: !model.desktopControlEnabled && androidSelected && androidTV.selectedDeviceID == device.id,
                              connected: androidTV.phase == .ready, busy: androidTV.busy) {
                        selectAndroidTV()
                        androidTV.selectDevice(device.id)
                        if androidTV.managementError == nil && androidTV.selectedDeviceID == device.id { dismiss() }
                    }
                }
                ForEach(tv.savedDevices) { device in
                    deviceRow(id: device.id, name: device.displayName, detail: "LG webOS · " + device.credential.host,
                              symbol: "tv", kind: .webos,
                              selected: !model.desktopControlEnabled && !androidSelected && tv.selectedDeviceID == device.id,
                              connected: tv.phase == .ready, busy: tv.busy) {
                        selectTV()
                        tv.selectDevice(device.id)
                        if tv.managementError == nil && tv.selectedDeviceID == device.id { dismiss() }
                    }
                }
            }
        }
    }

    private func deviceRow(id: UUID, name: String, detail: String, symbol: String, kind: DeviceTarget.Kind,
                           selected: Bool, connected: Bool, busy: Bool, select: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                select()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol).font(.system(size: 23)).frame(width: 32)
                        .foregroundStyle(selected ? Palette.mint : Palette.muted)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                        if selected {
                            Label(busy ? String(localized: "正在安全连接…") : connected ? String(localized: "当前设备 · 已连接") : String(localized: "当前设备 · 未连接"),
                                  systemImage: connected ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(connected ? Palette.mint : Palette.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 14).padding(.leading, 14).contentShape(Rectangle())
            }.buttonStyle(RemoteIconButtonStyle())
            Menu {
                Button { editedName = name; renameTarget = DeviceTarget(id: id, kind: kind, name: name) } label: {
                    Label(String(localized: "重命名设备"), systemImage: "pencil")
                }
                if selected && (connected || busy) {
                    Button {
                        switch kind {
                        case .computer: model.disconnectDevice()
                        case .android: androidTV.disconnect()
                        case .webos: tv.disconnect()
                        }
                    } label: { Label(String(localized: "断开连接"), systemImage: "pause.circle") }
                }
                Button(role: .destructive) { removeTarget = DeviceTarget(id: id, kind: kind, name: name) } label: {
                    Label(String(localized: "移除配对"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20)).frame(width: 44, height: 52).contentShape(Rectangle())
            }.accessibilityLabel(String(localized: "管理设备") + ", " + name)
        }
        .background(selected ? Palette.mint.opacity(0.075) : Palette.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? Palette.mint.opacity(0.36) : .clear, lineWidth: 1))
    }

    private func computerPlatform(_ value: String?) -> String {
        switch value { case "macos": return "Mac"; case "windows": return "Windows"; case "linux": return "Linux"; default: return String(localized: "电脑") }
    }
    private func saveName() {
        guard let target = renameTarget else { return }
        switch target.kind {
        case .computer: model.renameDevice(target.id, name: editedName)
        case .android: androidTV.renameDevice(target.id, name: editedName)
        case .webos: tv.renameDevice(target.id, name: editedName)
        }
        renameTarget = nil
    }
    private func removeDevice() {
        guard let target = removeTarget else { return }
        switch target.kind {
        case .computer: model.removeDevice(target.id)
        case .android: androidTV.removeDevice(target.id)
        case .webos: tv.removeDevice(target.id)
        }
        removeTarget = nil
    }
}
