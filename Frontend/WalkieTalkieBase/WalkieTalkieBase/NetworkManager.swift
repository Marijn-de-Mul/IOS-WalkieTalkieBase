import Foundation
import AVFoundation

class NetworkManager: NSObject {
    static let shared = NetworkManager()
    private let baseURL = "https://walkietalkie.backend.marijndemul.nl"
    private var webSocketTask: URLSessionWebSocketTask?
    private var controlWebSocketTask: URLSessionWebSocketTask?
    private var audioPlayer: AVAudioPlayer?
    private var isReceivingCallback: ((Bool) -> Void)?

    private override init() {}

    func connectWebSocket(isReceivingCallback: @escaping (Bool) -> Void) {
        self.isReceivingCallback = isReceivingCallback

        guard let url = URL(string: "\(baseURL.replacingOccurrences(of: "http", with: "ws"))/ws") else {
            print("Invalid WebSocket URL")
            return
        }
        webSocketTask = URLSession.shared.webSocketTask(with: url)
        webSocketTask?.resume()

        receiveAudio()

        guard let controlUrl = URL(string: "\(baseURL.replacingOccurrences(of: "http", with: "ws"))/ws/control") else {
            print("Invalid Control WebSocket URL")
            return
        }
        controlWebSocketTask = URLSession.shared.webSocketTask(with: controlUrl)
        controlWebSocketTask?.resume()
    }

    func disconnectWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        controlWebSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveAudio() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .failure(let error):
                print("Error receiving audio: \(error)")
            case .success(let message):
                switch message {
                case .data(let data):
                    self?.isReceivingCallback?(true)
                    self?.playAudio(data: data)
                default:
                    break
                }
            }

            self?.receiveAudio()
        }
    }

    func sendAudio(data: Data) {
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("Error sending audio: \(error)")
            }
        }
    }

    func sendControlMessage(_ message: String, completion: @escaping (String) -> Void) {
        let controlMessage = URLSessionWebSocketTask.Message.string(message)
        controlWebSocketTask?.send(controlMessage) { error in
            if let error = error {
                print("Error sending control message: \(error)")
                completion("error")
                return
            }

            self.controlWebSocketTask?.receive { result in
                switch result {
                case .failure(let error):
                    print("Error receiving control response: \(error)")
                    completion("error")
                case .success(let message):
                    switch message {
                    case .string(let response):
                        completion(response)
                    default:
                        completion("error")
                    }
                }
            }
        }
    }

    private func playAudio(data: Data) {
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.play()
            isReceivingCallback?(false)
        } catch {
            print("Error playing audio: \(error)")
        }
    }
}
