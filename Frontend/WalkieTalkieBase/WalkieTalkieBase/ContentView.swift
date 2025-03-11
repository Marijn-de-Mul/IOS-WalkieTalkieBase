import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var isRecording = false
    @State private var isReceiving = false
    @State private var audioRecorder: AVAudioRecorder?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isBusy = false

    var body: some View {
        VStack {
            Text(isReceiving ? "Receiving Audio..." : "Idle")
                .font(.headline)
                .foregroundColor(isReceiving ? .blue : .gray)
                .padding()

            Spacer()

            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.green)
                    .frame(width: 150, height: 150)
                    .shadow(radius: 10)

                Text(isRecording ? "Recording..." : "Press to Talk")
                    .foregroundColor(.white)
                    .font(.headline)
            }
            .onTapGesture {
                isRecording.toggle()
                if isRecording {
                    startRecording()
                } else {
                    stopRecording()
                }
            }

            Spacer()

            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .resizable()
                    .frame(width: 50, height: 50)
                    .foregroundColor(.gray)
                Spacer()
                Image(systemName: "speaker.wave.2.fill")
                    .resizable()
                    .frame(width: 50, height: 50)
                    .foregroundColor(.gray)
            }
            .padding()
        }
        .padding()
        .onAppear {
            NetworkManager.shared.connectWebSocket { isReceiving in
                self.isReceiving = isReceiving
            }
        }
        .onDisappear {
            NetworkManager.shared.disconnectWebSocket()
        }
    }

    func startRecording() {
        NetworkManager.shared.sendControlMessage("start") { response in
            if response == "start_ack" {
                let audioFilename = getDocumentsDirectory().appendingPathComponent("recording.wav")
                let settings = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]

                do {
                    audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
                    audioRecorder?.isMeteringEnabled = true
                    audioRecorder?.record()

                    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                        guard let recorder = self.audioRecorder else {
                            timer.invalidate()
                            return
                        }

                        recorder.updateMeters()
                        let data = try! Data(contentsOf: recorder.url)
                        NetworkManager.shared.sendAudio(data: data)
                    }
                } catch {
                    print("Failed to start recording: \(error)")
                }
            } else if response == "busy" {
                isBusy = true
            }
        }
    }

    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        NetworkManager.shared.sendControlMessage("stop") { response in
            if response == "stop_ack" {
                isBusy = false
            }
        }
    }

    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
