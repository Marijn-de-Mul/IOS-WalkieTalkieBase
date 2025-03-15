import SwiftUI

struct OptionsView: View {
    @ObservedObject var networkManager: NetworkManager

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Advanced").font(.headline)) {
                    NavigationLink(destination: LogView(networkManager: networkManager)) {
                        Label("View Log", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        print("Settings saved!")
                    }
                }
            }
        }
    }
}

struct LogView: View {
    @ObservedObject var networkManager: NetworkManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                ForEach(networkManager.logMessages, id: \.self) { msg in
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text(msg)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
            .padding()
        }
        .navigationTitle("Log Messages")
        .navigationBarTitleDisplayMode(.inline)
    }
}
