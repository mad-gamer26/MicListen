import SwiftUI

struct AddEndpointView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var urlText = ""
    @State private var password = ""
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case url
        case password
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("URL", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .url)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                }
            }
            .navigationTitle("Add Endpoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .onSubmit(save)
            .onAppear {
                focusedField = .url
            }
        }
    }

    private func save() {
        guard !isSaving else {
            return
        }
        isSaving = true
        Task {
            let added = await model.addEndpoint(name: name, urlText: urlText, password: password)
            isSaving = false
            if added {
                dismiss()
            }
        }
    }
}

struct EditEndpointView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let endpoint: SavedEndpoint

    @State private var name: String
    @State private var urlText: String
    @State private var password = ""
    @State private var isSaving = false

    init(endpoint: SavedEndpoint) {
        self.endpoint = endpoint
        _name = State(initialValue: endpoint.name)
        _urlText = State(initialValue: endpoint.baseURLString)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("URL", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("New Password", text: $password)
                        .textContentType(.password)
                }

                Section {
                    Button(role: .destructive) {
                        update(passwordOverride: "")
                    } label: {
                        Label("Remove Saved Password", systemImage: "key.slash")
                    }
                }
            }
            .navigationTitle("Edit Endpoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        update(passwordOverride: password.isEmpty ? nil : password)
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }

    private func update(passwordOverride: String?) {
        guard !isSaving else {
            return
        }
        isSaving = true
        Task {
            let saved = await model.updateEndpoint(
                endpoint,
                name: name,
                urlText: urlText,
                password: passwordOverride
            )
            isSaving = false
            if saved {
                dismiss()
            }
        }
    }
}
