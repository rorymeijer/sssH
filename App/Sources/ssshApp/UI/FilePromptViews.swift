import SwiftUI
import ssshCore

/// Renaming, with the extension left out of the initial selection where there
/// is one — because renaming almost never means renaming the extension.
struct RenamePromptView: View {
    let currentName: String
    let rename: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var isFocused: Bool

    init(currentName: String, rename: @escaping (String) -> Void) {
        self.currentName = currentName
        self.rename = rename
        _name = State(initialValue: currentName)
    }

    private var isValid: Bool {
        RemotePath.isValidComponent(name) && name != currentName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Naam wijzigen", comment: "Title of the rename prompt")
                .font(.headline)

            TextField(text: $name) {
                Text("Naam", comment: "Placeholder for a new folder's name")
            }
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            #if os(iOS)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { if isValid { finish() } }

            if !name.isEmpty, !RemotePath.isValidComponent(name) {
                Text("Een naam mag geen schuine streep bevatten en kan niet . of .. zijn.",
                     comment: "Explains why a proposed filename is not allowed")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: {
                    Text("Annuleer", comment: "Cancel button")
                }
                Button(action: finish) {
                    Text("Wijzigen", comment: "Button that confirms a rename")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        .onAppear { isFocused = true }
    }

    private func finish() {
        rename(name)
        dismiss()
    }
}

/// POSIX permissions, as nine checkboxes and an octal field that stay in step.
///
/// Both, because people think in both: `chmod 755` is muscle memory, and
/// "should the group be able to write" is the question someone who has not
/// memorised the bits is actually asking.
struct PermissionsEditorView: View {
    let entry: RemoteFileEntry
    let apply: (POSIXPermissions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var bits: UInt16
    @State private var octal: String

    init(entry: RemoteFileEntry, apply: @escaping (POSIXPermissions) -> Void) {
        self.entry = entry
        self.apply = apply
        let current = entry.attributes.permissions?.rawValue ?? 0o644
        _bits = State(initialValue: current)
        _octal = State(initialValue: String(current, radix: 8))
    }

    /// Owner, group, other — the three triplets of a POSIX mode, most
    /// significant first.
    private static let classShifts: [UInt16] = [6, 3, 0]

    private func classLabel(shift: UInt16) -> Text {
        switch shift {
        case 6: return Text("Eigenaar", comment: "Permission class: the file's owner")
        case 3: return Text("Groep", comment: "Permission class: the file's group")
        default: return Text("Anderen", comment: "Permission class: everyone else")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rechten voor \(entry.name)", comment: "Title of the permissions editor, naming the file")
                .font(.headline)

            Grid(alignment: .leading) {
                GridRow {
                    Text(verbatim: "")
                    Text("Lezen", comment: "Permission bit: read").font(.caption)
                    Text("Schrijven", comment: "Permission bit: write").font(.caption)
                    Text("Uitvoeren", comment: "Permission bit: execute").font(.caption)
                }
                ForEach(Self.classShifts, id: \.self) { shift in
                    GridRow {
                        classLabel(shift: shift).font(.callout)
                        toggle(shift: shift, bit: 0o4)
                        toggle(shift: shift, bit: 0o2)
                        toggle(shift: shift, bit: 0o1)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Octaal", comment: "Label for the octal permissions field")
                TextField(text: $octal) {
                    Text("Octaal", comment: "Label for the octal permissions field")
                }
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .font(.body.monospaced())
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onChange(of: octal) { _, value in
                    // Only a valid octal value moves the checkboxes. Anything
                    // else is left alone so that half-typed input does not
                    // reset the whole sheet.
                    guard let parsed = UInt16(value, radix: 8), parsed <= 0o7777 else { return }
                    bits = parsed
                }

                Text(verbatim: POSIXPermissions(rawValue: bits).description)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: {
                    Text("Annuleer", comment: "Cancel button")
                }
                Button {
                    apply(POSIXPermissions(rawValue: bits))
                    dismiss()
                } label: {
                    Text("Toepassen", comment: "Button that applies new permissions")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    private func toggle(shift: UInt16, bit: UInt16) -> some View {
        let mask = bit << shift
        return Toggle(isOn: Binding(
            get: { bits & mask != 0 },
            set: { isOn in
                if isOn { bits |= mask } else { bits &= ~mask }
                octal = String(bits, radix: 8)
            }
        )) {
            Text(verbatim: "")
        }
        .labelsHidden()
    }
}
