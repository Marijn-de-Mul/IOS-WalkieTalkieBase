import SwiftUI
import AVFoundation

struct ContentView: View {
    @ObservedObject var networkManager = NetworkManager()
    @State private var showingAlert = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            radioView()
                .tabItem {
                    Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                }
            OptionsView(networkManager: networkManager)
                .tabItem {
                    Label("Options", systemImage: "gearshape")
                }
        }
        .onAppear {
            networkManager.configureAudioSession()
            networkManager.connect() // Automatically connect
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .active:
                print("App became active")
                if !networkManager.isConnected {
                    networkManager.connect()
                }
            case .inactive:
                print("App became inactive")
                // Optionally handle deactivation tasks
            case .background:
                print("App moved to the background")
                // Optionally handle background tasks
            @unknown default:
                print("Unexpected app phase")
            }
        }
    }

    private func radioView() -> some View {
        NavigationView {
            VStack {
                Spacer() // Pushes content to the middle

                // Header
                Text("WalkioTalkio")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom)

                // Status Icons
                StatusIconsView(
                    isRecording: networkManager.isRecordingAudio,
                    isConnected: networkManager.isConnected,
                    isTransmitting: networkManager.isTransmitting,
                    isReceiving: networkManager.isReceiving
                )
                .padding(.bottom)

                // Channel selection hint (future addition)
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                    Text("Channel support coming soon")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding(.bottom)

                // Audio Visualizer
                AudioVisualizer(networkManager: networkManager)
                    .frame(height: 50)
                    .padding(.horizontal)
                    .padding(.bottom)

                // Talk Button
                Button(action: {
                    if networkManager.isTalking {
                        showingAlert = true
                    } else {
                        if networkManager.isRecordingAudio {
                            networkManager.stopRecording()
                        } else {
                            networkManager.startRecording()
                        }
                    }
                }) {
                    Text(networkManager.isRecordingAudio ? "Stop Recording" : "Start Recording")
                        .padding()
                        .foregroundColor(.white)
                        .background(networkManager.isRecordingAudio ? Color.red : Color.blue)
                        .cornerRadius(10)
                        .opacity(networkManager.isTalking ? 0.5 : 1.0) // Reduce opacity when disabled
                }
                .disabled(networkManager.isTalking)
                .alert(isPresented: $showingAlert) {
                    Alert(
                        title: Text("Busy"),
                        message: Text("Only one person can transmit at a time on 1 channel."),
                        dismissButton: .default(Text("OK"))
                    )
                }

                Spacer() // Pushes content to the middle
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Use available space
            .multilineTextAlignment(.center) // Center text within elements
            .navigationBarHidden(true)
        }
    }
}

struct StatusIconsView: View {
    let isRecording: Bool
    let isConnected: Bool
    let isTransmitting: Bool
    let isReceiving: Bool

    var body: some View {
        HStack(spacing: 24) {
            statusItem(
                systemName: isRecording ? "mic.circle.fill" : "mic.circle",
                title: "Recording",
                color: isRecording ? .red : .gray
            )
            statusItem(
                systemName: isConnected ? "wifi" : "wifi.slash",
                title: "Network",
                color: isConnected ? .green : .gray
            )
            statusItem(
                systemName: isTransmitting ? "arrow.up.circle.fill" : "arrow.up.circle",
                title: "TX",
                color: isTransmitting ? .blue : .gray
            )
            statusItem(
                systemName: isReceiving ? "arrow.down.circle.fill" : "arrow.down.circle",
                title: "RX",
                color: isReceiving ? .blue : .gray
            )
        }
        .font(.caption)
    }

    @ViewBuilder
    private func statusItem(systemName: String, title: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.title2)
                .foregroundColor(color)
            Text(title)
                .foregroundColor(color)
        }
    }
}

class AudioInputMonitor: ObservableObject {
    @Published var averagePower: Float = 0.0
    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?

    init() {
        setupRecorder()
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func setupRecorder() {
        let url = URL(fileURLWithPath: "/dev/null")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatAppleLossless),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            audioRecorder?.prepareToRecord()
        } catch {
            print("Could not set up audio recorder: \(error)")
        }
    }

    func startMonitoring() {
        audioRecorder?.record()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.audioRecorder?.updateMeters()
            self?.averagePower = self?.audioRecorder?.averagePower(forChannel: 0) ?? -160
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        audioRecorder?.stop()
    }
}

struct AudioVisualizer: View {
    @ObservedObject var networkManager: NetworkManager
    @StateObject var audioInputMonitor = AudioInputMonitor()
    @State private var amplitudes: [CGFloat] = Array(repeating: 0.0, count: 20)

    var body: some View {
        HStack {
            ForEach(0..<amplitudes.count, id: \.self) { index in
                Rectangle()
                    .fill(Color.green)
                    .frame(width: 5, height: calculateBarHeight(index: index))
                    .padding(.horizontal, 1)
            }
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            updateAmplitudes()
        }
    }

    private func calculateBarHeight(index: Int) -> CGFloat {
        let normalizedPower = CGFloat(min(1, max(0, 1 + audioInputMonitor.averagePower / 160)))
        return normalizedPower * 50
    }

    private func updateAmplitudes() {
        var newAmplitudes: [CGFloat] = []
        for _ in 0..<amplitudes.count {
            let randomAmplitude = CGFloat.random(in: 0...50)
            newAmplitudes.append(randomAmplitude)
        }
        amplitudes = newAmplitudes
    }
}
