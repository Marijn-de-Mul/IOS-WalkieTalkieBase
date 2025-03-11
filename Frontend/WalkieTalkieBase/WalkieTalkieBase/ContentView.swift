import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject var networkManager = NetworkManager()
    @State private var isRecording = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text(isRecording ? "Recording..." : "Idle")
                .font(.title)
                .padding()
            Button(action: toggleRecording) {
                Text(isRecording ? "Stop" : "Press to Talk")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(isRecording ? Color.red : Color.green)
                    .cornerRadius(10)
            }
            List {
                ForEach(Array(networkManager.logMessages.enumerated()), id: \.offset) { index, msg in
                    Text(msg)
                }
            }
        }
        .onAppear {
            configureAudioSession()
            networkManager.connect()
            networkManager.startPlayback()
        }
    }
    
    private func toggleRecording() {
        isRecording.toggle()
        if isRecording {
            networkManager.sendControlMessage("start") { response in
                if response == "start" || response == "start_ack" {
                    DispatchQueue.main.async {
                        networkManager.startRecording()
                    }
                }
            }
        } else {
            networkManager.stopRecording()
            networkManager.sendControlMessage("stop") { _ in }
        }
    }
    
    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
            networkManager.log("Audio session configured and activated")
        } catch {
            networkManager.log("Failed to configure and activate audio session: \(error.localizedDescription)")
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}