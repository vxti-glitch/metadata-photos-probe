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

    func testMovieWithCsgmCompactSampleToGroupBoxesIsAcceptedAndRewritten() async throws {
        let csgmBoxes = box("csgm", word(0) + Data([1, 2, 3, 4])) + box("csgm", word(0) + Data([5, 6, 7, 8]))
        let bytes = structuralMovie(sampleTableExtra: csgmBoxes)
        let source = directory.appendingPathComponent("csgm-source.mov")
        let output = directory.appendingPathComponent("csgm-output.mov")
        try bytes.write(to: source)
        let report = try await VideoMetadataWriter.write(
            source: source,
            output: output,
            patch: MetadataPatch(values: ["make": .string("Apple"), "model": .string("iPhone 15 Pro")])
        )
        XCTAssertEqual(report.validatedTracks, 1)
        XCTAssertEqual(report.validatedChunks, 1)
        let edited = try Data(contentsOf: output)
        let before = try boxes(bytes), after = try boxes(edited)
        let oldMovie = try XCTUnwrap(before.first { $0.type == "moov" })
        let newMovie = try XCTUnwrap(after.last { $0.type == "moov" })
        XCTAssertGreaterThan(newMovie.range.count, 0)

        // Verify media data payload in mdat is byte-for-byte immutable
        let media = try XCTUnwrap(before.first { $0.type == "mdat" })
        XCTAssertEqual(bytes.subdata(in: media.range), edited.subdata(in: media.range))

        // Verify retired old movie is converted to zeroed free space
        let retired = try XCTUnwrap(after.first { $0.range.lowerBound == oldMovie.range.lowerBound })
        XCTAssertEqual(retired.type, "free")
        XCTAssertEqual(retired.range, oldMovie.range)
        XCTAssertTrue(edited.subdata(in: retired.payload).allSatisfy { $0 == 0 })

        // Verify csgm atoms are retained intact inside new movie's sample table
        let newTrak = try XCTUnwrap(boxes(edited.subdata(in: newMovie.payload)).first { $0.type == "trak" })
        let newMdia = try XCTUnwrap(boxes(edited.subdata(in: newTrak.payload)).first { $0.type == "mdia" })
        let newMinf = try XCTUnwrap(boxes(edited.subdata(in: newMdia.payload)).first { $0.type == "minf" })
        let newStbl = try XCTUnwrap(boxes(edited.subdata(in: newMinf.payload)).first { $0.type == "stbl" })
        let stblChildren = try boxes(edited.subdata(in: newStbl.payload))
        let csgmChildren = stblChildren.filter { $0.type == "csgm" }
        XCTAssertEqual(csgmChildren.count, 2)
        XCTAssertEqual(edited.subdata(in: csgmChildren[0].payload), word(0) + Data([1, 2, 3, 4]))
        XCTAssertEqual(edited.subdata(in: csgmChildren[1].payload), word(0) + Data([5, 6, 7, 8]))
    }

    func testMovieWithUnqualifiedSampleTableAtomIsStrictlyRefused() async throws {
        let unqualifiedBox = box("unkn", Data([1, 2, 3, 4]))
        let bytes = structuralMovie(sampleTableExtra: unqualifiedBox)
        try await assertRefused(bytes)
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

    func testCoordinateRemovalRetiresISOLocationAndPreservesOtherUserDataAndMedia() async throws {
        let retained = box("chpl", Data("retained chapter bytes".utf8))
        let original = structuralMovie(userData: box("loci", Data("opaque ISO location".utf8)) + retained)
        let source = directory.appendingPathComponent("iso-source.mov"), output = directory.appendingPathComponent("iso-removed.mov")
        try original.write(to: source)
        _ = try await VideoMetadataWriter.write(source: source, output: output,
            patch: MetadataPatch(removals: ["latitude", "longitude", "altitude"]))
        let edited = try Data(contentsOf: output)
        XCTAssertEqual(try movieUserData(edited), retained)
        let media = try XCTUnwrap(boxes(original).first { $0.type == "mdat" })
        XCTAssertEqual(edited.subdata(in: media.range), original.subdata(in: media.range))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testUnrelatedRemovalPreservesISOLocationBytes() async throws {
        let location = box("loci", Data("opaque ISO location".utf8))
        let source = directory.appendingPathComponent("iso-source.mov"), output = directory.appendingPathComponent("software-removed.mov")
        try structuralMovie(userData: location).write(to: source)
        _ = try await VideoMetadataWriter.write(source: source, output: output, patch: MetadataPatch(removals: ["software"]))
        XCTAssertEqual(try movieUserData(Data(contentsOf: output)), location)
    }

    func testCoordinateEditsRetireISORecordsAtMovieTrackAndMediaScopes() async throws {
        let location = box("loci", Data("old opaque ISO location".utf8))
        let retained = box("chpl", Data("retained chapter bytes".utf8))
        let original = structuralMovie(userData: location + retained, trackUserData: location + retained, mediaUserData: location + retained)
        let source = directory.appendingPathComponent("nested-iso-source.mov")
        try original.write(to: source)
        let patches = [MetadataPatch(removals: ["latitude", "longitude", "altitude"]),
                       MetadataPatch(values: ["latitude": .number(-12.5), "longitude": .number(44.25), "altitude": .number(-10)])]
        for (index, patch) in patches.enumerated() {
            let output = directory.appendingPathComponent("nested-iso-edited-\(index).mov")
            _ = try await VideoMetadataWriter.write(source: source, output: output, patch: patch)
            let edited = try Data(contentsOf: output)
            let movie = try XCTUnwrap(boxes(edited).last { $0.type == "moov" })
            let movieData = edited.subdata(in: movie.payload)
            let track = try XCTUnwrap(boxes(movieData).first { $0.type == "trak" })
            let trackData = movieData.subdata(in: track.payload)
            let media = try XCTUnwrap(boxes(trackData).first { $0.type == "mdia" })
            for scope in [movieData, trackData, trackData.subdata(in: media.payload)] {
                let userData = try XCTUnwrap(boxes(scope).first { $0.type == "udta" })
                XCTAssertEqual(scope.subdata(in: userData.payload), retained)
            }
            let mdat = try XCTUnwrap(boxes(original).first { $0.type == "mdat" })
            XCTAssertEqual(edited.subdata(in: mdat.range), original.subdata(in: mdat.range))
            let readback = try VideoMetadataWriter.inspect(output)
            if index == 0 { XCTAssertNil(readback["latitude"]); XCTAssertNil(readback["longitude"]); XCTAssertNil(readback["altitude"]) }
            else { XCTAssertEqual(readback["latitude"], "-12.5"); XCTAssertEqual(readback["longitude"], "44.25"); XCTAssertEqual(readback["altitude"], "-10") }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testGPSChangesRefuseTimedMetadataTrackWithoutDeletingSamples() async throws {
        let source = directory.appendingPathComponent("timed-source.mov"), output = directory.appendingPathComponent("timed-refused.mov")
        let original = structuralMovie(userData: Data(), mediaHandler: "meta")
        try original.write(to: source)
        do {
            _ = try await VideoMetadataWriter.write(source: source, output: output, patch: MetadataPatch(removals: ["latitude", "longitude"]))
            XCTFail("GPS changes must refuse unqualified timed metadata")
        } catch ProbeError.unsupported { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testAltitudeOnlyISOLocationAndOpaqueXMPRemovalRemainRefused() async throws {
        let source = directory.appendingPathComponent("iso-source.mov"), seeded = directory.appendingPathComponent("iso-seeded.mov")
        try structuralMovie(userData: box("loci", Data("opaque ISO location".utf8))).write(to: source)
        _ = try await VideoMetadataWriter.write(source: source, output: seeded,
            patch: MetadataPatch(values: ["latitude": .number(12.5), "longitude": .number(44.25), "altitude": .number(10)]))
        // Add a competing legacy tuple to the generated container after seeding:
        // GPS setting intentionally removes it, so it must be restored for this
        // altitude-only refusal control to reach the unqualified ISO record.
        var seededBytes = try Data(contentsOf: seeded)
        let movie = try XCTUnwrap(boxes(seededBytes).last { $0.type == "moov" })
        let restoredMovie = box("moov", seededBytes.subdata(in: movie.payload) + box("udta", box("loci", Data("opaque ISO location".utf8))))
        seededBytes.replaceSubrange(movie.range, with: restoredMovie)
        try seededBytes.write(to: seeded)
        for (name, input, patch) in [("altitude", seeded, MetadataPatch(removals: ["altitude"])),
                                      ("xmp", directory.appendingPathComponent("xmp-source.mov"), MetadataPatch(removals: ["software"]))] {
            if name == "xmp" { try structuralMovie(userData: box("XMP_", Data("opaque XMP".utf8))).write(to: input) }
            let output = directory.appendingPathComponent("\(name)-refused.mov")
            do {
                _ = try await VideoMetadataWriter.write(source: input, output: output, patch: patch)
                XCTFail("Unqualified partial/opaque metadata removal must be refused")
            } catch ProbeError.unsupported { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
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

    private func movieUserData(_ data: Data) throws -> Data {
        let movie = try XCTUnwrap(boxes(data).last { $0.type == "moov" })
        let children = data.subdata(in: movie.payload)
        let userData = try XCTUnwrap(boxes(children).first { $0.type == "udta" })
        return children.subdata(in: userData.payload)
    }

    private func structuralMovie(referenceType: String = "url ", referencePayload: Data? = nil,
                                 chunkOffset: UInt32 = 32, sampleSize: UInt32 = 4, sampleCount: UInt32 = 1,
                                 userData: Data? = nil, trackUserData: Data? = nil, mediaUserData: Data? = nil,
                                 mediaHandler: String = "vide", sampleTableExtra: Data = Data()) -> Data {
        let ftyp = box("ftyp", Data("qt  ".utf8) + word(0) + Data("qt  ".utf8) + word(0))
        let mdat = box("mdat", Data([1,2,3,4]))
        let dref = box("dref", word(0) + word(1) + box(referenceType, referencePayload ?? word(1)))
        let sample = box("avc1", Data(repeating: 0, count: 6) + Data([0,1]))
        let stsd = box("stsd", word(0) + word(1) + sample)
        let stsc = box("stsc", word(0) + word(1) + word(1) + word(1) + word(1))
        let stsz = box("stsz", word(0) + word(sampleSize) + word(sampleCount))
        let stco = box("stco", word(0) + word(1) + word(chunkOffset))
        let stbl = box("stbl", stsd + stsc + stsz + stco + sampleTableExtra)
        let minf = box("minf", box("dinf", dref) + stbl)
        // Date headers make the ISO location controls inspectable by the bounded
        // metadata reader. These remain structural controls, not playable media.
        let hasMetadata = userData != nil || trackUserData != nil || mediaUserData != nil
        let dates = hasMetadata ? Data(repeating: 0, count: 12) : Data()
        let handler = hasMetadata ? box("hdlr", word(0) + word(0) + Data(mediaHandler.utf8) + Data(repeating: 0, count: 12)) : Data()
        let media = minf + handler + (mediaUserData.map { box("udta", $0) } ?? Data())
        let track = box("trak", box("tkhd", dates) + box("mdia", media) + (trackUserData.map { box("udta", $0) } ?? Data()))
        return ftyp + mdat + box("moov", box("mvhd", dates) + track + (userData.map { box("udta", $0) } ?? Data()))
    }
}
