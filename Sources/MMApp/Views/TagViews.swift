import SwiftUI

/// 一个标签的小胶囊，列表、表单、批量编辑共用同一种外观。
struct TagChip: View {
    let title: String
    var systemImage: String?
    var detail: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(title).lineLimit(1)
            if let detail { Text(verbatim: detail).foregroundStyle(.secondary).monospacedDigit() }
        }
        .font(.callout)
        .foregroundStyle(tint ?? .primary)
        .padding(.horizontal, 7).padding(.vertical, 1.5)
        .background(tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.quaternary), in: Capsule())
        .fixedSize()
    }
}

/// 表格单元格里的一行标签：放不下时只显示前几个，后面用 "+N" 表示。
struct TagChipsLine: View {
    let tags: [String]

    var body: some View {
        if tags.isEmpty {
            Text(verbatim: "—").foregroundStyle(.tertiary)
        } else {
            // ViewThatFits 依次尝试，选第一个放得下的：全部 → 少一个加 +1 → …… → 只剩 +N
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: tags.count, through: 0, by: -1)), id: \.self) { k in
                    HStack(spacing: 4) {
                        ForEach(tags.prefix(k), id: \.self) { TagChip(title: $0) }
                        if k < tags.count {
                            Text(verbatim: "+\(tags.count - k)").font(.callout).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                }
            }
            .help(tags.joined(separator: L("common.listSeparator")))
        }
    }
}

/// 标签输入框，下面列出还没加上的常用标签，点一下就加上，不用记名字也不用打字。
struct TagEditor: View {
    @Binding var tags: [String]
    var suggestions: [String]
    var placeholder = L("tagField.placeholder")
    /// 最多列出几个候选，其余的输入时靠自动补全
    var maxSuggestions = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TagTokenField(tags: $tags, suggestions: suggestions, placeholder: placeholder)
            let rest = Array(suggestions.filter { !tags.contains($0) }.prefix(maxSuggestions))
            if !rest.isEmpty {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(rest, id: \.self) { t in
                        Button { tags.append(t) } label: { TagChip(title: t, systemImage: "plus") }
                            .buttonStyle(.plain)
                            .help(L("tagEditor.add.help \(t)"))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 从左到右排，一行放不下就换行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(maxWidth: bounds.width, subviews).frames
        for (view, f) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }

    private func arrange(maxWidth: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
            width = max(width, x - spacing)
        }
        return (frames, CGSize(width: width, height: frames.isEmpty ? 0 : y + lineHeight))
    }
}
