//
//  CameraModel.swift
//  TruVideo
//

import AVFoundation
import UIKit
import StoreKit

class CameraModel: NSObject, ObservableObject {
    public private(set) var session = AVCaptureSession()

    private var videoInputDevice: AVCaptureDeviceInput?
    private var audioInputDevice: AVCaptureDeviceInput?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?

    private var videoSettings: [String: Any] = [:]
    private var audioSettings: [String: Any] = [:]

    private var startTime: CMTime?
    private let recordingQueue = DispatchQueue(label: "VideoRecordingQueue")

    private var currentSegmentURL: URL?
    private var segmentURLs: [URL] = []

    @Published var isRecording = false
    @Published var canPause = false
    @Published var canResume = false
    @Published var isProcessing = false

    private var isWriting = false

    func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            print("❌ Failed to add camera input")
            return
        }

        session.addInput(videoInput)
        videoInputDevice = videoInput

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            audioInputDevice = audioInput
        }

        videoOutput.setSampleBufferDelegate(self, queue: recordingQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        audioOutput.setSampleBufferDelegate(self, queue: recordingQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov) ?? [:]
        audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any] ?? [:]

        session.commitConfiguration()
        session.startRunning()
    }

    func stopSession() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func startRecording() {
        segmentURLs.removeAll()
        startNewSegment()
        canPause = true
        canResume = false
    }

    private func startNewSegment() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Segment_\(UUID().uuidString).mov")
        currentSegmentURL = tempURL

        do {
            assetWriter = try AVAssetWriter(outputURL: tempURL, fileType: .mov)

            videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)

            videoWriterInput?.expectsMediaDataInRealTime = true
            audioWriterInput?.expectsMediaDataInRealTime = true

            if let videoWriterInput = videoWriterInput, assetWriter?.canAdd(videoWriterInput) == true {
                assetWriter?.add(videoWriterInput)
            }

            if let audioWriterInput = audioWriterInput, assetWriter?.canAdd(audioWriterInput) == true {
                assetWriter?.add(audioWriterInput)
            }

            isWriting = true
            isRecording = true
            startTime = nil
        } catch {
            print("❌ Error starting new segment: \(error)")
        }
    }

    func pauseRecording() {
        guard isWriting else { return }

        isRecording = false
        canPause = false
        canResume = true

        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()

        assetWriter?.finishWriting { [weak self] in
            guard let self = self, let finishedURL = self.currentSegmentURL else { return }

            DispatchQueue.main.async {
                self.segmentURLs.append(finishedURL)
                self.assetWriter = nil
                self.videoWriterInput = nil
                self.audioWriterInput = nil
                self.currentSegmentURL = nil
                self.isWriting = false

                print("⏸️ Paused recording. Saved segment: \(finishedURL.lastPathComponent)")
            }
        }
    }

    func resumeRecording() {
        canPause = true
        canResume = false
        startNewSegment()
        print("▶️ Resumed recording")
    }

    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        canPause = false
        canResume = false
        isProcessing = true

        if isWriting {
            videoWriterInput?.markAsFinished()
            audioWriterInput?.markAsFinished()
            assetWriter?.finishWriting { [weak self] in
                guard let self = self, let finalURL = self.currentSegmentURL else { return }
                self.segmentURLs.append(finalURL)
                self.finalizeRecording()
            }
        } else {
            finalizeRecording()
        }
    }

    private func finalizeRecording() {
        mergeSegments { [weak self] mergedURL in
            guard let self = self else { return }
            guard let finalURL = mergedURL else {
                print("❌ Merge failed")
                DispatchQueue.main.async {
                    self.isProcessing = false
                }
                return
            }

            self.uploadVideo(url: finalURL)
        }
    }

    private func mergeSegments(completion: @escaping (URL?) -> Void) {
        let mixComposition = AVMutableComposition()
        guard let videoTrack = mixComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(nil)
            return
        }

        var insertTime = CMTime.zero
        for url in segmentURLs {
            let asset = AVAsset(url: url)
            if let vTrack = asset.tracks(withMediaType: .video).first {
                try? videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: vTrack, at: insertTime)
            }
            if let aTrack = asset.tracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: aTrack, at: insertTime)
            }
            insertTime = insertTime + asset.duration
        }

        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("FinalCompressedVideo.mp4")
        try? FileManager.default.removeItem(at: exportURL)

        guard let exporter = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPreset1280x720) else {
            completion(nil)
            return
        }

        exporter.outputURL = exportURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.fileLengthLimit = 500_000_000 // ~500MB

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed:
                    print("✅ Export succeeded: \(exportURL)")
                    completion(exportURL)
                case .failed:
                    print("❌ Export failed: \(exporter.error?.localizedDescription ?? "Unknown error")")
                    completion(nil)
                case .cancelled:
                    print("❌ Export cancelled")
                    completion(nil)
                default:
                    print("⚠️ Export finished with status: \(exporter.status)")
                    completion(nil)
                }
            }
        }
    }

    private func uploadVideo(url: URL) {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://webhook.site/6ea66387-31d3-42fa-ad61-7787376ad5c7")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        do {
            let fileData = try Data(contentsOf: url)
            var body = Data()

            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"video.mp4\"\r\n")
            body.append("Content-Type: video/mp4\r\n\r\n")
            body.append(fileData)
            body.append("\r\n--\(boundary)--\r\n")

            request.httpBody = body

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    self.isProcessing = false
                }

                if let error = error {
                    print("❌ Upload failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.presentAppClipOverlay(success: false)
                    }
                    return
                }

                if let httpResp = response as? HTTPURLResponse {
                    print("📡 HTTP Status: \(httpResp.statusCode)")
                }

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    print("📥 Server Response: \(responseString)")
                }

                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    print("❌ Upload failed: \(String(describing: response))")
                    DispatchQueue.main.async {
                        self.presentAppClipOverlay(success: false)
                    }
                    return
                }

                print("✅ Video uploaded successfully")
                DispatchQueue.main.async {
                    self.presentAppClipOverlay(success: true)
                }
            }

            task.resume()

        } catch {
            print("❌ Failed to read video data: \(error)")
            DispatchQueue.main.async {
                self.isProcessing = false
                self.presentAppClipOverlay(success: false)
            }
        }
    }

    private func presentAppClipOverlay(success: Bool) {
        guard let rootVC = UIApplication.shared.windows.first?.rootViewController else {
            print("❌ Cannot get root view controller.")
            return
        }

        let title = success ? "Upload Complete" : "Upload Failed"
        let message = success
            ? "Upload successfully completed. You can get the full app for more features!"
            : "There was a problem uploading your video. Please try again."

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            if success {
                let config = SKOverlay.AppConfiguration(appIdentifier: "1337738505", position: .bottom)
                let overlay = SKOverlay(configuration: config)
                overlay.delegate = self

                if let windowScene = rootVC.view.window?.windowScene {
                    overlay.present(in: windowScene)
                } else {
                    print("❌ Unable to get UIWindowScene for SKOverlay.")
                }
            }
        }))

        DispatchQueue.main.async {
            rootVC.present(alert, animated: true, completion: nil)
        }
    }

}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isWriting, isRecording else { return }

        if startTime == nil {
            startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            assetWriter?.startWriting()
            if let start = startTime {
                assetWriter?.startSession(atSourceTime: start)
            }
        }

        if output == videoOutput,
           let videoInput = videoWriterInput,
           videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        } else if output == audioOutput,
                  let audioInput = audioWriterInput,
                  audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }
}

extension CameraModel: SKOverlayDelegate {
    func storeOverlayWillStartPresentation(_ overlay: SKOverlay) {
        print("🛍 App Clip overlay will present")
    }

    func storeOverlayDidFinishPresentation(_ overlay: SKOverlay) {
        print("🛍 App Clip overlay finished")
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
