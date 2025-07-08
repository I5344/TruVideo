import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var cameraModel = CameraModel()
    @State private var recordingTime: Int = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            CameraPreview(session: cameraModel.session)
                .ignoresSafeArea()

            if cameraModel.isProcessing {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                ProgressView("Uploading...")
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .foregroundColor(.white)
                    .font(.headline)
            }

            VStack {
                // Timer display
                Text(formattedTime)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.top, 60)

                Spacer()

                HStack(spacing: 40) {
                    // Start / Stop Button (correct behavior across paused state)
                    Button(action: {
                        if cameraModel.isRecording || cameraModel.canResume {
                            // Stop recording regardless of paused or active
                            cameraModel.stopRecording()
                            stopTimer()
                            recordingTime = 0
                        } else {
                            // Start fresh recording
                            cameraModel.startRecording()
                            startTimer()
                        }
                    }) {
                        Image(systemName: (cameraModel.isRecording || cameraModel.canResume) ? "stop.fill" : "circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor((cameraModel.isRecording || cameraModel.canResume) ? .white : .red)
                            .padding(24)
                            .background((cameraModel.isRecording || cameraModel.canResume) ? Color.red : Color.white)
                            .clipShape(Circle())
                            .shadow(radius: 4)
                    }
                    .disabled(cameraModel.isProcessing)

                    // Pause / Resume Button
                    Button(action: {
                        if cameraModel.canPause {
                            cameraModel.pauseRecording()
                            stopTimer()
                        } else if cameraModel.canResume {
                            cameraModel.resumeRecording()
                            startTimer()
                        }
                    }) {
                        Image(systemName: cameraModel.canResume ? "play.fill" : "pause.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                            .padding(24)
                            .background(Color.blue)
                            .clipShape(Circle())
                            .shadow(radius: 4)
                    }
                    .disabled(!(cameraModel.canPause || cameraModel.canResume) || cameraModel.isProcessing)
                    .opacity(cameraModel.isRecording || cameraModel.canResume ? 1 : 0.5)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            cameraModel.configure()
        }
        .onDisappear {
            stopTimer()
            cameraModel.stopSession()
        }
    }

    // Timer formatting
    var formattedTime: String {
        let minutes = recordingTime / 60
        let seconds = recordingTime % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // Timer handling
    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            recordingTime += 1
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
