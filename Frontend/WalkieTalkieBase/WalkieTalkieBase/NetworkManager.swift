import Foundation
import AVFoundation
import Combine

class NetworkManager: ObservableObject {
    // WebSocket properties
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession
    private let serverURL = "ws://walkietalkie.backend.marijndemul.nl/ws/control"
    
    // Audio playback properties
    private var outputEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    
    // Audio recording properties
    private var inputEngine: AVAudioEngine?
    
    @Published var logMessages: [String] = []
    
    // NEW: Flag to indicate if we are recording/sending audio.
    @Published var isRecordingAudio = false
    
    init() {
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config)
    }
    
    // MARK: WebSocket Connection
    
    func connect() {
        guard let url = URL(string: serverURL) else {
            log("Invalid URL")
            return
        }
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()
        log("Connected to WebSocket")
        receiveMessages()
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        log("Disconnected from WebSocket")
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
                case .data(let data):
                    self.log("Received audio data: \(data.count) bytes")
                    // Only play audio when not sending audio.
                    if !self.isRecordingAudio {
                        self.playAudioData(data)
                    } else {
                        self.log("Skipping playback while recording")
                    }
                @unknown default:
                    break
                }
            }
            // Schedule next receive
            self.receiveMessages()
        }
    }
    
    func log(_ message: String) {
        DispatchQueue.main.async {
            self.logMessages.append(message)
            print(message)
        }
    }
    
    // MARK: Audio Recording and Playback
    
    func startRecording() {
        isRecordingAudio = true  // Set flag before starting tap.
        inputEngine = AVAudioEngine()
        guard let engine = inputEngine else { return }
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        // Install a tap (use a buffer size of 1024 samples)
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
            log("Started recording")
        } catch {
            log("Error starting recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        isRecordingAudio = false   
        if let engine = inputEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            log("Stopped recording")
        }
    }
    
    func startPlayback() {
        outputEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        guard let engine = outputEngine, let player = playerNode else {
            log("Playback engine or player not available")
            return
        }
        engine.attach(player)
        // Use the main mixer node's output format (typically PCM Float32)
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
    }
        
    func playAudioData(_ data: Data) {
        guard let player = playerNode, let engine = outputEngine else {
            log("Playback engine or player not available")
            return
        }
        
        // Use the main mixer's output format (typically PCM Float32).
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        
        let bytesPerSample = MemoryLayout<Int16>.size
        let sampleCount = data.count / bytesPerSample
        if sampleCount == 0 {
            log("Frame count is zero")
            return
        }
        
        // Convert raw data (assumed to be Int16) to [Int16].
        let int16Array: [Int16] = data.withUnsafeBytes { buffer in
            return Array(buffer.bindMemory(to: Int16.self))
        }
        
        // Convert Int16 samples to Float32 in the range -1.0 ... 1.0.
        let floatArray: [Float] = int16Array.map { Float($0) / 32768.0 }
        
        // Create a PCM buffer using the mixer format.
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: mixerFormat,
                                               frameCapacity: AVAudioFrameCount(sampleCount)) else {
            log("Failed to create PCM buffer")
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)
        
        // Copy the converted float samples into the buffer.
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            log("Buffer floatChannelData is nil")
            return
        }
        let channel = floatChannelData[0]
        for i in 0..<sampleCount {
            channel[i] = floatArray[i]
        }
        
        // Schedule the buffer for playback.
        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
        
        // Ensure the player is playing.
        if !player.isPlaying {
            player.play()
        }
        
        log("Buffer scheduled: \(sampleCount) samples (\(data.count) bytes)")
    }

    private func audioBufferToData(buffer: AVAudioPCMBuffer) -> Data {
        let frameLength = Int(buffer.frameLength)
        
        // Attempt to use int16ChannelData first.
        if let int16ChannelData = buffer.int16ChannelData {
            let samples = int16ChannelData[0]
            let data = Data(bytes: samples, count: frameLength * MemoryLayout<Int16>.size)
            log("Converted audio buffer using int16ChannelData: \(data.count) bytes")
            return data
        }
        
        // Fallback: Convert from floatChannelData.
        if let floatChannelData = buffer.floatChannelData {
            let floatSamples = floatChannelData[0]
            var int16Samples = [Int16](repeating: 0, count: frameLength)
            for i in 0..<frameLength {
                // Clamp and convert Float32 samples in the range [-1.0, 1.0] to Int16.
                int16Samples[i] = Int16(clamping: Int(floatSamples[i] * 32767))
            }
            let data = Data(bytes: int16Samples, count: int16Samples.count * MemoryLayout<Int16>.size)
            log("Converted audio buffer using floatChannelData: \(data.count) bytes")
            return data
        }
        
        log("No valid channel data found in audio buffer")
        return Data()
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
            log("Audio session configured and activated")
        } catch {
            log("Failed to configure and activate audio session: \(error.localizedDescription)")
        }
    }
}