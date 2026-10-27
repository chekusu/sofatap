import Foundation

@main struct BluetoothTransportTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); checks += 1
        }
        let source = Data((0..<16384).map { UInt8($0 % 251) })
        for mtu in [20, 64, 185, 512] {
            var buffer = BluetoothByteBuffer()
            try buffer.append(source)
            var delivered = Data()
            while let packet = buffer.next(maximum: mtu) {
                check(buffer.next(maximum: mtu) == packet, "backpressure retains identical bytes")
                delivered.append(packet)
                try buffer.consume(packet.count)
            }
            check(delivered == source && buffer.count == 0, "fragmentation is byte exact")
        }
        var full = BluetoothByteBuffer()
        try full.append(Data(repeating: 1, count: BluetoothByteBuffer.limit))
        do { try full.append(Data([2])); fatalError("overflow accepted") } catch { checks += 1 }
        check(full.count == BluetoothByteBuffer.limit, "overflow does not mutate buffered stream")
        check(full.next(maximum: 0) == nil, "invalid MTU cannot spin")
        full.close()
        check(full.count == 0 && full.next(maximum: 20) == nil, "close discards queued bytes")
        do { try full.append(Data([3])); fatalError("closed stream reused") } catch { checks += 1 }
        var invalid = BluetoothByteBuffer()
        try invalid.append(Data([1,2,3]))
        do { try invalid.consume(4); fatalError("overconsume accepted") } catch { checks += 1 }
        check(invalid.count == 3, "invalid completion cannot lose bytes")
        let fp = String(repeating: "a1", count: 32)
        check(BluetoothWire.service(fingerprint: fp) == BluetoothWire.service(fingerprint: fp.uppercased()), "service ID ignores hex case")
        check(BluetoothWire.service(fingerprint: fp) != BluetoothWire.service(fingerprint: String(repeating: "b2", count: 32)), "receiver discovery is identity scoped")
        print("Bluetooth bounded transport: \(checks) checks passed (no radio or OS input)")
    }
}
