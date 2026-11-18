import LukaCore
import SwiftUI

/// A tag as a small capsule.
struct TagChip: View {
    let tag: String
    var highlighted = false

    var body: some View {
        Text(verbatim: "#" + tag)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(highlighted ? AnyShapeStyle(LukaTheme.accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(highlighted ? LukaTheme.accent.opacity(0.18) : Color.primary.opacity(0.07), in: .capsule)
    }
}

/// Lays its children out left to right, wrapping onto new lines as needed.
struct TagFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

/// Above the session list: All, then every tag. Choosing one lists only sessions with it.
struct TagFilterBar: View {
    let tags: [String]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(tr("All"), on: selected == nil) { selected = nil }
                ForEach(tags, id: \.self) { tag in
                    let on = selected.map { Tags.same($0, tag) } ?? false
                    chip("#" + tag, on: on) { selected = on ? nil : tag }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.caption.weight(on ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(on ? AnyShapeStyle(LukaTheme.accent) : AnyShapeStyle(Color.primary.opacity(0.07)), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Adds and removes tags on one or several sessions. A tag on only some of them shows a dash;
/// clicking it puts it on all of them.
struct TagEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: Set<UUID>
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// Whether all, some or none of the sessions have a tag.
    private enum Presence { case all, some, none }

    private func state(of tag: String) -> Presence {
        let count = ids.filter { id in model.tags(of: id).contains { Tags.same($0, tag) } }.count
        return count == 0 ? .none : count == ids.count ? .all : .some
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ids.count > 1 ? String(format: tr("Tags for %d sessions"), ids.count) : tr("Tags"))
                .font(.headline)
            HStack {
                TextField(tr("New tag"), text: $draft, prompt: Text(tr("e.g. interview, Airwallex")))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(add)
                Button(tr("Add"), action: add)
                    .disabled(Tags.normalize(draft) == nil)
            }
            let tags = model.allTags
            if tags.isEmpty {
                Text(tr("No tags yet. Type one above and press Return."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    TagFlow(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            toggle(tag)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            HStack {
                Spacer()
                Button(tr("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .tint(LukaTheme.accent)
        .onAppear { focused = true }
    }

    private func toggle(_ tag: String) -> some View {
        let state = state(of: tag)
        return Button {
            model.setTag(tag, on: state != .all, for: ids)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state == .all ? "checkmark" : state == .some ? "minus" : "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(verbatim: "#" + tag)
            }
            .font(.callout)
            .foregroundStyle(state == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(LukaTheme.accent))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(state == .none ? Color.primary.opacity(0.07) : LukaTheme.accent.opacity(0.15), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(state == .all ? tr("Remove this tag") : tr("Add this tag"))
    }

    private func add() {
        guard let tag = Tags.normalize(draft) else { return }
        model.setTag(tag, on: true, for: ids)
        draft = ""
    }
}

/// What the transcript window shows while several sessions are selected.
struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    let ids: Set<UUID>
    @State private var tagging: TagTarget?
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(String(format: tr("%d sessions selected"), ids.count))
                .font(.title2.weight(.semibold))
            let shared = model.allTags.filter { tag in ids.allSatisfy { id in model.tags(of: id).contains { Tags.same($0, tag) } } }
            if !shared.isEmpty {
                HStack(spacing: 4) {
                    ForEach(shared, id: \.self) { TagChip(tag: $0) }
                }
            }
            HStack(spacing: 10) {
                Button { tagging = TagTarget(ids: ids) } label: { Label(tr("Tags…"), systemImage: "tag") }
                Button { model.copy(ids) } label: { Label(tr("Copy"), systemImage: "doc.on.doc") }
                Button(role: .destructive) { confirmingDelete = true } label: { Label(tr("Delete…"), systemImage: "trash") }
            }
            .controlSize(.large)
            Text(tr("⌘-click or ⇧-click in the list to change the selection."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $tagging) { target in
            TagEditor(ids: target.ids).environment(model)
        }
        .confirmationDialog(String(format: tr("Delete %d sessions?"), ids.count), isPresented: $confirmingDelete) {
            Button(tr("Delete"), role: .destructive) {
                let ids = ids
                withAnimation(.smooth) { model.deleteSessions(ids) }
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(tr("The transcripts will be removed from this Mac."))
        }
    }
}
