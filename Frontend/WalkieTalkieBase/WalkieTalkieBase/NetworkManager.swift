import Foundation
import AVFoundation
import Combine

class NetworkManager: ObservableObject {
    private let serverURL = "ws://walkietalkie.backend.marijndemul.nl/ws/control"
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession
    private var outputEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var inputEngine: AVAudioEngine?
    private var connectedURL: URL?
    private var lastAudioDataReceived: Date?
    private var silenceTimer: Timer?

    @Published var logMessages: [String] = []
    @Published var isRecordingAudio = false
    @Published var isConnected: Bool = false
    @Published var isTransmitting: Bool = false
    @Published var isReceiving: Bool = false
    @Published var isTalking: Bool = false {
        didSet {
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }

    init() {
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config)
        setupSilenceTimer()
    }

    deinit {
        silenceTimer?.invalidate()
    }

    func connect() {
        guard let url = URL(string: serverURL) else {
            log("Invalid URL")
            return
        }
        connectedURL = url
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()
        log("Connected to WebSocket")
        startPlayback()
        receiveMessages()
        DispatchQueue.main.async {
            self.isConnected = true
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        log("Disconnected from WebSocket")
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }

    func sendControlMessage(_ message: String, completion: @escaping (String?) -> Void) {
        guard let webSocketTask = webSocketTask else {
            log("WebSocket not connected")
            completion(nil)
            return
        }
        let wsMessage = URLSessionWebSocketTask.Message.string(message)
        webSocketTask.send(wsMessage) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.log("Error sending control message: \(error.localizedDescription)")
                completion(nil)
            } else {
                self.log("Sent control message: \(message)")
                completion(message)
            }
        }
    }

    func sendAudioData(_ data: Data) {
        guard let webSocketTask = webSocketTask else {
            log("WebSocket not connected for audio")
            return
        }
        if data.isEmpty {
            log("Audio data is empty, not sending")
            return
        }
        let wsMessage = URLSessionWebSocketTask.Message.data(data)
        webSocketTask.send(wsMessage) { [weak self] error in
            if let error = error {
                self?.log("Error sending audio data: \(error.localizedDescription)")
            } else {
                self?.log("Sent audio data: \(data.count) bytes")
            }
        }
    }

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.log("Error receiving message: \(error.localizedDescription)")
            case .success(let message):
                switch message {
                case .string(let text):
                    self.log("Received text: \(text)")
                    DispatchQueue.main.async {
                        if text == "start_ack" {
                            self.isTransmitting = true
                        } else if text == "stop_ack" {
                            self.isTransmitting = false
                        }
                    }
                case .data(let data):
                    self.log("Received audio data: \(data.count) bytes")
                    // Play audio data if not recording
                    if !self.isRecordingAudio {
                        self.playAudioData(data)
                        DispatchQueue.main.async {
                            self.isTalking = true
                            self.isReceiving = true
                            self.lastAudioDataReceived = Date()
                        }
                    } else {
                        self.log("Skipping playback while recording")
                    }
                @unknown default:
                    break
                }
            }
            self.receiveMessages()
        }
    }

    func startRecording() {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] allowed in
                guard let self = self else { return }
                self.handleRecordPermission(allowed: allowed)
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
                guard let self = self else { return }
                self.handleRecordPermission(allowed: allowed)
            }
        }
    }

    func stopRecording() {
        DispatchQueue.main.async {
            self.isRecordingAudio = false
            self.isTalking = false
            self.isReceiving = false
        }
        if let engine = inputEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            log("Stopped recording")
        }
        sendControlMessage("stop") { _ in
            self.log("Control stop message sent")
        }
    }

    func startPlayback() {
        if outputEngine == nil || playerNode == nil {
            outputEngine = AVAudioEngine()
            playerNode = AVAudioPlayerNode()
            guard let engine = outputEngine, let player = playerNode else {
                log("Playback engine or player not available")
                return
            }
            engine.attach(player)
            let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: mixerFormat)
            player.volume = 1.0
            do {
                try engine.start()
                player.play()
                log("Started playback")
            } catch {
                log("Error starting playback: \(error.localizedDescription)")
            }
        } else {
            log("Playback engine already started")
        }
    }

    func playAudioData(_ data: Data) {
        guard let player = playerNode, let engine = outputEngine else {
            log("Playback engine or player not available")
            startPlayback()
            return
        }
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let bytesPerSample = MemoryLayout<Int16>.size
        let sampleCount = data.count / bytesPerSample

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: mixerFormat,
                                               frameCapacity: AVAudioFrameCount(sampleCount)) else {
            log("Failed to create PCM buffer")
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let rawBytes = buffer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                log("Failed to bind memory to Int16")
                return
            }

            let floatChannelData = pcmBuffer.floatChannelData?[0]
            for i in 0..<sampleCount {
                floatChannelData?[i] = Float(rawBytes[i]) / Float(Int16.max)
            }
        }

        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
        log("Buffer scheduled: \(sampleCount) samples (\(data.count) bytes)")
    }

    private func audioBufferToData(buffer: AVAudioPCMBuffer) -> Data {
        let frameLength = Int(buffer.frameLength)
        if let int16ChannelData = buffer.int16ChannelData {
            let samples = int16ChannelData[0]
            let data = Data(bytes: samples, count: frameLength * MemoryLayout<Int16>.size)
            log("Converted audio buffer using int16ChannelData: \(data.count) bytes")
            return data
        }
        if let floatChannelData = buffer.floatChannelData {
            let floatSamples = floatChannelData[0]
            var int16Samples = [Int16](repeating: 0, count: frameLength)
            let gain: Float = 1.0
            for i in 0..<frameLength {
                let amplified = floatSamples[i] * gain
                int16Samples[i] = Int16(clamping: Int(amplified * 32767))
            }
            let data = Data(bytes: int16Samples, count: int16Samples.count * MemoryLayout<Int16>.size)
            log("Converted audio buffer using floatChannelData: \(data.count) bytes")
            return data
        }
        log("No valid channel data found in audio buffer")
        return Data()
    }

    internal func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try audioSession.setActive(true)
            log("Audio session configured and activated")
        } catch {
            log("Failed to configure and activate audio session: \(error.localizedDescription)")
        }
    }

    func log(_ message: String) {
        DispatchQueue.main.async {
            self.logMessages.append(message)
            print(message)
        }
    }

    private func handleRecordPermission(allowed: Bool) {
        DispatchQueue.main.async {
            if allowed {
                self.configureAudioSession()
                self.isRecordingAudio = true
                self.isTalking = false
                self.isReceiving = false
                self.sendControlMessage("start") { _ in
                    self.log("Control start message sent")
                }
                self.inputEngine = AVAudioEngine()
                guard let engine = self.inputEngine else { return }
                let inputNode = engine.inputNode
                let format = inputNode.inputFormat(forBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    guard let self = self else { return }
                    let audioData = self.audioBufferToData(buffer: buffer)
                    if audioData.isEmpty {
                        self.log("Converted audio data is empty")
                    } else {
                        self.sendAudioData(audioData)
                    }
                }
                do {
                    try engine.start()
                    self.log("Started recording")
                } catch {
                    self.log("Error starting recording: \(error.localizedDescription)")
                }
            } else {
                self.log("Microphone permission denied")
            }
        }
    }

    private func setupSilenceTimer() {
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let lastReceived = self.lastAudioDataReceived, Date().timeIntervalSince(lastReceived) > 0.5 {
                    self.isTalking = false
                    self.isReceiving = false
                }
            }
        }
    }
}
