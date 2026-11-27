import SwiftUI
import UniformTypeIdentifiers
import KumoCoreKit

struct ExternalChangeNoticeRow: View {
    let onReload: () -> Void

    var body: some View {
        HStack {
            Label(String(localized: "Updated externally."), systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Reload")) {
                onReload()
            }
            .controlSize(.small)
        }
    }
}

struct ControllerSecretField: View {
    let currentSecret: String
    var externalRevision: Int = 0
    let commit: (String) -> Void
    @State private var draft: String = ""
    @State private var hasChanges = false
    @State private var lastSyncedSecret: String?
    @State private var hasExternalUpdate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("Controller Secret", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { _, _ in
                        hasChanges = draft != currentSecret
                        if !hasChanges {
                            hasExternalUpdate = false
                        }
                    }
                    .onSubmit { applyIfNeeded() }
                Button(String(localized: "Apply")) {
                    applyIfNeeded()
                }
                .disabled(!hasChanges)
            }
            if hasExternalUpdate {
                ExternalChangeNoticeRow {
                    draft = currentSecret
                    lastSyncedSecret = currentSecret
                    hasChanges = false
                    hasExternalUpdate = false
                }
            }
        }
        .onAppear {
            draft = currentSecret
            lastSyncedSecret = currentSecret
            hasChanges = false
            hasExternalUpdate = false
        }
        .onChange(of: currentSecret) { _, newValue in
            // Sync only when the user has not typed pending changes,
            // otherwise the in-progress edit would be clobbered by store
            // updates triggered elsewhere.
            if !hasChanges {
                draft = newValue
                lastSyncedSecret = newValue
                hasExternalUpdate = false
            }
        }
        .onChange(of: externalRevision) { _, _ in
            if hasChanges, currentSecret != lastSyncedSecret {
                lastSyncedSecret = currentSecret
                hasExternalUpdate = true
            } else if !hasChanges {
                draft = currentSecret
                lastSyncedSecret = currentSecret
                hasExternalUpdate = false
            }
        }
    }

    private func applyIfNeeded() {
        guard hasChanges else { return }
        commit(draft)
        lastSyncedSecret = draft
        hasChanges = false
        hasExternalUpdate = false
    }
}

struct ProviderRow<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

