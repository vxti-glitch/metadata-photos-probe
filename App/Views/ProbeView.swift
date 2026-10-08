import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ProbeCore

struct ProbeView: View {
    @StateObject private var probe = ProbeViewModel()
    @State private var showPhotos = false
    @State private var showFilePicker = false
    @State private var pickingPreparedOutput = false
    @State private var confirmSave = false
    @State private var confirmClear = false
    @State private var showShare = false
    @State private var showFilesExport = false
    @State private var exportTrialID: UUID?
    @State private var returnedTrialID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("Feasibility only") {
                    Text("This probe cannot detect or remove Photos source attribution. Inspect Apple Photos yourself and record the result below.")
                    Text("Use disposable fixtures. No conversion, visual editing, bulk processing or commercial features are included.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Device", value: probe.device.hardwareIdentifier)
                    LabeledContent("iOS", value: probe.device.osDescription)
                    if !probe.device.matchesPrimaryTarget {
                        Text("Primary acceptance target: physical iPhone 15 Pro Max, iOS 27.2. This device/build is a separate test condition.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    TextField("Settings version/build and beta/public channel", text: $probe.reportedBuild)
                        .disabled(probe.busy)
                }

                Section("1 · Controlled source") {
                    Button("Choose source from Photos") { returnedTrialID = nil; showPhotos = true }.disabled(probe.busy)
                    Button("Choose source from Files") { pickingPreparedOutput = false; showFilePicker = true }
                        .disabled(probe.busy)
                    TextField("Baseline origin: Camera / iCloud / app / Files", text: $probe.baselineOrigin)
                        .disabled(probe.busy)
                    if let source = probe.source {
                        Text(source.representation).font(.footnote)
                        ForEach(source.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        if source.assetIdentifier != nil {
                            Button("Retrieve original Photos resource") { probe.acquirePhotoResource(preferOriginal: true) }
                                .disabled(probe.busy)
                            Button("Retrieve current Photos resource") { probe.acquirePhotoResource(preferOriginal: false) }
                                .disabled(probe.busy)
                        }
                    }
                }

                if let source = probe.sourceInspection {
                    InspectionSection(title: "Source metadata", inspection: source)
                    Section("Source Photos library location") {
                        Text(probe.source?.librarySnapshot?.locationSummary ?? "Not checked. Retrieve the original Photos resource to inspect the library separately.")
                        Text("The Photos map can differ from embedded GPS. The probe never silently copies library coordinates into a file.").font(.footnote)
                    }
                }

                Section("2 · Experiment") {
                    Picker("Stage", selection: $probe.stage) {
                        ForEach(ProbeStage.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(probe.busy)
                    if probe.stage == .preparedFiles {
                        Text("First isolate Photos behavior using a prepared edited counterpart of this exact source, or an unchanged control. This is not proof of processing on iPhone.")
                            .font(.footnote)
                        Button("Choose prepared output from Files") { pickingPreparedOutput = true; showFilePicker = true }
                            .disabled(probe.busy || probe.source == nil)
                        Button("Use unchanged source as a no-op control") { probe.selectNoOp() }
                            .disabled(probe.busy || probe.source == nil)
                    } else {
                        Toggle("I completed the baseline upload test for this format on my phone", isOn: $probe.stageAReviewed)
                            .disabled(probe.busy)
                        Text("This acknowledgement is your observation, not an automatic feasibility verdict. Choose camera values different from the source.")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("Camera make", text: $probe.make).disabled(probe.busy)
                        TextField("Camera model", text: $probe.model).disabled(probe.busy)
                        if probe.sourceInspection?.kind.isImage == true {
                            TextField("Optional lens model", text: $probe.lens).disabled(probe.busy)
                        }
                        Button("Write camera metadata on this device") { probe.transform() }.disabled(!probe.canTransform)
                    }
                }

                if let output = probe.outputInspection {
                    InspectionSection(title: "Staged output metadata", inspection: output)
                }
                if let comparison = probe.comparison {
                    IntegritySection(title: "Source → staged output", result: comparison)
                    Section("3 · Export to Files for iCloud") {
                        Text("Save a copy to Files, then upload it yourself at iCloud.com/photos in Safari. This does not require choosing a PhotoKit save route.").font(.footnote)
                        Button("Save a copy to Files") {
                            exportTrialID = probe.beginFilesExport()
                            showFilesExport = exportTrialID != nil
                        }.disabled(probe.busy || probe.outputURL == nil || comparison.status == .mismatch)
                        Link("Open iCloud Photos in your browser", destination: URL(string: "https://www.icloud.com/photos/")!)
                    }
                    Section("Optional direct Photos save experiment") {
                        Picker("Photos route", selection: $probe.route) {
                            ForEach(PhotoSaveRoute.allCases) { Text($0.title).tag($0) }
                        }.disabled(probe.busy)
                        Text("Direct saves previously displayed app attribution. This diagnostic route is separate from Files/Safari export.").font(.footnote)
                        if comparison.status == .incomplete {
                            Toggle("Diagnostic save: I accept that remaining integrity checks are unverified", isOn: $probe.incompleteAcknowledged)
                                .disabled(probe.busy)
                        }
                        if probe.route == .existingContentEdit {
                            Toggle("Edit the selected disposable existing asset; I retained its baseline", isOn: $probe.existingEditConsented)
                                .disabled(probe.busy)
                            Text("Previously adjusted, rotated or incompatible assets are refused. Files-only inputs have no existing Photos target.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Run selected PhotoKit save route") { confirmSave = true }.disabled(!probe.canSave)
                    }
                }

                Section("Status") {
                    if probe.busy { ProgressView() }
                    Text(probe.status)
                    if probe.busy { Button("Request cancellation", role: .destructive) { probe.cancel() } }
                }

                if !probe.fileTrials.isEmpty {
                    FileEvidenceSection(probe: probe) { id in
                        returnedTrialID = id; showPhotos = true
                    }
                }

                if !probe.attempts.isEmpty {
                    Section("4 · Saved-resource evidence") {
                        Picker("Experiment", selection: $probe.selectedAttemptID) {
                            ForEach(probe.attempts) { attempt in
                                Text("\(attempt.sourceInspection.kind.rawValue.uppercased()) · \(attempt.route.title) · \(attempt.id.uuidString.prefix(6))")
                                    .tag(Optional(attempt.id))
                            }
                        }.disabled(probe.busy)
                        if let attempt = selectedAttempt {
                            Text(attempt.state)
                            if let error = attempt.error { Text(error).foregroundStyle(.orange) }
                            if let commit = attempt.commit {
                                Text("Asset identifier: \(commit.assetIdentifier)").font(.caption).textSelection(.enabled)
                                ForEach(commit.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                                Button("Retry resource readback only") { probe.retryReadback() }.disabled(probe.busy)
                            }
                            if let readback = attempt.readback {
                                Text("Library date: \(readback.libraryDate?.formatted() ?? "not provided")")
                                Text("Library location: \(readback.locationSummary ?? "not provided")")
                                Text("Source category: \(readback.sourceType) — does not identify an importing-app label.")
                                    .font(.caption)
                                Text("Resources: \(readback.resources.map(\.type).joined(separator: ", "))")
                                    .font(.caption)
                            }
                            ForEach(attempt.savedResourceInspections.keys.sorted(), id: \.self) { key in
                                if let inspection = attempt.savedResourceInspections[key] {
                                    DisclosureGroup(key) {
                                        MetadataRows(values: inspection.metadata)
                                        ForEach(attempt.savedCameraChecks[key] ?? [], id: \.name) { check in
                                            CheckRow(check: check)
                                        }
                                        if let integrity = attempt.savedResourceIntegrity[key] {
                                            Text("Integrity: \(integrity.status.rawValue)")
                                            ForEach(integrity.checks, id: \.name) { check in CheckRow(check: check) }
                                            ForEach(integrity.limitations, id: \.self) { Text($0).font(.caption) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Section("5 · Observe Apple Photos yourself") {
                        Text("Open the saved/edited item in Photos → Info. Record displayed camera values and the exact source label. Repeat after relaunch and after sync. Screenshot references are filenames you retain separately.")
                            .font(.footnote)
                        Picker("Observation time", selection: $probe.observationPhase) {
                            ForEach(ObservationPhase.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Camera display", selection: $probe.observedCamera) {
                            ForEach(CameraObservation.allCases) { Text($0.rawValue).tag($0) }
                        }
                        TextField("Actual camera/lens text displayed", text: $probe.observedCameraText, axis: .vertical)
                        Picker("Source attribution", selection: $probe.attribution) {
                            ForEach(AttributionObservation.allCases) { Text($0.rawValue).tag($0) }
                        }
                        TextField("Exact source-label text if present", text: $probe.attributionText, axis: .vertical)
                        TextField("Screenshot reference", text: $probe.screenshotReference)
                        TextField("Quality, playback, HDR or other observations", text: $probe.observationNotes, axis: .vertical)
                        Button("Record manual observation") { probe.addObservation() }
                        if let attempt = selectedAttempt {
                            ForEach(attempt.observations) { observation in
                                VStack(alignment: .leading) {
                                    Text(observation.phase.rawValue).font(.subheadline)
                                    Text(observation.camera.rawValue)
                                    Text(observation.attribution.rawValue)
                                }.font(.caption)
                            }
                        }
                    }.disabled(probe.busy)
                }

                Section("Local evidence") {
                    Text("Reports can contain camera values, resource filenames, locations and asset identifiers. Nothing is uploaded automatically. Share only fixtures you are comfortable disclosing.")
                        .font(.footnote)
                    Button("Export evidence JSON") { probe.exportEvidence(); showShare = probe.shareURL != nil }
                        .disabled(probe.busy)
                    Button("Clear local probe copies and evidence", role: .destructive) { confirmClear = true }
                        .disabled(probe.busy)
                }
            }
            .navigationTitle("Photos Metadata Probe")
            .onChange(of: probe.stage) { _, _ in probe.stageChanged() }
            .onChange(of: probe.route) { _, _ in probe.routeChanged() }
            .onChange(of: probe.selectedFileTrialID) { _, _ in probe.resetObservationForm() }
            .onChange(of: probe.selectedAttemptID) { _, _ in probe.resetObservationForm() }
            .sheet(isPresented: $showPhotos) {
                let returnTarget = returnedTrialID
                PhotosPicker(stagingDirectory: probe.stagingDirectory,
                    onAcquisitionStarted: { probe.beginPhotosAcquisition() },
                    onResult: { generation, result in
                        if let id = returnTarget { probe.receivedReturnedPhoto(result, acquisitionID: generation, trialID: id) }
                        else { probe.receivedPhoto(result, acquisitionID: generation) }
                        returnedTrialID = nil
                    })
            }
            .fileImporter(isPresented: $showFilePicker,
                allowedContentTypes: [.jpeg, .heic, .mpeg4Movie, .quickTimeMovie], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): probe.importFiles(urls, asPreparedOutput: pickingPreparedOutput)
                case .failure(let error): probe.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = probe.shareURL { ProbeShareSheet(url: url) }
            }
            .sheet(isPresented: $showFilesExport, onDismiss: {
                if let id = exportTrialID { probe.finishFilesExport(id: id, completed: false) }
                exportTrialID = nil
            }) {
                if let id = exportTrialID, let url = probe.filesExportURL {
                    FilesExportPicker(fileURL: url) { completed in
                        probe.finishFilesExport(id: id, completed: completed); showFilesExport = false
                    }
                }
            }
            .alert("Run controlled Photos experiment?", isPresented: $confirmSave) {
                Button("Run experiment") { probe.save() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(probe.route == .existingContentEdit
                    ? "This will change the selected disposable asset's visible content. It does not erase original metadata or control attribution."
                    : "This will create a new Photos asset. A successful save does not prove camera display, label absence or full integrity.")
            }
            .alert("Remove local probe data?", isPresented: $confirmClear) {
                Button("Remove local copies", role: .destructive) { probe.clearLocalData() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes this app's copies and reports. Photos assets and source provider files remain untouched. Export the evidence first.") }
            .alert("Probe could not complete this operation", isPresented: Binding(
                get: { probe.errorMessage != nil }, set: { if !$0 { probe.errorMessage = nil } })) {
                Button("OK", role: .cancel) { probe.errorMessage = nil }
            } message: { Text(probe.errorMessage ?? "Unknown error") }
        }
    }

    private var selectedAttempt: ProbeAttempt? { probe.attempts.first { $0.id == probe.selectedAttemptID } }
}

private struct InspectionSection: View {
    let title: String
    let inspection: MediaInspection
    var body: some View {
        Section(title) {
            LabeledContent("Format", value: inspection.kind.rawValue.uppercased())
            LabeledContent("Bytes", value: String(inspection.byteCount))
            Text("Embedded location: \(inspection.location?.summary ?? "not checked in this report")")
            if let location = inspection.location, !location.values.isEmpty {
                DisclosureGroup("Embedded location fields") { MetadataRows(values: location.values) }
            }
            MetadataRows(values: inspection.metadata)
            DisclosureGroup("Structure and limitations") {
                MetadataRows(values: inspection.structure)
                ForEach(inspection.notes, id: \.self) { Text($0).font(.caption) }
            }
        }
    }
}

private struct MetadataRows: View {
    let values: [String: String]
    var body: some View {
        if values.isEmpty { Text("No supported values found.").foregroundStyle(.secondary) }
        ForEach(values.keys.sorted(), id: \.self) { key in
            VStack(alignment: .leading, spacing: 3) {
                Text(key).font(.caption).foregroundStyle(.secondary)
                Text(values[key] ?? "").textSelection(.enabled)
            }
        }
    }
}

private struct IntegritySection: View {
    let title: String
    let result: IntegrityComparison
    var body: some View {
        Section(title) {
            Text("Integrity result: \(result.status.rawValue)").font(.headline)
            ForEach(result.checks, id: \.name) { check in CheckRow(check: check) }
            ForEach(result.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            Text("This result concerns file checks only. Photos camera display and attribution remain unverified.")
                .font(.footnote)
        }
    }
}

private struct CheckRow: View {
    let check: IntegrityCheck
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(check.name): \(check.status.rawValue)")
                .foregroundColor(check.status == .failed ? .red : check.status == .passed ? .green : .orange)
            Text(check.detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProbeShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.excludedActivityTypes = [.saveToCameraRoll]
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct FileEvidenceSection: View {
    @ObservedObject var probe: ProbeViewModel
    let inspect: (UUID) -> Void
    var body: some View {
    Section("Files/iCloud test evidence") {
        Picker("File test", selection: $probe.selectedFileTrialID) {
            ForEach(probe.fileTrials) { trial in
                Text("\(trial.outputInspection.kind.rawValue.uppercased()) · \(trial.id.uuidString.prefix(6))")
                    .tag(Optional(trial.id))
            }
        }.disabled(probe.busy)
        if let trial = probe.selectedFileTrial {
            Text(trial.exportState)
            Text("Processed file GPS: \(trial.outputInspection.location?.summary ?? "not checked")")
            Text("Original library location: \(trial.source.librarySnapshot?.locationSummary ?? "not checked")")
            Button("Inspect returned iCloud photo (optional)") {
                inspect(trial.id)
            }.disabled(probe.busy)
            if let error = trial.returnedError { Text(error).foregroundStyle(.orange) }
            if let returned = trial.returnedInspection {
                Text("Returned file GPS: \(returned.location?.summary ?? "not checked")")
                Text("Returned library location: \(trial.returnedAsset?.librarySnapshot?.locationSummary ?? "not checked")")
                MetadataRows(values: returned.metadata)
            }
            if let result = trial.returnedIntegrity {
                Text("Returned original integrity: \(result.status.rawValue)")
                ForEach(result.checks, id: \.name) { CheckRow(check: $0) }
                ForEach(result.limitations, id: \.self) { Text($0).font(.caption) }
            }
            Picker("Observation time", selection: $probe.observationPhase) {
                ForEach(ObservationPhase.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Photos source label", selection: $probe.attribution) {
                ForEach(AttributionObservation.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Exact label, if present", text: $probe.attributionText)
            Picker("Photos camera display", selection: $probe.observedCamera) {
                ForEach(CameraObservation.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Camera values actually displayed", text: $probe.observedCameraText)
            TextField("Notes / screenshot reference", text: $probe.observationNotes)
            Button("Record this external-upload observation") { probe.addFileObservation() }
            Text("Upload completion, source labels and camera display are your observations. They are not automatically detected.").font(.footnote)
            ForEach(trial.observations) { observation in
                Text("\(observation.phase.rawValue): \(observation.attribution.rawValue)").font(.caption)
            }
        }
    }.disabled(probe.busy)
    }
}
