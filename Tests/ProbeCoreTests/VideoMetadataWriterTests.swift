import XCTest
import Foundation
import AVFoundation
import CoreVideo
import AudioToolbox
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

    func testSynthetic4KWithAudioPreservesSamplesAndRecordsProcessingTime() async throws {
        let source = directory.appendingPathComponent("synthetic-4k.mp4"), output = directory.appendingPathComponent("synthetic-4k-edited.mp4")
        try await makeNativeMOV(source, includeMetadata: true, kind: .mp4, includeAudio: true,
                                fastStart: true, frameCount: 15, width: 3840, height: 2160)
        let originalHash = try WholeFileDigest.sha256(source)
        let start = Date()
        let result = try await MetadataEngine.processMetadataPatch(source: source, output: output,
            patch: MetadataPatch(values: ["make": .string("Apple"), "model": .string("Synthetic 4K Camera")]))
        let encoded = result.integrity.checks.filter { $0.name.contains("compressed data") }
        XCTAssertEqual(encoded.count, 2)
        XCTAssertTrue(encoded.allSatisfy { $0.status == .passed })
        XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed })
        XCTAssertEqual(try WholeFileDigest.sha256(source), originalHash)
        print("Synthetic 4K H264/AAC metadata rewrite plus verification: \(Date().timeIntervalSince(start)) seconds; \(result.sourceInspection.byteCount) input bytes; 15 generated frames. This is a host fixture measurement, not a physical-device benchmark.")
    }

    func testAutomaticProfileOnUntaggedNativeMoviesPreservesEncodedSamples() async throws {
        // No user fixture is used or uploaded. This covers the first edit of an
        // ordinary movie with no camera mdta and the full automatic camera plan.
        for (kind, includeAudio) in [(MediaKind.mov, false), (.mp4, false), (.mov, true), (.mp4, true)] {
            let suffix = includeAudio ? "audio" : "video"
            let source = directory.appendingPathComponent("automatic-source-\(suffix).\(kind.rawValue)")
            try await makeNativeMOV(source, includeMetadata: false, kind: kind, includeAudio: includeAudio, fastStart: includeAudio)
            let original = try WholeFileDigest.sha256(source)
            for (index, iso) in [123.0, 65535.0].enumerated() {
                let output = directory.appendingPathComponent("automatic-edited-\(suffix)-\(index).\(kind.rawValue)")
                var values: [String: MetadataValue] = [
                    "make": .string("Apple"), "model": .string("iPhone 15 Pro Max"),
                    "software": .string("18.6.2"),
                    "lensModel": .string("iPhone 15 Pro Max back triple camera 6.765mm f/1.78"),
                    "focalLength35mm": .number(24), "iso": .number(iso),
                    "exposureTime": .number(index == 0 ? 1.0 / 250 : 1.0 / 1000),
                    "fNumber": .number(1.78)
                ]
                for key in VideoMetadataFields.dateKeys.union(["dateTimeOriginal"]) {
                    values[key] = .string("2026-04-05T06:07:08-04:00")
                }
                let patch = MetadataPatch(values: values)
                // Keep the writer's diagnostic copy for this synthetic test so
                // every failing check can identify its layer without bypassing
                // MetadataEngine's production cleanup and rejection gate.
                _ = try await VideoMetadataWriter.write(source: source, output: output, patch: patch)
                let inspected = try await MetadataEngine.inspect(output)
                try patch.validateReadback(inspected)
                let comparison = try await MediaIntegrity.compareMetadata(source: source, output: output, patch: patch)
                XCTAssertFalse(comparison.checks.contains { $0.status == .failed }, "Synthetic \(kind) \(suffix): \(comparison.checks)")
                XCTAssertTrue(comparison.checks.contains { $0.name.contains("compressed data") && $0.status == .passed })
                let encodedChecks = comparison.checks.filter { $0.name.contains("compressed data") }
                XCTAssertEqual(encodedChecks.count, includeAudio ? 2 : 1)
                XCTAssertTrue(encodedChecks.allSatisfy { $0.status == .passed })
                XCTAssertEqual(try WholeFileDigest.sha256(source), original)
            }
        }
    }

    func testAutomaticProfileOnLongMultiChunkMoviesPreservesEveryAudioAndVideoSample() async throws {
        for kind in [MediaKind.mov, .mp4] {
            let source = directory.appendingPathComponent("generated-multichunk-source.\(kind.rawValue)")
            let output = directory.appendingPathComponent("generated-multichunk-edited.\(kind.rawValue)")
            try await makeNativeMOV(source, includeMetadata: false, kind: kind, includeAudio: true,
                fastStart: true, frameCount: 240, audioSampleRate: 44_100, noisyAudio: true)
            let sourceBytes = try Data(contentsOf: source)
            let sourceBoxes = try boxes(sourceBytes)
            let movie = try XCTUnwrap(sourceBoxes.first { $0.type == "moov" })
            let media = try XCTUnwrap(sourceBoxes.first { $0.type == "mdat" })
            XCTAssertLessThan(movie.range.lowerBound, media.range.lowerBound, "Fixture must exercise fast-start relocation")
            let chunkCounts = try movieChunkCounts(sourceBytes)
            XCTAssertEqual(chunkCounts.count, 2)
            XCTAssertTrue(chunkCounts.allSatisfy { $0 > 1 }, "Fixture must contain multiple chunks on both tracks: \(chunkCounts)")
            var values: [String: MetadataValue] = [
                "make": .string("Apple"), "model": .string("iPhone 15 Pro Max"),
                "software": .string("18.6.2"),
                "lensModel": .string("iPhone 15 Pro Max back triple camera 6.765mm f/1.78"),
                "focalLength35mm": .number(24), "iso": .number(317),
                "exposureTime": .number(1.0 / 320), "fNumber": .number(1.78)
            ]
            for key in VideoMetadataFields.dateKeys.union(["dateTimeOriginal"]) {
                values[key] = .string("2026-04-05T06:07:08-04:00")
            }
            let patch = MetadataPatch(values: values)
            let report = try await VideoMetadataWriter.write(source: source, output: output, patch: patch)
            XCTAssertEqual(report.validatedTracks, 2)
            XCTAssertEqual(report.validatedChunks, chunkCounts.reduce(0, +))
            let inspected = try await MetadataEngine.inspect(output)
            try patch.validateReadback(inspected)
            let comparison = try await MediaIntegrity.compareMetadata(source: source, output: output, patch: patch)
            XCTAssertFalse(comparison.checks.contains { $0.status == .failed }, "Synthetic long \(kind): \(comparison.checks)")
            let encoded = comparison.checks.filter { $0.name.contains("compressed data") }
            XCTAssertEqual(encoded.count, 2)
            XCTAssertTrue(encoded.allSatisfy { $0.status == .passed })
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            XCTAssertEqual(try movieChunkCounts(Data(contentsOf: output)), chunkCounts)
        }
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
        let moovData = edited.subdata(in: newMovie.payload)
        let newTrak = try XCTUnwrap(boxes(moovData).first { $0.type == "trak" })
        let trakData = moovData.subdata(in: newTrak.payload)
        let newMdia = try XCTUnwrap(boxes(trakData).first { $0.type == "mdia" })
        let mdiaData = trakData.subdata(in: newMdia.payload)
        let newMinf = try XCTUnwrap(boxes(mdiaData).first { $0.type == "minf" })
        let minfData = mdiaData.subdata(in: newMinf.payload)
        let newStbl = try XCTUnwrap(boxes(minfData).first { $0.type == "stbl" })
        let stblData = minfData.subdata(in: newStbl.payload)
        let stblChildren = try boxes(stblData)
        let csgmChildren = stblChildren.filter { $0.type == "csgm" }
        XCTAssertEqual(csgmChildren.count, 2)
        XCTAssertEqual(stblData.subdata(in: csgmChildren[0].payload), word(0) + Data([1, 2, 3, 4]))
        XCTAssertEqual(stblData.subdata(in: csgmChildren[1].payload), word(0) + Data([5, 6, 7, 8]))
    }

    func testTrackMetadataInspectorKeepsValuesSeparateAcrossVideoTracks() async throws {
        let source = directory.appendingPathComponent("two-video-track-source.mov")
        let output = directory.appendingPathComponent("two-video-track-output.mov")
        let removed = directory.appendingPathComponent("two-video-track-removed.mov")
        try structuralMovie(videoTrackCount: 2).write(to: source)
        _ = try await VideoMetadataWriter.write(source: source, output: output,
            patch: MetadataPatch(values: ["lensModel": .string("Requested Lens")]))

        let tracks = try VideoMetadataWriter.inspectVideoTrackMetadata(output)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0]["com.apple.quicktime.camera.lens_model"], "Requested Lens")
        XCTAssertEqual(tracks[1]["com.apple.quicktime.camera.lens_model"], "Requested Lens")

        _ = try await VideoMetadataWriter.write(source: output, output: removed,
            patch: MetadataPatch(removals: ["lensModel"]))
        let removedTracks = try VideoMetadataWriter.inspectVideoTrackMetadata(removed)
        XCTAssertEqual(removedTracks.count, 2)
        let removalStatuses = removedTracks.map {
            $0["com.apple.quicktime.camera.lens_model"] == nil && $0["lensModel"] == nil ? CheckStatus.passed : .failed
        }
        XCTAssertEqual(MediaIntegrity.videoTrackReadbackStatus(removalStatuses, expectedTrackCount: 2), .passed)
    }

    func testTrackEditPreservesNonMdtaMetaAndRefusesDuplicateMdtaContainers() async throws {
        let nonMdta = box("meta", word(0) + box("hdlr", word(0) + word(0) + Data("mdir".utf8) + Data(repeating: 0, count: 12)) + box("free", Data([1, 2, 3, 4])))
        let source = directory.appendingPathComponent("track-non-mdta.mov")
        let output = directory.appendingPathComponent("track-non-mdta-edited.mov")
        try structuralMovie(trackMeta: nonMdta).write(to: source)
        _ = try await VideoMetadataWriter.write(source: source, output: output,
            patch: MetadataPatch(values: ["lensModel": .string("Requested Lens")]))
        let edited = try Data(contentsOf: output)
        let movie = try XCTUnwrap(boxes(edited).last { $0.type == "moov" })
        let track = try XCTUnwrap(boxes(edited.subdata(in: movie.payload)).first { $0.type == "trak" })
        XCTAssertTrue(try boxes(edited.subdata(in: movie.payload).subdata(in: track.payload)).contains {
            $0.type == "meta" && edited.subdata(in: movie.payload).subdata(in: track.payload).subdata(in: $0.range) == nonMdta
        })

        let seed = directory.appendingPathComponent("track-metadata-seed.mov")
        let seedSource = directory.appendingPathComponent("track-metadata-seed-source.mov")
        let duplicateSource = directory.appendingPathComponent("track-metadata-duplicate.mov")
        // Keep the first fixture immutable. Reusing and overwriting `source` here
        // can leave URL.resourceValues with its earlier, larger cached file size.
        try structuralMovie().write(to: seedSource)
        _ = try await VideoMetadataWriter.write(source: seedSource, output: seed,
            patch: MetadataPatch(values: ["lensModel": .string("Existing Lens")]))
        let trackMetadata = try firstTrackMetadataAtom(Data(contentsOf: seed))
        let duplicateBytes = structuralMovie(trackUserData: trackMetadata, trackMeta: trackMetadata)
        try duplicateBytes.write(to: duplicateSource)
        let duplicateOutput = directory.appendingPathComponent("track-metadata-duplicate-output.mov")
        do {
            _ = try await VideoMetadataWriter.write(source: duplicateSource, output: duplicateOutput,
                patch: MetadataPatch(values: ["lensModel": .string("Requested Lens")]))
            XCTFail("Editing ambiguous track metadata must be refused")
        } catch ProbeError.unsupported { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicateOutput.path))
        XCTAssertEqual(try Data(contentsOf: duplicateSource), duplicateBytes)
    }

    func testWriterUsesOpenedFileLengthWhenURLHasStaleCachedSize() async throws {
        let source = directory.appendingPathComponent("stale-size-source.mov")
        let output = directory.appendingPathComponent("stale-size-output.mov")
        let handler = box("hdlr", word(0) + word(0) + Data("mdir".utf8) + Data(repeating: 0, count: 12))
        let retainedMetadata = box("meta", word(0) + handler + box("free", Data(repeating: 0, count: 128)))
        let largeFixture = structuralMovie(trackMeta: retainedMetadata)
        let currentFixture = structuralMovie(userData: Data())
        try largeFixture.write(to: source)
        let cachedSize = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(cachedSize, currentFixture.count)

        // Deliberately replace the file after priming URL's larger cached size.
        // This reproduces stale URL.resourceValues without mutating a writer input.
        try currentFixture.write(to: source)
        XCTAssertEqual(try Data(contentsOf: source), currentFixture)
        _ = try await VideoMetadataWriter.write(source: source, output: output,
            patch: MetadataPatch(values: ["model": .string("Fresh File Size")]))

        XCTAssertEqual(try Data(contentsOf: source), currentFixture)
        XCTAssertEqual(try VideoMetadataWriter.inspect(output)["model"], "Fresh File Size")
    }

    func testExtendedSizeFtypWorksAndInvalidCompatibleBrandPaddingIsRefused() async throws {
        let extended = directory.appendingPathComponent("extended-ftyp.mov")
        let output = directory.appendingPathComponent("extended-ftyp-edited.mov")
        // Extended ftyp adds eight bytes before mdat, so the chunk must point to
        // the mdat payload at byte 40 rather than the ordinary fixture's byte 32.
        try structuralMovie(chunkOffset: 40, extendedFtyp: true).write(to: extended)
        _ = try await VideoMetadataWriter.write(source: extended, output: output, patch: CameraPatch())
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let malformed = structuralMovie(ftypPayload: Data("qt  ".utf8) + word(0) + Data([0x71]))
        try await assertRefused(malformed)
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

    func testRemovingCoordinatesMustExplicitlyRemoveExistingAltitude() async throws {
        let source = directory.appendingPathComponent("gps-tuple-source.mov")
        let seeded = directory.appendingPathComponent("gps-tuple-seeded.mov")
        let partial = directory.appendingPathComponent("gps-tuple-partial-removal.mov")
        let complete = directory.appendingPathComponent("gps-tuple-complete-removal.mov")
        // GPS write/readback inspects movie and track dates as well; include valid
        // version-0 date headers even though this fixture starts without metadata.
        try structuralMovie(userData: Data()).write(to: source)
        _ = try await VideoMetadataWriter.write(source: source, output: seeded,
            patch: MetadataPatch(values: ["latitude": .number(12.5), "longitude": .number(44.25), "altitude": .number(10)]))

        do {
            _ = try await VideoMetadataWriter.write(source: seeded, output: partial,
                patch: MetadataPatch(removals: ["latitude", "longitude"]))
            XCTFail("Removing the coordinate pair must not silently erase an untargeted altitude")
        } catch ProbeError.unsupported { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try VideoMetadataWriter.inspect(seeded)["altitude"], "10")

        _ = try await VideoMetadataWriter.write(source: seeded, output: complete,
            patch: MetadataPatch(removals: ["latitude", "longitude", "altitude"]))
        let readback = try VideoMetadataWriter.inspect(complete)
        XCTAssertNil(readback["latitude"])
        XCTAssertNil(readback["longitude"])
        XCTAssertNil(readback["altitude"])
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

    func testOpaqueLegacyLocationRequiresExplicitActionForAllGPSComponents() async throws {
        let source = directory.appendingPathComponent("opaque-location-source.mov")
        let partial = directory.appendingPathComponent("opaque-location-partial.mov")
        let full = directory.appendingPathComponent("opaque-location-full.mov")
        let original = structuralMovie(userData: box("loci", Data("opaque ISO location with unknown altitude".utf8)))
        try original.write(to: source)

        do {
            _ = try await VideoMetadataWriter.write(source: source, output: partial,
                patch: MetadataPatch(removals: ["latitude", "longitude"]))
            XCTFail("An opaque ISO location may contain an altitude that must not be silently erased")
        } catch ProbeError.unsupported { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: source), original)

        _ = try await VideoMetadataWriter.write(source: source, output: full,
            patch: MetadataPatch(removals: ["latitude", "longitude", "altitude"]))
        XCTAssertNil(try VideoMetadataWriter.inspect(full)["latitude"])
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

    private func makeNativeMOV(_ url: URL, includeMetadata: Bool, kind: MediaKind = .mov, includeAudio: Bool = false, fastStart: Bool = false,
                               frameCount: Int = 3, audioSampleRate: Int = 48_000, noisyAudio: Bool = false,
                               width: Int = 32, height: Int = 32) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: kind == .mp4 ? .mp4 : .mov)
        writer.shouldOptimizeForNetworkUse = fastStart
        if includeMetadata {
            writer.metadata = [(.quickTimeMetadataMake, "Source Maker"), (.quickTimeMetadataModel, "Source Movie"),
                (.quickTimeMetadataTitle, "Retained synthetic title"), (.quickTimeMetadataLocationISO6709, "+12.5000-044.2500/")].map { identifier, value in
                let item = AVMutableMetadataItem(); item.identifier = identifier; item.value = value as NSString
                item.dataType = "com.apple.metadata.datatype.UTF-8"; return item
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw ProbeError.writeFailed("Cannot add native MOV fixture input") }
        writer.add(input)
        let audioInput: AVAssetWriterInput?
        if includeAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
            guard writer.canAdd(audio) else { throw ProbeError.writeFailed("Cannot add synthetic AAC fixture") }
            writer.add(audio); audioInput = audio
        } else { audioInput = nil }
        guard writer.startWriting() else { throw writer.error ?? ProbeError.writeFailed("Cannot start native MOV fixture") }
        defer {
            if writer.status == .writing { writer.cancelWriting() }
        }
        writer.startSession(atSourceTime: .zero)
        var videoFrame = 0, audioFrame = 0
        var deadline = Date().addingTimeInterval(10)
        while videoFrame < frameCount || (audioInput != nil && audioFrame < frameCount) {
            guard writer.status == .writing else {
                throw writer.error ?? ProbeError.writeFailed("Synthetic movie writer stopped")
            }
            var advanced = false
            // Each track advances independently. Waiting on video before feeding
            // ready audio can deadlock the writer's interleaving backpressure.
            if videoFrame < frameCount && input.isReadyForMoreMediaData {
                var pixel: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess,
                      let pixel else { throw ProbeError.writeFailed("Fixture pixel buffer unavailable") }
                CVPixelBufferLockBaseAddress(pixel, [])
                if let address = CVPixelBufferGetBaseAddress(pixel) {
                    memset(address, Int32((videoFrame * 70) % 256), CVPixelBufferGetBytesPerRow(pixel) * height)
                }
                CVPixelBufferUnlockBaseAddress(pixel, [])
                guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(videoFrame), timescale: 30)) else {
                    throw writer.error ?? ProbeError.writeFailed("Cannot append native MOV frame")
                }
                videoFrame += 1
                advanced = true
                if videoFrame == frameCount { input.markAsFinished() }
            }
            if let audioInput, audioFrame < frameCount && audioInput.isReadyForMoreMediaData {
                let samplesPerFrame = audioSampleRate / 30
                guard audioInput.append(try syntheticPCM(samples: samplesPerFrame,
                    sampleRate: audioSampleRate, noisy: noisyAudio, startSample: audioFrame * samplesPerFrame)) else {
                    throw writer.error ?? ProbeError.writeFailed("Cannot append synthetic PCM fixture")
                }
                audioFrame += 1
                advanced = true
                if audioFrame == frameCount { audioInput.markAsFinished() }
            }
            if advanced {
                deadline = Date().addingTimeInterval(10)
            } else {
                guard Date() < deadline else { throw ProbeError.writeFailed("Synthetic movie fixture stalled") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProbeError.writeFailed("Native MOV fixture unfinished") }
    }

    private func syntheticPCM(samples: Int, sampleRate: Int, noisy: Bool, startSample: Int) throws -> CMSampleBuffer {
        // Encode generated PCM once solely to create the source fixture. The
        // metadata operation never decodes or re-encodes either media track.
        let bytesPerSample = 2
        var description: CMAudioFormatDescription?
        var stream = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &stream,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description) == noErr, let description else {
            throw ProbeError.writeFailed("Synthetic PCM format unavailable")
        }
        var block: CMBlockBuffer?
        let length = samples * bytesPerSample
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
            let block else { throw ProbeError.writeFailed("Synthetic PCM block unavailable") }
        guard CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
            dataLength: length) == noErr else { throw ProbeError.writeFailed("Synthetic PCM initialization failed") }
        if noisy {
            // Deterministic generated noise gives AAC variable, nonempty packets
            // instead of relying solely on short/silence packet controls.
            var seed: UInt32 = 0x12345678 ^ UInt32(startSample)
            var pcm = Data(count: length)
            pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let values = raw.bindMemory(to: UInt16.self)
                for index in 0..<samples {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    values[index] = UInt16(truncatingIfNeeded: seed >> 16).littleEndian
                }
            }
            let copied = pcm.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: length)
            }
            guard copied == noErr else { throw ProbeError.writeFailed("Synthetic PCM data copy failed") }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(value: Int64(startSample), timescale: Int32(sampleRate)),
            decodeTimeStamp: .invalid)
        var size = bytesPerSample
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: description, sampleCount: samples, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else {
            throw ProbeError.writeFailed("Synthetic PCM sample unavailable")
        }
        return sample
    }

    func testFixtureBoxParserSupportsExtendedAndTerminalBoxSizes() throws {
        let extended = word(1) + Data("free".utf8) + qword(19) + Data([1, 2, 3])
        let terminal = word(0) + Data("mdat".utf8) + Data([4, 5])
        let parsed = try boxes(extended + terminal)
        XCTAssertEqual(parsed.map(\.type), ["free", "mdat"])
        XCTAssertEqual(parsed[0].payload, 16..<19)
        XCTAssertEqual(parsed[1].payload, 27..<29)
        XCTAssertThrowsError(try boxes(word(1) + Data("free".utf8)))
        XCTAssertThrowsError(try boxes(word(1) + Data("free".utf8) + qword(UInt64.max)))
        XCTAssertThrowsError(try boxes(word(1) + Data("free".utf8) + qword(15)))
    }

    private struct Box { let type: String; let range: Range<Int>; let payload: Range<Int> }
    private func boxes(_ data: Data) throws -> [Box] {
        var result = [Box](), offset = 0
        while offset < data.count {
            guard offset <= data.count - 8 else { throw ProbeError.malformed("Test box header truncated") }
            let declared = data[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            var header = 8
            let length: Int
            if declared == 1 {
                guard data.count - offset >= 16 else { throw ProbeError.malformed("Extended test box header truncated") }
                let extended = data[offset+8..<offset+16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard extended <= UInt64(data.count - offset) else { throw ProbeError.malformed("Extended test box exceeds bounds") }
                header = 16
                length = Int(extended)
            } else {
                length = declared == 0 ? data.count - offset : Int(declared)
            }
            guard length >= header, length <= data.count - offset else { throw ProbeError.malformed("Test box bounds invalid") }
            result.append(Box(type: String(decoding: data[offset+4..<offset+8], as: UTF8.self),
                range: offset..<offset+length, payload: offset+header..<offset+length))
            offset += length
        }
        return result
    }

    private func movieChunkCounts(_ bytes: Data) throws -> [Int] {
        let movie = try XCTUnwrap(boxes(bytes).first { $0.type == "moov" })
        let movieData = bytes.subdata(in: movie.payload)
        var result = [Int]()
        for track in try boxes(movieData) where track.type == "trak" {
            let trackData = movieData.subdata(in: track.payload)
            let mdia = try XCTUnwrap(boxes(trackData).first { $0.type == "mdia" })
            let mdiaData = trackData.subdata(in: mdia.payload)
            let minf = try XCTUnwrap(boxes(mdiaData).first { $0.type == "minf" })
            let minfData = mdiaData.subdata(in: minf.payload)
            let stbl = try XCTUnwrap(boxes(minfData).first { $0.type == "stbl" })
            let tableData = minfData.subdata(in: stbl.payload)
            let offset = try XCTUnwrap(boxes(tableData).first { $0.type == "stco" || $0.type == "co64" })
            let payload = tableData.subdata(in: offset.payload)
            guard payload.count >= 8 else { throw ProbeError.malformed("Fixture offset table truncated") }
            result.append(Int(payload[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }))
        }
        return result
    }

    private func word(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    private func qword(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> ((7 - $0) * 8)) & 255) })
    }
    private func box(_ type: String, _ payload: Data) -> Data { word(UInt32(payload.count + 8)) + Data(type.utf8) + payload }

    private func movieUserData(_ data: Data) throws -> Data {
        let movie = try XCTUnwrap(boxes(data).last { $0.type == "moov" })
        let children = data.subdata(in: movie.payload)
        let userData = try XCTUnwrap(boxes(children).first { $0.type == "udta" })
        return children.subdata(in: userData.payload)
    }

    private func firstTrackMetadataAtom(_ data: Data) throws -> Data {
        let movie = try XCTUnwrap(boxes(data).last { $0.type == "moov" })
        let moviePayload = data.subdata(in: movie.payload)
        let movieChildren = try boxes(moviePayload)
        guard let track = movieChildren.first(where: { $0.type == "trak" }) else { throw ProbeError.malformed("No test track") }
        let trackPayload = moviePayload.subdata(in: track.payload)
        guard let metadata = try boxes(trackPayload).first(where: { $0.type == "meta" }) else { throw ProbeError.malformed("No test track metadata") }
        return trackPayload.subdata(in: metadata.range)
    }

    private func structuralMovie(referenceType: String = "url ", referencePayload: Data? = nil,
                                 chunkOffset: UInt32 = 32, sampleSize: UInt32 = 4, sampleCount: UInt32 = 1,
                                 userData: Data? = nil, trackUserData: Data? = nil, mediaUserData: Data? = nil,
                                 mediaHandler: String = "vide", sampleTableExtra: Data = Data(), videoTrackCount: Int = 1,
                                 trackMeta: Data? = nil, ftypPayload: Data? = nil, extendedFtyp: Bool = false) -> Data {
        let brands = ftypPayload ?? (Data("qt  ".utf8) + word(0) + Data("qt  ".utf8) + word(0))
        let ftyp = extendedFtyp
            ? word(1) + Data("ftyp".utf8) + qword(UInt64(brands.count + 16)) + brands
            : box("ftyp", brands)
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
        let handler = box("hdlr", word(0) + word(0) + Data(mediaHandler.utf8) + Data(repeating: 0, count: 12))
        let media = minf + handler + (mediaUserData.map { box("udta", $0) } ?? Data())
        let track = box("trak", box("tkhd", dates) + box("mdia", media) + (trackUserData.map { box("udta", $0) } ?? Data()) + (trackMeta ?? Data()))
        let tracks = (0..<max(1, videoTrackCount)).reduce(into: Data()) { result, _ in result.append(track) }
        return ftyp + mdat + box("moov", box("mvhd", dates) + tracks + (userData.map { box("udta", $0) } ?? Data()))
    }
}
