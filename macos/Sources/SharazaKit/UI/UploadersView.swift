import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct UploadersView: View {
    @ObservedObject var appState: AppState

    @State private var imgurClientId: String = KeychainManager.shared.getSecret(for: .imgurClientId) ?? ""
    @State private var imgurBearer: String = KeychainManager.shared.getSecret(for: .imgurBearerToken) ?? ""
    @State private var vgymeKey: String = KeychainManager.shared.getSecret(for: .vgymeUserKey) ?? ""
    @State private var pastebinKey: String = KeychainManager.shared.getSecret(for: .pastebinDevKey) ?? ""
    @State private var githubToken: String = KeychainManager.shared.getSecret(for: .githubGistToken) ?? ""
    @State private var bitlyToken: String = KeychainManager.shared.getSecret(for: .bitlyAccessToken) ?? ""
    @State private var dropboxToken: String = KeychainManager.shared.getSecret(for: .dropboxAccessToken) ?? ""
    @State private var nextcloudUrl: String = KeychainManager.shared.getSecret(for: .nextcloudWebDavUrl) ?? ""
    @State private var nextcloudUser: String = KeychainManager.shared.getSecret(for: .nextcloudUsername) ?? ""
    @State private var nextcloudPass: String = KeychainManager.shared.getSecret(for: .nextcloudPassword) ?? ""
    @State private var s3Presigned: String = KeychainManager.shared.getSecret(for: .s3PresignedUrl) ?? ""
    @State private var sxcuDraft: String = """
{
  "Version": "22.4.0",
  "Name": "Example Custom Host",
  "DestinationType": "ImageUploader, FileUploader",
  "RequestMethod": "POST",
  "RequestURL": "https://example.com/api/upload",
  "Body": "MultipartFormData",
  "FileFormName": "file",
  "URL": "$json:data.url$"
}
"""

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        Form {
            Section("Active Destinations") {
                Picker("Image Uploader", selection: $appState.config.default_settings.image_uploader) {
                    ForEach(BuiltinImageUploader.allCases) { u in
                        Text(u.displayName).tag(u)
                    }
                }
                .onChange(of: appState.config.default_settings.image_uploader) { _, _ in appState.persistConfig() }

                Picker("Text Uploader", selection: $appState.config.default_settings.text_uploader) {
                    ForEach(BuiltinTextUploader.allCases) { u in
                        Text(u.rawValue).tag(u)
                    }
                }
                .onChange(of: appState.config.default_settings.text_uploader) { _, _ in appState.persistConfig() }

                Picker("File Uploader", selection: $appState.config.default_settings.file_uploader) {
                    ForEach(BuiltinFileUploader.allCases) { u in
                        Text(u.rawValue).tag(u)
                    }
                }
                .onChange(of: appState.config.default_settings.file_uploader) { _, _ in appState.persistConfig() }

                Picker("URL Shortener", selection: $appState.config.default_settings.url_shortener) {
                    ForEach(BuiltinUrlShortener.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .onChange(of: appState.config.default_settings.url_shortener) { _, _ in appState.persistConfig() }
            }

            Section("macOS Keychain Credentials Vault (Encrypted via Security.framework)") {
                SecureField("Imgur Client-ID (optional override)", text: $imgurClientId)
                SecureField("Imgur OAuth Bearer Token (optional)", text: $imgurBearer)
                SecureField("vgy.me User Key", text: $vgymeKey)
                SecureField("GitHub Gist Personal Access Token", text: $githubToken)
                SecureField("Pastebin Developer API Key", text: $pastebinKey)
                SecureField("Bitly Access Token", text: $bitlyToken)
                SecureField("Dropbox OAuth Access Token", text: $dropboxToken)
                TextField("Nextcloud / ownCloud WebDAV Base URL", text: $nextcloudUrl)
                TextField("Nextcloud Username", text: $nextcloudUser)
                SecureField("Nextcloud App Password", text: $nextcloudPass)
                SecureField("S3 Presigned / PUT Endpoint URL", text: $s3Presigned)

                Button("Save Secrets to macOS Keychain") {
                    KeychainManager.shared.setSecret(imgurClientId, for: .imgurClientId)
                    KeychainManager.shared.setSecret(imgurBearer, for: .imgurBearerToken)
                    KeychainManager.shared.setSecret(vgymeKey, for: .vgymeUserKey)
                    KeychainManager.shared.setSecret(githubToken, for: .githubGistToken)
                    KeychainManager.shared.setSecret(pastebinKey, for: .pastebinDevKey)
                    KeychainManager.shared.setSecret(bitlyToken, for: .bitlyAccessToken)
                    KeychainManager.shared.setSecret(dropboxToken, for: .dropboxAccessToken)
                    KeychainManager.shared.setSecret(nextcloudUrl, for: .nextcloudWebDavUrl)
                    KeychainManager.shared.setSecret(nextcloudUser, for: .nextcloudUsername)
                    KeychainManager.shared.setSecret(nextcloudPass, for: .nextcloudPassword)
                    KeychainManager.shared.setSecret(s3Presigned, for: .s3PresignedUrl)
                    appState.statusBanner = "Saved credentials securely to macOS Keychain"
                }
                .buttonStyle(.borderedProminent)
            }

            Section("ShareX Custom Uploaders (.sxcu)") {
                HStack {
                    Button("Import .sxcu File…") {
                        importSxcuFile()
                    }
                    Button("Export Editor .sxcu…") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "CustomUploader.sxcu"
                        if panel.runModal() == .OK, let url = panel.url {
                            try? sxcuDraft.write(to: url, atomically: true, encoding: .utf8)
                        }
                    }
                    Button("Save Editor JSON as Custom Uploader") {
                        do {
                            let saved = try appState.core.saveCustomUploader(sxcuJSON: sxcuDraft)
                            appState.customUploaders = (try? appState.core.listCustomUploaders()) ?? []
                            appState.config.default_settings.custom_uploader_name = saved.Name
                            appState.persistConfig()
                            appState.statusBanner = "Saved .sxcu uploader '\(saved.Name)'"
                        } catch {
                            appState.lastError = error.localizedDescription
                        }
                    }
                }

                TextEditor(text: $sxcuDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 150)

                ForEach(appState.customUploaders) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.Name.isEmpty ? item.RequestURL : item.Name)
                                .fontWeight(.semibold)
                            Text("\(item.RequestMethod) • \(item.RequestURL) • \(item.DestinationType)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appState.config.default_settings.custom_uploader_name == item.Name {
                            Text("Active")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        } else {
                            Button("Select") {
                                appState.config.default_settings.custom_uploader_name = item.Name
                                appState.persistConfig()
                            }
                        }
                        Button(role: .destructive) {
                            try? appState.core.deleteCustomUploader(name: item.Name)
                            appState.customUploaders = (try? appState.core.listCustomUploaders()) ?? []
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Upload Destinations & Keychain")
    }

    private func importSxcuFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var importedCount = 0
        for url in panel.urls {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let saved = try? appState.core.saveCustomUploader(sxcuJSON: text) {
                appState.config.default_settings.custom_uploader_name = saved.Name
                sxcuDraft = text
                importedCount += 1
            }
        }
        appState.customUploaders = (try? appState.core.listCustomUploaders()) ?? []
        appState.persistConfig()
        appState.statusBanner = "Imported \(importedCount) .sxcu custom uploader(s)"
    }
}
