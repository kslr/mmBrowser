import AppKit
import SwiftUI

/// 标签输入：系统的 NSTokenField（输入逗号或回车后变成一个独立标签，可整体删除），按已有标签自动补全。
/// 外观完全交给系统，在不同 macOS 版本上自动跟随系统样式。
struct TagTokenField: NSViewRepresentable {
    @Binding var tags: [String]
    var suggestions: [String] = []
    var placeholder = L("tagField.placeholder")

    func makeNSView(context: Context) -> NSTokenField {
        let f = NSTokenField()
        f.delegate = context.coordinator
        f.tokenizingCharacterSet = CharacterSet(charactersIn: ",，")
        f.placeholderString = placeholder
        f.completionDelay = 0.1
        f.objectValue = tags
        context.coordinator.pushed = tags
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: NSTokenField, context: Context) {
        context.coordinator.parent = self
        // 只在标签被外部改掉时（比如点了下面的候选标签）才回写；自己刚同步出去的不回写，免得打断正在输入的文字
        if tags != context.coordinator.pushed {
            context.coordinator.pushed = tags
            f.objectValue = tags
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TagTokenField
        /// 最近一次和外部对齐过的标签
        var pushed: [String] = []
        init(_ parent: TagTokenField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) { sync(obj) }
        func controlTextDidEndEditing(_ obj: Notification) { sync(obj) }

        private func sync(_ obj: Notification) {
            guard let f = obj.object as? NSTokenField else { return }
            let raw = (f.objectValue as? [String]) ?? []
            var seen = Set<String>()
            let cleaned = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            pushed = cleaned
            if cleaned != parent.tags { parent.tags = cleaned }
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let existing = Set((tokenField.objectValue as? [String]) ?? [])
            let s = substring.lowercased()
            return parent.suggestions.filter { !existing.contains($0) && (s.isEmpty || $0.lowercased().hasPrefix(s)) }
        }
    }
}
