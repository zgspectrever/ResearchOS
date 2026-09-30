import SwiftUI

struct KnowledgeGraphNodeList: View {
    let graph: KnowledgeGraph
    @Binding var selection: UUID?
    @State private var query = ""

    private var filteredNodes: [KnowledgeNode] {
        let nodes = graph.nodes.sorted {
            if $0.kind == $1.kind { return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        guard !query.isEmpty else { return nodes }
        return nodes.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
                || $0.provenance.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if graph.nodes.isEmpty {
                EmptyStateCard(title: "知识图谱尚未建立", message: "先导入论文或创建研究问题，ResearchOS 会在这里组织来源与证据关系。", symbol: "point.3.connected.trianglepath.dotted") { EmptyView() }
            } else {
                List(filteredNodes, selection: $selection) { node in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: node.kind.symbol)
                            .foregroundStyle(node.kind.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(node.label)
                                .font(.headline)
                                .lineLimit(3)
                            HStack(spacing: 6) {
                                Text(node.kind.title)
                                Text("·")
                                Text(node.reviewStatus.title)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                    .tag(node.id)
                }
            }
        }
        .navigationTitle("知识图谱")
        .searchable(text: $query, prompt: "搜索实体或来源")
    }
}

struct KnowledgeGraphDetailView: View {
    let graph: KnowledgeGraph
    @Binding var selection: UUID?
    let onRebuild: () -> Void
    @State private var showsInspector = true

    private var selectedNode: KnowledgeNode? {
        graph.nodes.first { $0.id == selection }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            InteractiveKnowledgeGraph(
                graph: graph,
                selection: $selection,
                onRebuild: onRebuild,
                onToggleInspector: { showsInspector.toggle() }
            )
            .padding(.trailing, showsInspector ? 332 : 0)

            if showsInspector {
                GraphInspector(
                    graph: graph,
                    node: selectedNode,
                    selection: $selection,
                    onClose: { showsInspector = false }
                )
                .frame(width: 320)
                .padding(12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showsInspector)
        .onChange(of: selection) { _, newValue in
            if newValue != nil { showsInspector = true }
        }
        .navigationTitle("知识图谱")
    }
}

private struct InteractiveKnowledgeGraph: View {
    let graph: KnowledgeGraph
    @Binding var selection: UUID?
    let onRebuild: () -> Void
    let onToggleInspector: () -> Void
    @State private var positions: [UUID: CGPoint] = [:]
    @State private var visibleKinds = Set(KnowledgeNodeKind.allCases)
    @State private var scale: CGFloat = 1
    @State private var scaleOrigin: CGFloat?
    @State private var canvasOffset: CGSize = .zero
    @State private var panOrigin: CGSize?
    @State private var nodeDragOrigins: [UUID: CGPoint] = [:]
    @State private var canvasSize: CGSize = .zero

    private var visibleNodes: [KnowledgeNode] {
        graph.nodes.filter { visibleKinds.contains($0.kind) }
    }

    private var visibleNodeIDs: Set<UUID> {
        Set(visibleNodes.map(\.id))
    }

    private var visibleEdges: [KnowledgeEdge] {
        graph.edges.filter {
            visibleNodeIDs.contains($0.sourceNodeID) && visibleNodeIDs.contains($0.targetNodeID)
        }
    }

    private var connectedNodeIDs: Set<UUID> {
        guard let selection else { return [] }
        return Set(visibleEdges.flatMap { edge -> [UUID] in
            guard edge.sourceNodeID == selection || edge.targetNodeID == selection else { return [] }
            return [edge.sourceNodeID, edge.targetNodeID]
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            graphToolbar
            Divider()

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(ResearchPalette.window)
                        .contentShape(Rectangle())
                        .gesture(panGesture)

                    graphLayer(size: proxy.size)
                        .scaleEffect(scale, anchor: .topLeading)
                        .offset(canvasOffset)

                    if graph.nodes.isEmpty {
                        ContentUnavailableView(
                            "知识图谱尚未建立",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("先导入论文或从 PDF 保存一条证据。")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .clipped()
                .simultaneousGesture(zoomGesture)
                .onAppear { updateCanvasSize(proxy.size, resetLayout: positions.isEmpty) }
                .onChange(of: proxy.size) { _, size in updateCanvasSize(size, resetLayout: false) }
                .onChange(of: graph.nodes.map(\.id)) { _, _ in updateCanvasSize(proxy.size, resetLayout: true) }
            }
        }
    }

    private var graphToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("证据流")
                    .font(.headline)
                Text("论文 → 证据 → 研究问题")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 28)
            Text("\(visibleNodes.count) 个节点 · \(visibleEdges.count) 条关系")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()

            Menu {
                ForEach(KnowledgeNodeKind.allCases, id: \.self) { kind in
                    Toggle(isOn: kindBinding(kind)) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
                Divider()
                Button("显示全部") { visibleKinds = Set(KnowledgeNodeKind.allCases) }
            } label: {
                Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            ControlGroup {
                Button { changeZoom(by: -0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("缩小")
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 40)
                Button { changeZoom(by: 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("放大")
                Button { resetView() } label: { Image(systemName: "scope") }
                    .help("适合窗口并恢复布局")
            }
            .controlSize(.small)

            Button("更新", systemImage: "arrow.triangle.2.circlepath", action: onRebuild)
                .controlSize(.small)
            Button(action: onToggleInspector) {
                Image(systemName: "sidebar.trailing")
            }
            .help("显示或隐藏节点详情")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.bar)
    }

    private func graphLayer(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, canvasSize in
                drawGrid(in: &context, size: canvasSize)
                drawLaneTitles(in: &context, size: canvasSize)
                drawEdges(in: &context)
            }
            .frame(width: size.width, height: size.height)

            ForEach(visibleNodes) { node in
                GraphNodeCard(
                    node: node,
                    isSelected: selection == node.id,
                    isDimmed: selection != nil
                        && !connectedNodeIDs.isEmpty
                        && selection != node.id
                        && !connectedNodeIDs.contains(node.id)
                )
                .position(positions[node.id] ?? CGPoint(x: size.width / 2, y: size.height / 2))
                .onTapGesture { selection = node.id }
                .gesture(nodeDragGesture(for: node.id))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var dots = Path()
        for x in stride(from: 18.0, through: size.width, by: 28) {
            for y in stride(from: 22.0, through: size.height, by: 28) {
                dots.addEllipse(in: CGRect(x: x, y: y, width: 1.4, height: 1.4))
            }
        }
        context.fill(dots, with: .color(Color.secondary.opacity(0.13)))
    }

    private func drawLaneTitles(in context: inout GraphicsContext, size: CGSize) {
        guard !graph.edges.isEmpty else { return }
        let labels: [(String, CGFloat)] = [("论文来源", 0.16), ("证据与研究单元", 0.53), ("研究问题", 0.86)]
        for (label, ratio) in labels {
            context.draw(
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary),
                at: CGPoint(x: size.width * ratio, y: 24),
                anchor: .center
            )
        }
    }

    private func drawEdges(in context: inout GraphicsContext) {
        for edge in visibleEdges {
            guard let source = positions[edge.sourceNodeID], let target = positions[edge.targetNodeID] else { continue }
            let selectedEdge = selection == nil || edge.sourceNodeID == selection || edge.targetNodeID == selection
            let direction: CGFloat = target.x >= source.x ? 1 : -1
            let start = CGPoint(x: source.x + direction * 96, y: source.y)
            let end = CGPoint(x: target.x - direction * 96, y: target.y)
            let bend = max(46, abs(end.x - start.x) * 0.48)
            var path = Path()
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + direction * bend, y: start.y),
                control2: CGPoint(x: end.x - direction * bend, y: end.y)
            )
            context.stroke(
                path,
                with: .color(edge.kind.graphColor.opacity(selectedEdge ? 0.74 : 0.10)),
                style: StrokeStyle(
                    lineWidth: selectedEdge && selection != nil ? 2.2 : 1.15,
                    lineCap: .round,
                    dash: edge.reviewStatus == .aiSuggested ? [6, 5] : []
                )
            )

            var endDot = Path()
            endDot.addEllipse(in: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6))
            context.fill(endDot, with: .color(edge.kind.graphColor.opacity(selectedEdge ? 0.85 : 0.12)))

            if selection != nil && selectedEdge {
                let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 10)
                context.draw(
                    Text(edge.kind.title).font(.caption2.weight(.medium)).foregroundStyle(edge.kind.graphColor),
                    at: midpoint,
                    anchor: .center
                )
            }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panOrigin == nil { panOrigin = canvasOffset }
                guard let panOrigin else { return }
                canvasOffset = CGSize(
                    width: panOrigin.width + value.translation.width,
                    height: panOrigin.height + value.translation.height
                )
            }
            .onEnded { _ in panOrigin = nil }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if scaleOrigin == nil { scaleOrigin = scale }
                scale = min(2.2, max(0.45, (scaleOrigin ?? scale) * value))
            }
            .onEnded { _ in scaleOrigin = nil }
    }

    private func nodeDragGesture(for id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if nodeDragOrigins[id] == nil { nodeDragOrigins[id] = positions[id] }
                guard let origin = nodeDragOrigins[id] else { return }
                positions[id] = CGPoint(
                    x: origin.x + value.translation.width / scale,
                    y: origin.y + value.translation.height / scale
                )
            }
            .onEnded { _ in
                nodeDragOrigins[id] = nil
                selection = id
            }
    }

    private func kindBinding(_ kind: KnowledgeNodeKind) -> Binding<Bool> {
        Binding(
            get: { visibleKinds.contains(kind) },
            set: { isVisible in
                if isVisible { visibleKinds.insert(kind) } else { visibleKinds.remove(kind) }
            }
        )
    }

    private func updateCanvasSize(_ size: CGSize, resetLayout: Bool) {
        guard size.width > 10, size.height > 10 else { return }
        canvasSize = size
        if resetLayout || Set(positions.keys) != Set(graph.nodes.map(\.id)) {
            positions = EvidenceFlowLayout.positions(for: graph, in: size)
        }
    }

    private func changeZoom(by amount: CGFloat) {
        scale = min(2.2, max(0.45, scale + amount))
    }

    private func resetView() {
        positions = EvidenceFlowLayout.positions(for: graph, in: canvasSize)
        scale = graph.nodes.count > 18 ? 0.82 : 1
        canvasOffset = .zero
    }
}

private struct GraphNodeCard: View {
    let node: KnowledgeNode
    let isSelected: Bool
    let isDimmed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(node.kind.color)
                .frame(width: 30, height: 30)
                .background(node.kind.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(node.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(node.kind.title)
                    Circle()
                        .fill(node.reviewStatus.color)
                        .frame(width: 5, height: 5)
                    Text(node.reviewStatus.title)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(width: 192, height: 66)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? node.kind.color : ResearchPalette.separator.opacity(0.65), lineWidth: isSelected ? 2 : 0.6)
        }
        .shadow(color: isSelected ? node.kind.color.opacity(0.20) : .black.opacity(0.06), radius: isSelected ? 10 : 4, y: 2)
        .opacity(isDimmed ? 0.28 : 1)
        .animation(.easeOut(duration: 0.14), value: isDimmed)
        .help(node.label)
    }
}

private struct GraphInspector: View {
    let graph: KnowledgeGraph
    let node: KnowledgeNode?
    @Binding var selection: UUID?
    let onClose: () -> Void

    private var relationships: [(KnowledgeEdge, KnowledgeNode, Bool)] {
        guard let node else { return [] }
        return graph.edges.compactMap { edge in
            if edge.sourceNodeID == node.id,
               let other = graph.nodes.first(where: { $0.id == edge.targetNodeID }) {
                return (edge, other, true)
            }
            if edge.targetNodeID == node.id,
               let other = graph.nodes.first(where: { $0.id == edge.sourceNodeID }) {
                return (edge, other, false)
            }
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(node == nil ? "图谱概览" : "节点详情")
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()

            if let node {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: node.kind.symbol)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(node.kind.color)
                                .frame(width: 38, height: 38)
                                .background(node.kind.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(node.kind.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(node.kind.color)
                                Text(node.label)
                                    .font(.headline)
                                    .textSelection(.enabled)
                            }
                        }

                        if node.detail != node.label {
                            Text(node.detail)
                                .font(.callout)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Label("来源", systemImage: "link")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(node.provenance)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))

                        HStack {
                            Text("关系").font(.headline)
                            Spacer()
                            Text("\(relationships.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if relationships.isEmpty {
                            Text("暂时没有关系。保存 PDF 证据后，来源链会自动出现在这里。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(relationships, id: \.0.id) { edge, other, outgoing in
                                Button {
                                    selection = other.id
                                } label: {
                                    HStack(alignment: .top, spacing: 9) {
                                        Image(systemName: outgoing ? "arrow.right" : "arrow.left")
                                            .foregroundStyle(edge.kind.graphColor)
                                            .frame(width: 15)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(edge.kind.title)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(edge.kind.graphColor)
                                            Text(other.label)
                                                .font(.callout.weight(.medium))
                                                .lineLimit(3)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(10)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                            }
                        }
                    }
                    .padding(14)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("选择一个节点")
                        .font(.headline)
                    Text("单击节点查看来源与关系；拖动节点整理布局，拖动空白处平移图谱，触控板捏合即可缩放。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        InspectorMetric(value: graph.nodes.count, label: "节点")
                        InspectorMetric(value: graph.edges.count, label: "关系")
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ResearchPalette.separator.opacity(0.7), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 7)
    }
}

private struct InspectorMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value.formatted())
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 80, height: 54)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }
}

private enum EvidenceFlowLayout {
    static func positions(for graph: KnowledgeGraph, in size: CGSize) -> [UUID: CGPoint] {
        guard !graph.nodes.isEmpty else { return [:] }
        if graph.edges.isEmpty {
            return gridPositions(for: graph.nodes, in: size)
        }

        let papers = graph.nodes.filter { $0.kind == .paper }
        let questions = graph.nodes.filter { $0.kind == .researchQuestion }
        let evidence = graph.nodes.filter { $0.kind != .paper && $0.kind != .researchQuestion }
        var result: [UUID: CGPoint] = [:]
        placeLane(papers, xRange: 112...max(112, size.width * 0.31), size: size, into: &result)
        placeLane(evidence, xRange: size.width * 0.45...size.width * 0.67, size: size, into: &result)
        placeLane(questions, xRange: min(size.width - 112, size.width * 0.84)...max(112, size.width - 112), size: size, into: &result)
        return result
    }

    private static func placeLane(
        _ nodes: [KnowledgeNode],
        xRange: ClosedRange<CGFloat>,
        size: CGSize,
        into result: inout [UUID: CGPoint]
    ) {
        guard !nodes.isEmpty else { return }
        let sorted = nodes.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        let availableHeight = max(180, size.height - 116)
        let maxRows = max(1, Int(availableHeight / 84))
        let columns = max(1, Int(ceil(Double(sorted.count) / Double(maxRows))))
        let rows = min(maxRows, sorted.count)
        for (index, node) in sorted.enumerated() {
            let column = index / maxRows
            let row = index % maxRows
            let x: CGFloat = columns == 1
                ? (xRange.lowerBound + xRange.upperBound) / 2
                : xRange.lowerBound + CGFloat(column) * (xRange.upperBound - xRange.lowerBound) / CGFloat(columns - 1)
            let y = 78 + CGFloat(row) * max(82, availableHeight / CGFloat(max(1, rows)))
            result[node.id] = CGPoint(x: x, y: y)
        }
    }

    private static func gridPositions(for nodes: [KnowledgeNode], in size: CGSize) -> [UUID: CGPoint] {
        let sorted = nodes.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        let columns = max(1, min(4, Int(max(1, size.width - 60) / 215)))
        let rows = Int(ceil(Double(sorted.count) / Double(columns)))
        let horizontal = size.width / CGFloat(columns + 1)
        let vertical = max(86, (size.height - 70) / CGFloat(max(rows, 1)))
        return Dictionary(uniqueKeysWithValues: sorted.enumerated().map { index, node in
            let column = index % columns
            let row = index / columns
            return (node.id, CGPoint(x: horizontal * CGFloat(column + 1), y: 64 + vertical * CGFloat(row) + vertical / 2))
        })
    }
}

private extension KnowledgeEdgeKind {
    var graphColor: Color {
        switch self {
        case .candidateFor: .secondary
        case .contains: .indigo
        case .reports: .orange
        case .usesMethod: .purple
        case .limitedBy: .red
        case .supports: .green
        case .contradicts: .orange
        case .leavesGap: .blue
        }
    }
}
