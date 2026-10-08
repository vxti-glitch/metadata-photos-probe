import XCTest
import Foundation
import AVFoundation
import CoreVideo
@testable import ProbeCore

final class VideoMetadataWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testDirectNativeMOVEditsExistingCameraAndRetainsLocationAndTitle() async throws {
        try await assertNativeMOV(includeMetadata: true)
    }

    func testDirectNativeMOVAddsCameraWithoutEngineCleanup() async throws {
        try await assertNativeMOV(includeMetadata: false)
    }

    func testSelfContainedAliasKeepsChunksAndTrackBytesAtOriginalOffsets() async throws {
        // A structural parser control, not a playable video or quality proof.
        let bytes = structuralMovie(referenceType: "alis")
        let source = directory.appendingPathComponent("source.mov")
        let output = directory.appendingPathComponent("output.mov")
        try bytes.write(to: source)
        let report = try await VideoMetadataWriter.write(source: source, output: output, patch: CameraPatch())
        let edited = try Data(contentsOf: output)
        let before = try boxes(bytes), after = try boxes(edited)
        let oldMovie = try XCTUnwrap(before.first { $0.type == "moov" })
        let newMovie = try XCTUnwrap(after.last { $0.type == "moov" })
        XCTAssertEqual(report.validatedTracks, 1)
        XCTAssertEqual(report.validatedChunks, 1)
        let media = try XCTUnwrap(before.first { $0.type == "mdat" })
        XCTAssertEqual(bytes.subdata(in: media.range), edited.subdata(in: media.range))
        let retired = try XCTUnwrap(after.first { $0.range.lowerBound == oldMovie.range.lowerBound })
        XCTAssertEqual(retired.type, "free")
        XCTAssertEqual(retired.range, oldMovie.range)
        XCTAssertTrue(edited.subdata(in: retired.payload).allSatisfy { $0 == 0 })
        let originalTrack = try XCTUnwrap(boxes(bytes.subdata(in: oldMovie.payload)).first { $0.type == "trak" })
        let editedTrack = try XCTUnwrap(boxes(edited.subdata(in: newMovie.payload)).first { $0.type == "trak" })
        XCTAssertEqual(bytes.subdata(in: oldMovie.payload).subdata(in: originalTrack.range),
                       edited.subdata(in: newMovie.payload).subdata(in: editedTrack.range))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testExternalAliasesAndURLsAndUnknownReferenceFlagsAreRefused() async throws {
        for type in ["alis", "url "] {
            try await assertRefused(structuralMovie(referenceType: type, referencePayload: word(0) + Data("external".utf8)))
            try await assertRefused(structuralMovie(referenceType: type, referencePayload: word(1) + Data([0])))
            try await assertRefused(structuralMovie(referenceType: type, referencePayload: word(3)))
            try await assertRefused(structuralMovie(referenceType: type, referencePayload: word(0x01000001)))
        }
        try await assertRefused(structuralMovie(referenceType: "rsrc"))
    }

    func testChunksOutsideMediaOrCrossingMediaBoundaryAreRefused() async throws {
        try await assertRefused(structuralMovie(chunkOffset: 0))
        try await assertRefused(structuralMovie(chunkOffset: 34))
        try await assertRefused(structuralMovie(sampleSize: 5))
        try await assertRefused(structuralMovie(sampleCount: 2))
    }

    func testFragmentedUnknownAndEOFSizeLayoutsAreRefused() async throws {
        try await assertRefused(structuralMovie() + box("moof", Data()))
        try await assertRefused(structuralMovie() + box("uuid", Data(repeating: 0, count: 16)))
        var eof = structuralMovie()
        eof.replaceSubrange(24..<28, with: word(0))
        try await assertRefused(eof)
        var escaped = structuralMovie()
        escaped.replaceSubrange(24..<28, with: word(UInt32.max))
        try await assertRefused(escaped)
    }

    func testExistingOutputIsNeverReplacedAndSameSourceIsRefused() async throws {
        let source = directory.appendingPathComponent("source.mov"), output = directory.appendingPathComponent("output.mov")
        let original = structuralMovie(), sentinel = Data("existing file".utf8)
        try original.write(to: source); try sentinel.write(to: output)
        do {
            _ = try await VideoMetadataWriter.write(source: source, output: output, patch: CameraPatch())
            XCTFail("Must refuse existing output")
        } catch ProbeError.outputExists { }
        do {
            _ = try await VideoMetadataWriter.write(source: source, output: source, patch: CameraPatch())
            XCTFail("Must refuse source overwrite")
        } catch ProbeError.sameFile { }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }

    private func assertRefused(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) async throws {
        let source = directory.appendingPathComponent(UUID().uuidString + ".mov")
        let output = directory.appendingPathComponent(UUID().uuidString + ".mov")
        try bytes.write(to: source)
        do {
            _ = try await VideoMetadataWriter.write(source: source, output: output, patch: CameraPatch())
            XCTFail("Unsafe structural control was accepted", file: file, line: line)
        } catch let error as ProbeError {
            switch error {
            case .unsupported, .malformed: break
            default: XCTFail("Unexpected refusal: \(error)", file: file, line: line)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: source), bytes, file: file, line: line)
    }

    private func assertNativeMOV(includeMetadata: Bool) async throws {
        let source = directory.appendingPathComponent("direct-source.mov")
        let output = directory.appendingPathComponent("direct-output.mov")
        try await makeNativeMOV(source, includeMetadata: includeMetadata)
        let originalDigest = try WholeFileDigest.sha256(source)
        let patch = CameraPatch(make: "Direct Probe Maker", model: "Direct Probe Model")
        // This calls the writer directly: there is no MetadataEngine.process cleanup
        // that could obscure an unsupported-layout or file-writing failure.
        let report = try await VideoMetadataWriter.write(source: source, output: output, patch: patch)
        XCTAssertEqual(report.validatedTracks, 1)
        XCTAssertGreaterThan(report.validatedChunks, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let after = try await MetadataEngine.inspect(output)
        XCTAssertEqual(after.kind, .mov)
        XCTAssertEqual(after.metadata["make"], patch.make)
        XCTAssertEqual(after.metadata["model"], patch.model)
        if includeMetadata {
            let items = try await AVURLAsset(url: output).load(.metadata)
            let title = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataTitle).first
            let location = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataLocationISO6709).first
            let savedTitle = try await title?.load(.stringValue)
            let savedLocation = try await location?.load(.stringValue)
            XCTAssertEqual(savedTitle, "Retained synthetic title")
            XCTAssertEqual(savedLocation, "+12.5000-044.2500/")
        }
        let comparison = try await MediaIntegrity.compare(source: source, output: output, patch: patch)
        XCTAssertTrue(comparison.checks.contains { $0.name.contains("compressed data") && $0.status == .passed })
        XCTAssertFalse(comparison.checks.contains { $0.status == .failed })
        XCTAssertEqual(comparison.status, .incomplete)
        XCTAssertEqual(try WholeFileDigest.sha256(source), originalDigest)
    }

    private func makeNativeMOV(_ url: URL, includeMetadata: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        if includeMetadata {
            writer.metadata = [(.quickTimeMetadataMake, "Source Maker"), (.quickTimeMetadataModel, "Source Movie"),
                (.quickTimeMetadataTitle, "Retained synthetic title"), (.quickTimeMetadataLocationISO6709, "+12.5000-044.2500/")].map { identifier, value in
                let item = AVMutableMetadataItem(); item.identifier = identifier; item.value = value as NSString
                item.dataType = "com.apple.metadata.datatype.UTF-8"; return item
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        guard writer.canAdd(input) else { throw ProbeError.writeFailed("Cannot add native MOV fixture input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ProbeError.writeFailed("Cannot start native MOV fixture") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else {
                    writer.cancelWriting(); throw ProbeError.writeFailed("Native MOV fixture stalled")
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess,
                  let pixel else { throw ProbeError.writeFailed("Fixture pixel buffer unavailable") }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let address = CVPixelBufferGetBaseAddress(pixel) {
                memset(address, Int32(frame * 70), CVPixelBufferGetBytesPerRow(pixel) * 32)
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? ProbeError.writeFailed("Cannot append native MOV frame")
            }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProbeError.writeFailed("Native MOV fixture unfinished") }
    }

    private struct Box { let type: String; let range: Range<Int>; let payload: Range<Int> }
    private func boxes(_ data: Data) throws -> [Box] {
        var result = [Box](), offset = 0
        while offset < data.count {
            guard offset <= data.count - 8 else { throw ProbeError.malformed("Test box header truncated") }
            let length = Int(data[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard length >= 8, length <= data.count - offset else { throw ProbeError.malformed("Test box bounds invalid") }
            result.append(Box(type: String(decoding: data[offset+4..<offset+8], as: UTF8.self),
                range: offset..<offset+length, payload: offset+8..<offset+length))
            offset += length
        }
        return result
    }

    private func word(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    private func box(_ type: String, _ payload: Data) -> Data { word(UInt32(payload.count + 8)) + Data(type.utf8) + payload }

    private func structuralMovie(referenceType: String = "url ", referencePayload: Data? = nil,
                                 chunkOffset: UInt32 = 32, sampleSize: UInt32 = 4, sampleCount: UInt32 = 1) -> Data {
        let ftyp = box("ftyp", Data("qt  ".utf8) + word(0) + Data("qt  ".utf8) + word(0))
        let mdat = box("mdat", Data([1,2,3,4]))
        let dref = box("dref", word(0) + word(1) + box(referenceType, referencePayload ?? word(1)))
        let sample = box("avc1", Data(repeating: 0, count: 6) + Data([0,1]))
        let stsd = box("stsd", word(0) + word(1) + sample)
        let stsc = box("stsc", word(0) + word(1) + word(1) + word(1) + word(1))
        let stsz = box("stsz", word(0) + word(sampleSize) + word(sampleCount))
        let stco = box("stco", word(0) + word(1) + word(chunkOffset))
        let stbl = box("stbl", stsd + stsc + stsz + stco)
        let minf = box("minf", box("dinf", dref) + stbl)
        let track = box("trak", box("tkhd", Data()) + box("mdia", minf))
        return ftyp + mdat + box("moov", box("mvhd", Data()) + track)
    }
}
