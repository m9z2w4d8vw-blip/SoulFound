import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var client: SoulseekClient
    @EnvironmentObject var settings: AppSettings

    @State private var showFolderPicker = false
    @State private var showLogoutConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if client.isConnected {
                        LabeledContent("Logged in as", value: client.username)
                    } else {
                        Text("Not logged in")
                            .foregroundStyle(.secondary)
                    }
                    Button("Log Out", role: .destructive) {
                        showLogoutConfirm = true
                    }
                    .disabled(!client.isConnected)
                }

                Section {
                    LabeledContent("Save to", value: settings.downloadFolderDisplayName)
                    Button("Choose Folder…") { showFolderPicker = true }
                    if settings.downloadFolderBookmark != nil {
                        Button("Reset to Default", role: .destructive) {
                            settings.resetDownloadFolder()
                        }
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Only applies to new downloads — files already saved stay where they are.")
                }

                Section("Appearance") {
                    Toggle("Light Mode", isOn: $settings.isLightMode)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in
                    settings.setDownloadFolder(url)
                }
            }
            .confirmationDialog(
                "Log out of Soulseek?",
                isPresented: $showLogoutConfirm,
                titleVisibility: .visible
            ) {
                Button("Log Out", role: .destructive) {
                    KeychainHelper.clear()
                    client.disconnect()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to enter your username and password again next time.")
            }
        }
    }
}

/// Thin SwiftUI wrapper around UIDocumentPickerViewController in folder-picking
/// mode, so the user can point downloads at any folder they have Files access
/// to (iCloud Drive, a Shortcuts-mounted location, another app's shared
/// container, etc) rather than just the app's own sandbox.
private struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // Bookmark creation below doesn't require an active accessing
            // session to succeed, but starting/stopping here confirms we
            // actually have permission before AppSettings persists anything.
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            onPick(url)
        }
    }
}
