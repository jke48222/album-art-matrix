// Doodle — finger on glass, pixels on the wall. Strokes interpolate so
// fast lines don't gap, mirror mode for instant symmetry, undo and redo,
// and the colors you actually use stay within reach.
import SwiftUI
import UIKit

struct DoodleView: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var wall: WallAPI
    @EnvironmentObject var creations: CreationStore

    @State private var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
    @State private var undoStack: [[UInt8]] = []
    @State private var redoStack: [[UInt8]] = []
    @State private var strokeOpen = false
    @State private var lastCell: (Int, Int)? = nil
    @State private var tool = "draw"          // draw | fill | erase
    @State private var brush = 2              // 1 | 2 | 4
    @State private var mirror = false
    @State private var color = Color(hex: "#f4f1ea")
    @State private var recent: [String] = []
    @State private var sent = false

    private let presets = ["#f4f1ea", "#e8631a", "#5e1a1e",
                           "#d9a028", "#4c6b4f", "#33445c"]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(t.ink)
                    }
                    .buttonStyle(Pressable())
                    .padding(.trailing, 8)
                    Text("Doodle")
                        .font(.displayWide(28)).foregroundStyle(t.ink)
                    Spacer()
                    Button { undo() } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(undoStack.isEmpty ? t.ink35 : t.ink)
                    }
                    .buttonStyle(Pressable())
                    .disabled(undoStack.isEmpty)
                    Button { redo() } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(redoStack.isEmpty ? t.ink35 : t.ink)
                    }
                    .buttonStyle(Pressable())
                    .disabled(redoStack.isEmpty)
                    .padding(.leading, 10)
                    Button { snapshot(); px = .init(repeating: 0, count: px.count) } label: {
                        Text("CLEAR").font(.mono(11, .medium)).kerning(1)
                            .foregroundStyle(t.ink70)
                    }
                    .buttonStyle(Pressable())
                    .padding(.leading, 12)
                }
                .padding(.top, 8)

                canvas

                HStack(spacing: 10) {
                    StripControl(options: [
                        (id: "draw", label: "DRAW"), (id: "fill", label: "FILL"),
                        (id: "erase", label: "ERASE"),
                    ], selection: $tool, height: 38, fontSize: 11, kern: 1)
                    StripControl(options: [
                        (id: 1, label: "1"), (id: 2, label: "2"), (id: 4, label: "4"),
                    ], selection: $brush, height: 38, fontSize: 11, kern: 1)
                    .frame(width: 108)
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        mirror.toggle()
                    } label: {
                        Text("MIRROR")
                            .font(.display(11, .bold)).kerning(1)
                            .foregroundStyle(mirror ? t.ground : t.ink70)
                            .frame(width: 74, height: 38)
                            .background(mirror ? t.ink : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(t.ink, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(Pressable())
                }

                HStack(spacing: 11) {
                    ForEach(allSwatches, id: \.self) { hex in
                        swatch(hex)
                    }
                    Spacer(minLength: 0)
                    ColorPicker("", selection: $color, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 32)
                }

                if !recent.isEmpty {
                    HStack(spacing: 11) {
                        MonoTag("RECENT")
                        ForEach(recent, id: \.self) { hex in
                            swatch(hex, small: true)
                        }
                        Spacer(minLength: 0)
                    }
                }

                PrimaryButton(label: sent ? "On the wall" : "Send to the wall",
                              enabled: wall.reachable && !sent) {
                    let data = Data(px)
                    wall.sendFrame(data, preview: UIImage.fromRGB64(data))
                    creations.add(data)
                    withAnimation { sent = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        dismiss()
                    }
                }
                if !wall.reachable {
                    HStack { Spacer(); MonoTag("NO LINK, DRAWING STAYS HERE"); Spacer() }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
        }
        .background(t.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    // ---- canvas ---------------------------------------------------------
    private var canvas: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                Theme.panel
                if let ui = UIImage.fromRGB64(Data(px)) {
                    Image(uiImage: ui)
                        .resizable()
                        .interpolation(.none)
                }
                PixelGrid(cells: 64)
                if mirror {
                    Rectangle().fill(t.ground.opacity(0.35))
                        .frame(width: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !strokeOpen {
                            snapshot()
                            strokeOpen = true
                            lastCell = nil
                        }
                        paint(at: g.location, canvasSide: side)
                    }
                    .onEnded { _ in
                        strokeOpen = false
                        lastCell = nil
                        rememberColor()
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(6)
        .overlay(Rectangle().stroke(t.hairline, lineWidth: 1))
    }

    private var allSwatches: [String] { presets + (wall.state.art_colors ?? []).prefix(2) }

    private func swatch(_ hex: String, small: Bool = false) -> some View {
        let c = Color(hex: hex)
        let size: CGFloat = small ? 20 : 27
        return Circle()
            .fill(c)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(
                color.hexString == hex ? t.ink : t.hairline,
                lineWidth: color.hexString == hex ? 2 : 1))
            .onTapGesture {
                UISelectionFeedbackGenerator().selectionChanged()
                color = c
                if tool == "erase" { tool = "draw" }
            }
    }

    // ---- pixel ops ------------------------------------------------------
    private func snapshot() {
        undoStack.append(px)
        redoStack.removeAll()
        if undoStack.count > 30 { undoStack.removeFirst() }
        sent = false
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(px)
        px = last
        sent = false
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(px)
        px = next
        sent = false
    }

    private func rememberColor() {
        guard tool != "erase" else { return }
        let hex = color.hexString
        guard !presets.contains(hex) else { return }
        recent.removeAll { $0 == hex }
        recent.insert(hex, at: 0)
        if recent.count > 5 { recent.removeLast() }
    }

    private func rgb() -> (UInt8, UInt8, UInt8) {
        if tool == "erase" { return (0, 0, 0) }
        return color.rgb888
    }

    private func paint(at p: CGPoint, canvasSide: CGFloat) {
        let cx = Int(p.x / canvasSide * 64), cy = Int(p.y / canvasSide * 64)
        guard (0..<64).contains(cx), (0..<64).contains(cy) else { return }
        let (r, g, b) = rgb()
        if tool == "fill" {
            floodFill(x: cx, y: cy, r: r, g: g, b: b)
            lastCell = (cx, cy)
            return
        }
        // interpolate from the previous sample so fast strokes stay solid
        if let (lx, ly) = lastCell {
            let steps = max(abs(cx - lx), abs(cy - ly))
            if steps > 1 {
                for i in 1..<steps {
                    let ix = lx + (cx - lx) * i / steps
                    let iy = ly + (cy - ly) * i / steps
                    stamp(ix, iy, r, g, b)
                }
            }
        }
        stamp(cx, cy, r, g, b)
        lastCell = (cx, cy)
    }

    private func stamp(_ cx: Int, _ cy: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
        let half = brush / 2
        for dy in -half...(brush - 1 - half) {
            for dx in -half...(brush - 1 - half) {
                put(cx + dx, cy + dy, r, g, b)
                if mirror { put(63 - (cx + dx), cy + dy, r, g, b) }
            }
        }
    }

    private func put(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
        guard (0..<64).contains(x), (0..<64).contains(y) else { return }
        let i = (y * 64 + x) * 3
        px[i] = r; px[i + 1] = g; px[i + 2] = b
    }

    private func floodFill(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8) {
        let i0 = (y * 64 + x) * 3
        let target = (px[i0], px[i0 + 1], px[i0 + 2])
        guard target != (r, g, b) else { return }
        var queue = [(x, y)]
        while let (qx, qy) = queue.popLast() {
            guard (0..<64).contains(qx), (0..<64).contains(qy) else { continue }
            let i = (qy * 64 + qx) * 3
            guard (px[i], px[i + 1], px[i + 2]) == target else { continue }
            px[i] = r; px[i + 1] = g; px[i + 2] = b
            queue.append((qx + 1, qy)); queue.append((qx - 1, qy))
            queue.append((qx, qy + 1)); queue.append((qx, qy - 1))
        }
    }
}
