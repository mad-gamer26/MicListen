import SwiftUI

struct PasswordPromptView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: PasswordRequest

    @State private var password = ""
    @State private var isSaving = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($passwordFocused)
                } header: {
                    Text(request.message)
                }
            }
            .navigationTitle(request.title)
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
                            Text("Save")
                        }
                    }
                    .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .onSubmit(save)
            .onAppear {
                passwordFocused = true
            }
        }
    }

    private func save() {
        guard !isSaving else {
            return
        }
        isSaving = true
        Task {
            await model.savePassword(password, for: request)
            isSaving = false
            dismiss()
        }
    }
}
