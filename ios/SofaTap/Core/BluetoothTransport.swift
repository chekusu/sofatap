import Foundation
import CoreBluetooth
import Network
import CryptoKit

/// Opaque TLS bytes only. No pairing tokens, plaintext commands, or input injection
/// belong in this layer. A failed stream is discarded, never replayed on reconnect.
struct BluetoothByteBuffer {
    static let limit = 65_536
    private var bytes = Data()
    private var closed = false
    var count: Int { bytes.count }
    mutating func append(_ data: Data) throws {
        guard !closed, data.count <= Self.limit - bytes.count else { throw URLError(.dataLengthExceedsMaximum) }
        bytes.append(data)
    }
    func next(maximum: Int) -> Data? {
        guard !closed, maximum > 0, !bytes.isEmpty else { return nil }
        return Data(bytes.prefix(maximum))
    }
    mutating func consume(_ count: Int) throws {
        guard !closed, count > 0, count <= bytes.count else { throw URLError(.badServerResponse) }
        bytes.removeFirst(count)
    }
    mutating func close() { bytes.removeAll(); closed = true }
}

enum BluetoothWire {
    // A versioned, receiver-specific service. Discovery is not authentication:
    // PinnedSessionDelegate still verifies the full certificate fingerprint.
    static func service(fingerprint: String) -> CBUUID {
        let digest = Array(SHA256.hash(data: Data(("Sofatap BLE v1:" + fingerprint.lowercased()).utf8)))
        return CBUUID(data: Data(digest.prefix(16)))
    }
    static let upstream = CBUUID(string: "B585B001-7F81-48B1-92BD-2E99FD908511")
    static let downstream = CBUUID(string: "B585B002-7F81-48B1-92BD-2E99FD908511")
    static let ready: UInt8 = 0
    static let payload: UInt8 = 1
    static let closed: UInt8 = 2
}

/// Serial-queue socket adapter. Reading waits for radio backpressure; writing is
/// bounded even if notifications arrive faster than loopback can consume them.
final class BluetoothSocketPipe {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var pendingBytes = 0
    private var stopped = false
    var onReady: (() -> Void)?
    var onData: ((Data, @escaping () -> Void) -> Void)?
    var onClose: (() -> Void)?

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection; self.queue = queue
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready: self.onReady?(); self.read()
            case .failed, .cancelled: self.stop()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func read() {
        guard !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            guard error == nil else { self.stop(); return }
            guard let data, !data.isEmpty else {
                if complete { self.stop() } else { self.read() }; return
            }
            self.onData?(data) { [weak self] in
                guard let self, !self.stopped else { return }
                if complete { self.stop() } else { self.read() }
            }
        }
    }
    func write(_ data: Data, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !stopped, data.count <= BluetoothByteBuffer.limit - pendingBytes else {
            completion(false); stop(); return
        }
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.stopped else { return }
            self.pendingBytes -= data.count
            completion(error == nil)
            if error != nil { self.stop() }
        })
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        connection.stateUpdateHandler = nil; connection.cancel()
        let callback = onClose
        onReady = nil; onData = nil; onClose = nil
        callback?()
    }
}

/// iPhone central, with a loopback listener consumed by the existing pinned WSS
/// client. Explicit BLE mode never falls back to LAN or AWDL.
final class BluetoothTLSBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Sofatap BLE central")
    private let serviceID: CBUUID
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var upstream: CBCharacteristic?
    private var downstream: CBCharacteristic?
    private var listener: NWListener?
    private var pipe: BluetoothSocketPipe?
    private var completion: ((Result<UInt16, Error>) -> Void)?
    private var outgoing = BluetoothByteBuffer()
    private var resumeRead: (() -> Void)?
    private var writing = 0
    private var started = false
    private var stopped = false

    init(fingerprint: String) { serviceID = BluetoothWire.service(fingerprint: fingerprint); super.init() }
    func start() async throws -> UInt16 {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !started, !stopped else { continuation.resume(throwing: URLError(.cancelled)); return }
                    started = true; completion = { continuation.resume(with: $0) }
                    manager = CBCentralManager(delegate: self, queue: queue,
                        options: [CBCentralManagerOptionShowPowerAlertKey: false])
                    queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                        guard let self, self.completion != nil else { return }
                        self.finish(URLError(.timedOut))
                    }
                }
            }
            try Task.checkCancellation()
            return port
        } onCancel: { self.stop() }
    }
    func stop() { queue.async { [self] in finish(URLError(.cancelled)) } }
    private func finish(_ error: Error) {
        guard !stopped else { return }; stopped = true
        manager?.stopScan()
        if let peripheral { peripheral.delegate = nil; manager?.cancelPeripheralConnection(peripheral) }
        manager?.delegate = nil; manager = nil; peripheral = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        pipe?.stop(); pipe = nil
        outgoing.close(); resumeRead = nil; writing = 0
        let callback = completion; completion = nil; callback?(.failure(error))
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !stopped else { return }
        switch central.state {
        case .poweredOn: central.scanForPeripherals(withServices: [serviceID])
        case .unknown, .resetting: break
        default: finish(URLError(.notConnectedToInternet))
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover candidate: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped, peripheral == nil else { return }
        peripheral = candidate; candidate.delegate = self
        central.stopScan(); central.connect(candidate)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !stopped, peripheral === self.peripheral else { return }
        peripheral.discoverServices([serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(error ?? URLError(.cannotConnectToHost))
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        finish(error ?? URLError(.networkConnectionLost))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopped else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            finish(error ?? URLError(.badServerResponse)); return
        }
        peripheral.discoverCharacteristics([BluetoothWire.upstream, BluetoothWire.downstream], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !stopped else { return }
        upstream = service.characteristics?.first { $0.uuid == BluetoothWire.upstream }
        downstream = service.characteristics?.first { $0.uuid == BluetoothWire.downstream }
        guard error == nil, let upstream, upstream.properties.contains(.write),
              let downstream, downstream.properties.contains(.notify) else {
            finish(error ?? URLError(.badServerResponse)); return
        }
        peripheral.setNotifyValue(true, for: downstream)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped else { return }
        if error != nil || !characteristic.isNotifying { finish(error ?? URLError(.networkConnectionLost)) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped else { return }
        guard error == nil, characteristic.uuid == BluetoothWire.downstream,
              let data = characteristic.value, let kind = data.first else {
            finish(error ?? URLError(.badServerResponse)); return
        }
        switch kind {
        case BluetoothWire.ready:
            guard data.count == 1, listener == nil else { finish(URLError(.badServerResponse)); return }
            openListener()
        case BluetoothWire.payload:
            guard data.count > 1, let pipe else { finish(URLError(.badServerResponse)); return }
            pipe.write(Data(data.dropFirst()))
        default: finish(URLError(.networkConnectionLost))
        }
    }
    private func openListener() {
        do {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            parameters.acceptLocalOnly = true
            let listener = try NWListener(using: parameters); self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { self.finish(URLError(.cannotConnectToHost)); return }
                    let callback = self.completion; self.completion = nil; callback?(.success(port.rawValue))
                case .failed(let error): self.finish(error)
                case .cancelled: self.finish(URLError(.cancelled))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped, self.pipe == nil else { connection.cancel(); return }
                let pipe = BluetoothSocketPipe(connection, queue: self.queue); self.pipe = pipe
                pipe.onClose = { [weak self] in self?.finish(URLError(.networkConnectionLost)) }
                pipe.onData = { [weak self] data, resume in
                    guard let self, !self.stopped else { return }
                    do { try self.outgoing.append(data); self.resumeRead = resume; self.flush() }
                    catch { self.finish(error) }
                }
                pipe.start()
            }
            listener.start(queue: queue)
        } catch { finish(error) }
    }
    private func flush() {
        guard !stopped, writing == 0, let peripheral, let upstream else { return }
        if let packet = outgoing.next(maximum: peripheral.maximumWriteValueLength(for: .withResponse)) {
            writing = packet.count
            // ATT response is backpressure, not confirmation that input was applied.
            // The existing application ACK dispatcher remains authoritative.
            peripheral.writeValue(packet, for: upstream, type: .withResponse)
        } else {
            let resume = resumeRead; resumeRead = nil; resume?()
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopped else { return }
        guard error == nil, characteristic.uuid == BluetoothWire.upstream, writing > 0 else {
            finish(error ?? URLError(.badServerResponse)); return
        }
        do { try outgoing.consume(writing); writing = 0; flush() } catch { finish(error) }
    }
}

/// Mac peripheral. Explicit user opt-in owns its lifetime. One subscriber maps
/// to one helper TLS socket; closing that socket invokes existing button cleanup.
final class MacBluetoothRelay: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Sofatap BLE receiver")
    private let serviceID: CBUUID
    private let port: UInt16
    private var manager: CBPeripheralManager?
    private var upstream: CBMutableCharacteristic?
    private var downstream: CBMutableCharacteristic?
    private var central: CBCentral?
    private var pipe: BluetoothSocketPipe?
    private var outgoing = BluetoothByteBuffer()
    private var resumeRead: (() -> Void)?
    private var readyPending = false
    private var backendReady = false
    private var stopped = false
    private var epoch = UUID()
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private let status: @Sendable (String) -> Void

    init(backendPort: UInt16, fingerprint: String, status: @escaping @Sendable (String) -> Void) {
        port = backendPort; serviceID = BluetoothWire.service(fingerprint: fingerprint)
        self.status = status; super.init()
    }
    func start() {
        queue.async { [self] in
            guard !stopped, manager == nil else { return }
            manager = CBPeripheralManager(delegate: self, queue: queue,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
            watchdog()
        }
    }
    func stop() {
        queue.async { [self] in
            guard !stopped else { return }; stopped = true
            endSession(); manager?.stopAdvertising()
            if manager?.state == .poweredOn { manager?.removeAllServices() }
            manager?.delegate = nil; manager = nil
        }
    }
    private func watchdog() {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.central != nil && ProcessInfo.processInfo.systemUptime - self.lastActivity > 20 { self.endSession() }
            self.watchdog()
        }
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard !stopped else { return }
        endSession(); peripheral.stopAdvertising()
        guard peripheral.state == .poweredOn else {
            status(peripheral.state == .unauthorized ? "蓝牙权限未开启" : "蓝牙不可用"); return
        }
        peripheral.removeAllServices()
        let up = CBMutableCharacteristic(type: BluetoothWire.upstream, properties: [.write], value: nil, permissions: [.writeable])
        let down = CBMutableCharacteristic(type: BluetoothWire.downstream, properties: [.notify], value: nil, permissions: [.readable])
        upstream = up; downstream = down
        let service = CBMutableService(type: serviceID, primary: true); service.characteristics = [up, down]
        peripheral.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard !stopped else { return }
        guard error == nil else { status("蓝牙服务启动失败"); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard !stopped else { return }
        status(error == nil ? "蓝牙实验模式 · 等待 iPhone" : "蓝牙广播启动失败")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central candidate: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard !stopped, characteristic.uuid == BluetoothWire.downstream else { return }
        guard central == nil else {
            if central?.identifier != candidate.identifier, let downstream {
                _ = peripheral.updateValue(Data([BluetoothWire.closed]), for: downstream, onSubscribedCentrals: [candidate])
            }
            return
        }
        central = candidate; epoch = UUID(); let current = epoch
        outgoing = BluetoothByteBuffer(); lastActivity = ProcessInfo.processInfo.systemUptime
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
        let pipe = BluetoothSocketPipe(connection, queue: queue); self.pipe = pipe
        pipe.onReady = { [weak self] in
            guard let self, self.epoch == current else { return }
            self.backendReady = true; self.readyPending = true; self.flush()
            self.status("蓝牙通道已连接 · 身份验证由接收器确认")
        }
        pipe.onClose = { [weak self] in
            guard let self, self.epoch == current else { return }; self.endSession()
        }
        pipe.onData = { [weak self] data, resume in
            guard let self, self.epoch == current else { return }
            do { try self.outgoing.append(data); self.resumeRead = resume; self.flush() }
            catch { self.endSession() }
        }
        pipe.start()
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard central.identifier == self.central?.identifier else { return }; endSession()
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard !stopped, backendReady, let pipe, requests.allSatisfy({
            $0.central.identifier == central?.identifier && $0.characteristic.uuid == BluetoothWire.upstream &&
            $0.offset == 0 && $0.value?.isEmpty == false
        }) else { peripheral.respond(to: first, withResult: .writeNotPermitted); return }
        let byteCount = requests.reduce(0) { $0 + ($1.value?.count ?? 0) }
        guard byteCount <= BluetoothByteBuffer.limit else { peripheral.respond(to: first, withResult: .invalidAttributeValueLength); endSession(); return }
        let data = requests.reduce(into: Data()) { $0.append($1.value!) }
        let current = epoch
        lastActivity = ProcessInfo.processInfo.systemUptime
        pipe.write(data) { [weak self] success in
            guard let self, self.epoch == current else { return }
            peripheral.respond(to: first, withResult: success ? .success : .unlikelyError)
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flush() }
    private func flush() {
        guard !stopped, let manager, let central, let downstream else { return }
        if readyPending {
            guard manager.updateValue(Data([BluetoothWire.ready]), for: downstream, onSubscribedCentrals: [central]) else { return }
            readyPending = false
        }
        while let packet = outgoing.next(maximum: central.maximumUpdateValueLength - 1) {
            guard manager.updateValue(Data([BluetoothWire.payload]) + packet, for: downstream, onSubscribedCentrals: [central]) else { return }
            do { try outgoing.consume(packet.count) } catch { endSession(); return }
            lastActivity = ProcessInfo.processInfo.systemUptime
        }
        let resume = resumeRead; resumeRead = nil; resume?()
    }
    private func endSession() {
        epoch = UUID()
        if manager?.state == .poweredOn, let central, let downstream {
            _ = manager?.updateValue(Data([BluetoothWire.closed]), for: downstream, onSubscribedCentrals: [central])
        }
        central = nil; backendReady = false; readyPending = false
        pipe?.stop(); pipe = nil; outgoing.close(); resumeRead = nil
    }
}
