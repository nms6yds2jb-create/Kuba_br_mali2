import XCTest
@testable import KubaCore

final class HexAndChecksumTests: XCTestCase {
    func testHexRoundTrip() throws {
        let data = try Data(hex: "0x55 aa:01-FF")
        XCTAssertEqual(Array(data), [0x55, 0xAA, 0x01, 0xFF])
        XCTAssertEqual(data.hexString(), "55 AA 01 FF")
        XCTAssertThrowsError(try Data(hex: "ABC"))
        XCTAssertThrowsError(try Data(hex: "ZZ"))
    }

    func testChecksums() {
        let bytes = Array("123456789".utf8)
        XCTAssertEqual(Checksum.crc32(bytes), 0xCBF4_3926)
        XCTAssertEqual(Checksum.crc16CCITT(bytes), 0x29B1)
        XCTAssertEqual(Checksum.sum8([0xFF, 0x02]), 0x01)
        XCTAssertEqual(Checksum.xor8([0x0F, 0xF0]), 0xFF)
    }
}

final class TemplateTests: XCTestCase {
    func testFixedAndParams() throws {
        let t = CommandTemplate("AA01 {mode} {v:u16le} {w:u16be} {n:i8}")
        let out = try t.build(["mode": .int(2), "v": .int(0x1234), "w": .int(0x1234), "n": .int(-1)])
        XCTAssertEqual(Array(out), [0xAA, 0x01, 0x02, 0x34, 0x12, 0x12, 0x34, 0xFF])
    }

    func testLengthSequenceAndChecksum() throws {
        let t = CommandTemplate("55 AA {len:u8:1} {seq} 01 {mode} {sum8:2}")
        let out = try t.build(["mode": .int(1)], sequence: 7)
        // len = seq + cmd + mode = 3; sum = 03+07+01+01 = 0C
        XCTAssertEqual(Array(out), [0x55, 0xAA, 0x03, 0x07, 0x01, 0x01, 0x0C])
    }

    func testBigEndianLengthWithTrailer() throws {
        let out = try CommandTemplate("FE DC BA C0 03 {len:u16be:1} {seq} FF FF FF FF EF").build(sequence: 1)
        XCTAssertEqual(out.hexString(), "FE DC BA C0 03 00 05 01 FF FF FF FF EF")
    }

    func testCrc16() throws {
        let out = try CommandTemplate("{d} {crc16be}").build(["d": .bytes(Data("123456789".utf8))])
        XCTAssertEqual(Array(out.suffix(2)), [0x29, 0xB1])
    }

    func testErrors() {
        XCTAssertThrowsError(try CommandTemplate("{x}").build()) {
            XCTAssertEqual($0 as? TemplateError, .missingParameter("x"))
        }
        XCTAssertThrowsError(try CommandTemplate("{x}").build(["x": .int(300)]))
        XCTAssertThrowsError(try CommandTemplate("G1").build())
    }

    func testPattern() throws {
        let p = try BytePattern("55 AA ?? ?? 85")
        XCTAssertTrue(p.matches(try Data(hex: "55AA0501858182")))
        XCTAssertFalse(p.matches(try Data(hex: "55AA050186")))
        XCTAssertFalse(p.matches(try Data(hex: "55AA")))
    }
}

final class EqualizerTests: XCTestCase {
    func testQuantizeAndEncode() {
        var eq = Equalizer(step: 0.5)
        eq.setGain(3.3, at: 0)
        eq.setGain(40, at: 1)
        eq.setGain(-40, at: 2)
        XCTAssertEqual(eq.gains[0], 3.5)
        XCTAssertEqual(eq.gains[1], 12)
        XCTAssertEqual(eq.gains[2], -12)
        XCTAssertEqual(Array(eq.encodedSteps().prefix(3)), [7, 24, -24])
        XCTAssertEqual(Array(eq.encodedSteps(offsetDb: -12).prefix(3)), [31, 48, 0])
    }

    func testResponseCurve() {
        var eq = Equalizer()
        XCTAssertEqual(eq.response(at: 1000), 0, accuracy: 1e-9)
        eq.setGain(6, at: 5) // 1 kHz
        XCTAssertEqual(eq.response(at: 1000), 6, accuracy: 0.05)
        XCTAssertLessThan(eq.response(at: 50), 0.5)
        XCTAssertEqual(eq.curve(points: 64).count, 64)
    }

    func testPresetsHaveTenBands() {
        for preset in Equalizer.builtInPresets {
            XCTAssertEqual(preset.gains.count, 10, preset.name)
        }
    }
}

final class ProfileTests: XCTestCase {
    func testAllProfilesLoad() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Fixtures.profilesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThanOrEqual(files.count, 3)
        for file in files {
            let profile = try CommandProfile.load(from: Data(contentsOf: file))
            // Todo modelo de comando do perfil precisa ser válido.
            let driver = try ProfileDriver(profile: profile)
            let samples: [HeadsetCommand] = [
                .setNoiseMode(.anc), .setEqualizer(Array(repeating: 2, count: 10)),
                .setTouch(TouchBinding(side: .left, gesture: .singleTap, action: .playPause)),
                .setGameMode(true), .requestBattery, .requestInfo,
            ]
            for command in samples where driver.supports(command) {
                XCTAssertNoThrow(try driver.encode(command), "\(profile.id): \(command.profileKey)")
            }
            if let ota = profile.ota { _ = try BytePattern(ota.ackMatch) }
        }
    }

    func testMatching() throws {
        let p = try Fixtures.profile("jieli-rcsp-candidate")
        XCTAssertTrue(p.matches(name: "Qualquer", services: ["0000AE00-0000-1000-8000-00805F9B34FB"]))
        XCTAssertFalse(p.matches(name: "Qualquer", services: ["180F"]))
        let mali = try Fixtures.profile("kuba-mali2")
        XCTAssertTrue(mali.matches(name: "KUBA MALI 2", services: []))
    }

    func testRoundTripJSON() throws {
        let p = try Fixtures.profile("kubaopen")
        XCTAssertEqual(try CommandProfile.load(from: p.encoded()), p)
    }
}

final class DriverTests: XCTestCase {
    func testEncodeKubaOpenCommands() throws {
        let driver = try ProfileDriver(profile: Fixtures.profile("kubaopen"))
        let anc = try driver.encode(.setNoiseMode(.anc))
        XCTAssertEqual(anc.hexString(), "55 AA 03 00 01 01 05")
        let touch = try driver.encode(.setTouch(TouchBinding(side: .right, gesture: .doubleTap, action: .nextTrack)))
        XCTAssertEqual(Array(touch[4...7]), [0x03, 0x01, 0x01, 0x02])
        let eq = try driver.encode(.setEqualizer([1, -1, 12, 0, 0, 0, 0, 0, 0, 0]))
        // passo 0,5 dB -> 1 dB = 2 passos
        XCTAssertEqual(Array(eq[4...8]), [0x02, 0x0A, 0x02, 0xFE, 0x18])
        XCTAssertEqual(eq.count, 2 + 1 + 1 + 1 + 1 + 10 + 1)
    }

    func testUnsupportedCommand() throws {
        let driver = try ProfileDriver(profile: Fixtures.profile("kuba-mali2"))
        XCTAssertFalse(driver.supports(.setNoiseMode(.anc)))
        XCTAssertThrowsError(try driver.encode(.setNoiseMode(.anc))) {
            XCTAssertEqual($0 as? DriverError, .unsupported("noiseMode"))
        }
        XCTAssertTrue(driver.supports(.raw(Data([1]))))
    }

    func testDecodeEvents() throws {
        let driver = try ProfileDriver(profile: Fixtures.profile("kubaopen"))
        let sim = KubaOpenSimulator()
        sim.battery = (0x80 | 90, 75, 40) // bit 7 = carregando
        let battery = sim.receive(try driver.encode(.requestBattery))
        XCTAssertEqual(driver.decode(battery[0]), .battery(BatteryStatus(left: 90, right: 75, caseLevel: 40)))
        let info = sim.receive(try driver.encode(.requestInfo))
        XCTAssertEqual(driver.decode(info[0]), .firmwareVersion("1.0.0"))
        XCTAssertEqual(driver.decode(info[1]), .noiseMode(.off))
        XCTAssertEqual(driver.decode(Data([0x01, 0x02])), .unknown(Data([0x01, 0x02])))
    }

    func testSimulatorAppliesSettings() throws {
        let driver = try ProfileDriver(profile: Fixtures.profile("kubaopen"))
        let sim = KubaOpenSimulator()
        let replies = sim.receive(try driver.encode(.setNoiseMode(.transparency)))
        XCTAssertEqual(sim.noiseMode, 2)
        XCTAssertEqual(driver.decode(replies[1]), .noiseMode(.transparency))
        _ = sim.receive(try driver.encode(.setEqualizer([3, 0, 0, 0, 0, 0, 0, 0, 0, -3])))
        XCTAssertEqual(sim.eqGains.first, 6)
        XCTAssertEqual(sim.eqGains.last, -6)
        _ = sim.receive(try driver.encode(.setGameMode(true)))
        XCTAssertTrue(sim.gameMode)
    }

    func testSimulatorReassemblesFragments() throws {
        let driver = try ProfileDriver(profile: Fixtures.profile("kubaopen"))
        let sim = KubaOpenSimulator()
        let frame = try driver.encode(.setNoiseMode(.anc))
        var replies: [Data] = []
        replies += sim.receive(Data([0x00, 0x13])) // lixo antes
        for byte in frame { replies += sim.receive(Data([byte])) }
        XCTAssertEqual(sim.noiseMode, 1)
        XCTAssertEqual(replies.count, 2)
    }

    func testBadChecksumIgnored() throws {
        let sim = KubaOpenSimulator()
        XCTAssertTrue(sim.receive(try Data(hex: "55 AA 03 00 01 01 FF")).isEmpty)
        XCTAssertEqual(sim.noiseMode, 0)
    }
}

final class FirmwareTests: XCTestCase {
    private func image(_ size: Int) -> FirmwareImage {
        FirmwareImage(data: Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }), fileName: "teste.bin")
    }

    func testImageChecks() {
        XCTAssertFalse(FirmwareImage(data: Data(), fileName: "a").problems.isEmpty)
        XCTAssertFalse(FirmwareImage(data: Data(repeating: 0xFF, count: 10), fileName: "a").problems.isEmpty)
        XCTAssertTrue(image(1000).problems.isEmpty)
        XCTAssertEqual(FirmwareImage(data: Data([0x7F, 0x45, 0x4C, 0x46, 1]), fileName: "a").vendorHint.hasPrefix("Arquivo ELF"), true)
    }

    func testPreflight() throws {
        let spec = try XCTUnwrap(Fixtures.profile("kubaopen").ota)
        let engine = OTAEngine(spec: spec, image: image(1000))
        XCTAssertThrowsError(try engine.preflight(battery: nil)) { XCTAssertEqual($0 as? OTAError, .batteryUnknown) }
        XCTAssertThrowsError(try engine.preflight(battery: BatteryStatus(left: 90, right: 20))) {
            XCTAssertEqual($0 as? OTAError, .batteryTooLow(20, required: 50))
        }
        XCTAssertNoThrow(try engine.preflight(battery: BatteryStatus(left: 90, right: 80)))
    }

    func testFullUpdateOnSimulator() async throws {
        let spec = try XCTUnwrap(Fixtures.profile("kubaopen").ota)
        let fw = image(1000)
        let engine = OTAEngine(spec: spec, image: fw)
        XCTAssertEqual(engine.chunkCount, 8)
        XCTAssertEqual(try engine.frames().count, 10)
        let sim = KubaOpenSimulator()
        sim.dropNextChunks = 2 // força duas novas tentativas
        let transport = SimulatorTransport(simulator: sim)
        var last: OTAProgress?
        try await engine.run(battery: BatteryStatus(left: 90, right: 90), via: transport) { last = $0 }
        XCTAssertEqual(sim.installedFirmware, fw.data)
        XCTAssertEqual(sim.version.2, 1)
        XCTAssertEqual(last?.fraction, 1)
        XCTAssertEqual(transport.sentFrames.count, 12)
    }

    func testUpdateFailsWhenDeviceNeverAcks() async throws {
        let spec = try XCTUnwrap(Fixtures.profile("kubaopen").ota)
        let engine = OTAEngine(spec: spec, image: image(300))
        let sim = KubaOpenSimulator()
        sim.dropNextChunks = 100
        do {
            try await engine.run(battery: BatteryStatus(left: 90, right: 90),
                                 via: SimulatorTransport(simulator: sim)) { _ in }
            XCTFail("deveria falhar")
        } catch let error as OTAError {
            XCTAssertEqual(error, .noAck(step: "bloco 1/3"))
        }
        XCTAssertNil(sim.installedFirmware)
    }
}
