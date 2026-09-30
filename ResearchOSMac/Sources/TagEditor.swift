import SwiftUI

struct TagEditor: View {
    let tags: [String]
    let onSave: ([String]) -> Void
    @State private var text: String

    init(tags: [String], onSave: @escaping ([String]) -> Void) {
        self.tags = tags; self.onSave = onSave
        _text = State(initialValue: tags.joined(separator: ", "))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag").foregroundStyle(.secondary)
            TextField("添加标签，用逗号分隔", text: $text).textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            Button("保存") { save() }.controlSize(.small)
        }
    }
    private func save() { onSave(text.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
}
