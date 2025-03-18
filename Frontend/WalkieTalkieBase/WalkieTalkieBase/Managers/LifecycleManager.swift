import Foundation
import Combine
import SwiftUI

class LifecycleManager: ObservableObject {
    private var networkManager: NetworkManager
    private var cancellables = Set<AnyCancellable>()

    init(networkManager: NetworkManager) {
        self.networkManager = networkManager
        observeLifecycleEvents()
    }

    private func observeLifecycleEvents() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.handleAppDidEnterBackground()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppDidBecomeActive()
            }
            .store(in: &cancellables)
    }

    private func handleAppDidEnterBackground() {
        print("App entered background")
        networkManager.disconnect()
    }

    private func handleAppDidBecomeActive() {
        print("App became active")
        if !networkManager.isConnected {
            networkManager.connect()
        }
    }
}