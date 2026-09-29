// The Home Screen widget's views, shared by the widget, the Settings page
// that previews it and the render harness that photographs it.
//
// They only draw a WidgetReading. The small widget is the panel alone, with
// one label when the picture is not current, the wall is dark or a check is
// up. The medium
// widget puts the panel against three edges and gives the words a padded
// column of their own, so the title never sits on the art and the keys
// never sit under the corner mask.
//
// Type is capped at accessibility2 inside the views, not in the widget's
// entry view, so the page and the harness draw exactly the layout the
// widget draws at every text size. The keys and the small widget's label
// stop growing earlier, at xxxLarge: three keys share a column about 140 pt
// wide, and a label that grew past it would only step down again, smaller
// at accessibility sizes than at xxxLarge.
//
// No word is ever cut. Labels step down in size before they wrap. A title
// steps down until its widest word fits the column. A song's title and its
// artist end after a whole word when they run long ("Everything Is
// Beautiful..."), never inside one, and the artist is set only beside a
// title that is whole or takes its two lines: the title wins. The widget's
// own words ("Dark between songs") are shown whole or not at all. A timer's
// time left, a place, a hint, a dimmed picture's age and what the wall is
// changing to are never dropped: the title steps down in size, or gives a
// value its place, first. The three keys always share one
// size. WidgetRenderHarness measures these very views, and checks each of
// these rules with the numbers below, so the two cannot drift apart.

import AppIntents
import SwiftUI
import WidgetKit

enum WallWidgetFamily: String, CaseIterable {
    case small, medium

    /// The key WidgetKit's family is recorded under (WallSnapshot.measured).
    var measuredKey: String { self == .small ? "systemSmall" : "systemMedium" }

    init?(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        default: return nil
        }
    }
}

enum WidgetMetrics {
    /// The widget's size in points. The size WidgetKit reported on this
    /// phone wins. Until it has, the usual sizes by screen class.
    static func size(family: WallWidgetFamily, screen: CGSize, measured: CGSize? = nil) -> CGSize {
        if let measured, measured.width > 0, measured.height > 0 { return measured }
        let side: CGFloat
        let wide: CGFloat
        switch screen.width {
        case 428...: (side, wide) = (170, 364)
        case 390...: (side, wide) = (158, 338)
        case 375... where screen.height >= 812: (side, wide) = (155, 329)
        default: (side, wide) = (148, 321)
        }
        return family == .small ? CGSize(width: side, height: side) : CGSize(width: wide, height: side)
    }
}

/// The widget's type. relativeTo keeps each face growing with Dynamic Type.
enum WidgetType {
    static let labelFace = "MartianMono-Medium"
    static let labelSize: CGFloat = 9
    /// The status line's symbol, grown and stepped down with its words.
    static let symbolSize: CGFloat = 8
    static let symbolGap: CGFloat = 5
    static let titleFace = "Technor-Bold"
    static let titleSize: CGFloat = 18
    /// The title at one of titleSteps. Scaled by SwiftUI like .headline,
    /// which rounds to whole points, so step 1 is the size it always was
    /// and the harness measures the same font.
    static func title(step: CGFloat) -> Font {
        .custom(titleFace, size: titleSize * step, relativeTo: .headline)
    }
    static let subtitleFace = "Switzer-Medium"
    static let subtitleSize: CGFloat = 12
    static let countdown = Font.custom(labelFace, size: subtitleSize, relativeTo: .caption)
    /// The sizes a subtitle the reading keeps and never shortens (a place,
    /// a hint) tries whole in its lines, before it is shrunk onto one line.
    static let subtitleSteps: [CGFloat] = [1, 0.9, 0.8, 0.7]
    static let keyFace = "Switzer-Medium"
    static let keySelectedFace = "Switzer-Semibold"
    static let keySize: CGFloat = 12

    /// The sizes a label tries on one line, as fractions of its size at the
    /// text size in use. 0.8 lets "Queued for the wall" keep one line on a
    /// 375 pt phone at the default size. 0.7 and 0.6 keep "As of 15:12"
    /// and "Check running" on one line at accessibility2, which leaves the
    /// title the room it needs: even 0.6 is larger there than the label at
    /// the default size.
    static let labelSteps: [CGFloat] = [1, 0.9, 0.8, 0.7, 0.6]
    /// No step sets a label smaller than this. Past it, a second line.
    static let labelFloor: CGFloat = 7
    /// The steps a label of this size tries.
    static func labelSteps(size: CGFloat) -> [CGFloat] {
        labelSteps.filter { $0 == 1 || size * $0 >= labelFloor }
    }
    /// A label may take a second line at any text size, when even the
    /// smallest step would cut it. A second line beats a truncated word.
    static let labelLines = 2
    /// The size of a two line label, as a fraction of its size at the text
    /// size in use.
    static let labelMinScale: CGFloat = 0.7
    /// Keys stop growing here. At accessibility2 "Lamp" would need a scale
    /// of 0.63 to fit its key, at xxxLarge about 0.8 on the smallest phones.
    static let keyCap = DynamicTypeSize.xxxLarge
    /// The small widget's label stops growing here too. Past it, "Open
    /// Tessera" and "Nothing playing" only stepped down again, or took two
    /// lines, and drew smaller at accessibility sizes than at xxxLarge.
    static let chipCap = DynamicTypeSize.xxxLarge
    /// The label's inset from the small widget's leading and bottom edges.
    static let chipInset: CGFloat = 10
    /// Its room ends this far from the trailing edge, so its corner stays
    /// clear of the widget's rounded corner below it.
    static let chipTrailing: CGFloat = 20
    /// The width a small widget of this width offers the label's words:
    /// less the insets and the label's own padding.
    static func chipWords(width: CGFloat) -> CGFloat { width - chipInset - chipTrailing - 14 }
    /// The sizes the three keys try together, so they always share one.
    static let keySteps: [CGFloat] = [1, 0.9, 0.8, 0.7]
    static var keyMinScale: CGFloat { keySteps.last ?? 1 }
    /// A song's title gets two lines, then ends after a whole word. Other
    /// titles are never cut, so they have no line limit
    /// (WidgetReading.titleIsSong).
    static let songLines = 2
    /// The smallest step at which an optional subtitle (an artist, "Dark
    /// between songs") still sits beside the title. Below it the subtitle
    /// gives way first.
    static let titleMinScale: CGFloat = 0.75
    /// The smallest of the title's usual steps. At accessibility2 it is
    /// still larger than the title at the default text size. A subtitle
    /// the reading keeps stays beside the title down to here before it
    /// takes the title's place.
    static let titleShrinkScale: CGFloat = 0.6
    /// The sizes a title steps through, as fractions of its size at the
    /// text size in use. A word wider than its line would be broken
    /// mid-word, and the broken title could still fit the height, so the
    /// size starts at the first step at which the widest word fits the
    /// column on one line. From there the title steps down again, only as
    /// far as the height needs.
    static let titleSteps: [CGFloat] = [1, 0.85, titleMinScale, titleShrinkScale]
    /// The last sizes a title takes, only when it fits the height at none
    /// of titleSteps: smaller and whole, before anything the widget must
    /// show is dropped or cut.
    static let titleLastSteps: [CGFloat] = [0.5, 0.4]
    /// Every size a title may take from `step` down, largest first.
    static func titleSizes(from step: CGFloat) -> [CGFloat] {
        (titleSteps + titleLastSteps).filter { $0 <= step }
    }
}

// MARK: - Whole words

/// Text in at most `lines` lines that ends after a whole word, never inside
/// one. It measures the whole text and each whole-word prefix at the width
/// it is offered and sets the longest that fits. A text that never
/// shortens tries itself whole at each of `steps` instead. When nothing
/// fits, it is left out (hidesWhenCut, for a subtitle) or the last choice
/// shrinks onto one line, whole.
struct WordFitText: View {
    let text: String
    let lines: Int
    var hidesWhenCut = false
    /// Space above the text, taken only when there is text to show.
    var lead: CGFloat = 0
    /// Whether a shortened text ends in an ellipsis (WordFit.candidates).
    var ellipsis = true
    /// False: the whole text or, with hidesWhenCut, nothing.
    var shortens = true
    /// Leaves out a shortened text with no word of four letters ("The...").
    var telling = false
    /// The sizes the whole text tries, as fractions of its size, when it
    /// never shortens.
    var steps: [CGFloat] = [1]
    /// The face at a fraction of its size.
    let style: (Text, CGFloat) -> Text

    /// Each choice and the fraction of its size it is set at, in order.
    static func choices(_ text: String, ellipsis: Bool, shortens: Bool, telling: Bool,
                        steps: [CGFloat]) -> [(text: String, step: CGFloat)] {
        let all = WordFit.candidates(text, ellipsis: ellipsis, telling: telling)
        guard let whole = all.first else { return [] }
        if shortens { return all.map { ($0, 1) } }
        return (steps.isEmpty ? [1] : steps).map { (whole, $0) }
    }

    var body: some View {
        let shown = Self.choices(text, ellipsis: ellipsis, shortens: shortens, telling: telling, steps: steps)
            .map { (text: WordFit.display($0.text), step: $0.step) }
        let reference = Array(repeating: "A", count: max(1, lines)).joined(separator: "\n")
        // Measures only, never drawn: the height of `lines` lines at each
        // choice's size, each choice at the offered width, and each
        // choice's widest word.
        WordFitLayout(count: shown.count, hides: hidesWhenCut) {
            ForEach(shown.indices, id: \.self) { i in piece(reference, step: shown[i].step).hidden() }
            ForEach(shown.indices, id: \.self) { i in piece(shown[i].text, step: shown[i].step).hidden() }
            ForEach(shown.indices, id: \.self) { i in widest(shown[i].text, step: shown[i].step).hidden() }
            if !hidesWhenCut, let last = shown.last { fallback(last.text, step: last.step).hidden() }
        }
        // The layout has sized itself to the choice it made. Offered
        // exactly that height, this picks the same one: every earlier
        // choice is at least a line taller.
        .overlay(alignment: .topLeading) {
            ViewThatFits(in: .vertical) {
                ForEach(shown.indices, id: \.self) { i in piece(shown[i].text, step: shown[i].step) }
                if !hidesWhenCut, let last = shown.last {
                    fallback(last.text, step: last.step)
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        }
    }

    private func piece(_ s: String, step: CGFloat) -> some View {
        style(Text(s), step).fixedSize(horizontal: false, vertical: true).padding(.top, lead)
    }

    private func widest(_ s: String, step: CGFloat) -> some View {
        let words = WordFit.words(s)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(words.indices, id: \.self) { i in style(Text(words[i]), step).lineLimit(1).fixedSize() }
        }
        .fixedSize()
    }

    private func fallback(_ s: String, step: CGFloat) -> some View {
        style(Text(s), step).lineLimit(1).minimumScaleFactor(0.4).padding(.top, lead)
    }
}

/// Subviews: the reference lines at each choice's size, the choices, each
/// choice's widest word, then the fallback when there is one. It takes the
/// size of the first choice that fits its lines with no word wider than the
/// width.
private struct WordFitLayout: Layout {
    let count: Int
    let hides: Bool

    private func chosen(_ width: CGFloat, _ subviews: Subviews) -> Int? {
        let wide = ProposedViewSize(width: width, height: nil)
        for i in 0..<count {
            guard subviews[2 * count + i].sizeThatFits(.unspecified).width <= width + 0.5 else { continue }
            let limit = subviews[i].sizeThatFits(wide).height + 0.5
            if subviews[count + i].sizeThatFits(wide).height <= limit { return count + i }
        }
        let fallback = 3 * count
        return !hides && subviews.count > fallback ? fallback : nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard count > 0, subviews.count >= 3 * count else { return .zero }
        guard let width = proposal.width, width.isFinite else {
            return subviews[count].sizeThatFits(.unspecified)
        }
        guard let pick = chosen(width, subviews) else { return .zero }
        // A hair over, so the overlay's ViewThatFits is never a rounding
        // short of the candidate it must pick.
        let height = subviews[pick].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: height + 0.25)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

// MARK: - The panel

/// The wall's frame, rastered at the pixel size it is shown at, so nothing
/// is stretched: the blur of an upscaled bitmap was half of why the widget
/// looked unlike the wall.
struct WidgetPanelFace: View {
    let frame: Data?
    let side: Int?
    let duty: Double
    let dark: Bool
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            if let image = Self.image(frame: dark ? nil : frame, side: side, pixels: s * scale, duty: duty) {
                // The frame is a photograph of the wall: the Tinted and Clear
                // Home Screens would otherwise redraw it as monochrome glass.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .widgetAccentedRenderingMode(.fullColor)
                    .frame(width: s, height: s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The placeholder redacts the words. The lattice is the object, and
        // stays.
        .unredacted()
    }

    /// Rasters by content, cell and duty, since WidgetKit and the page may
    /// ask for the same picture several times.
    private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.totalCostLimit = 12 * 1024 * 1024
        return c
    }()

    static func image(frame: Data?, side: Int?, pixels: CGFloat, duty: Double) -> CGImage? {
        let px: [UInt8]
        if let frame, Panel.square(frame) != nil {
            px = [UInt8](frame)
        } else {
            // The wall with nothing on it, at the size the snapshot was taken:
            // still the object, not an empty square.
            px = Panel.blank(side: side.flatMap { $0 >= 16 ? $0 : nil } ?? Panel.side)
        }
        guard let n = Panel.square(px.count) else { return nil }
        // A dense wall at a size its emitters do not divide is rastered at
        // the exact size shown, so no resampling beats against the lattice.
        let exact = EmitterRaster.wantsExact(pixels: pixels, side: n)
        let cell = EmitterRaster.cell(forPixels: pixels, side: n)
        let size = exact ? "x\(Int(pixels.rounded()))" : "c\(cell)"
        let key = "\(EmitterRaster.digest(px))|\(n)|\(size)|\(Int((duty * 100).rounded()))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let made = exact ? EmitterRaster.render(px, pixels: Int(pixels.rounded()), duty: duty)
            : EmitterRaster.render(px, cell: cell, duty: duty)
        guard let image = made else { return nil }
        cache.setObject(image, forKey: key, cost: image.width * image.height * 4)
        return image
    }
}

/// Ink.ground as an image. Images can opt out of the accented rendering, so
/// a label's ground stays dark in Tinted and Clear and the words never sit
/// on the artwork.
struct WidgetGround: View {
    private static let pixel = EmitterRaster.solid(r: 0x0B, g: 0x0A, b: 0x09)

    var body: some View {
        if let pixel = Self.pixel {
            Image(decorative: pixel, scale: 1)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
        } else {
            Ink.ground
        }
    }
}

// MARK: - Words

/// A label's words, for the chip and the status line, after the status
/// line's symbol when there is one. One line when it fits, stepping down in
/// size first (WidgetType.labelSteps), the symbol with the words. Two lines
/// only when the smallest step would still be cut. ViewThatFits measures a
/// text at its full size and cannot see minimumScaleFactor, so the steps
/// are real point sizes.
struct WidgetLabelText: View {
    let text: String
    var symbol: String? = nil
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = WidgetType.labelSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(WidgetType.labelSteps(size: size), id: \.self) { step in
                marked(step: step) {
                    Text(text)
                        .font(.custom(WidgetType.labelFace, fixedSize: size * step))
                        .kerning(0.6)
                        .lineLimit(1)
                }
            }
            // The last choice is taken whether it fits or not, so it wraps,
            // at labelMinScale: two lines at the full size would jump well
            // past the one-line steps. It shrinks further only if a single
            // word is wider than the line.
            marked(step: WidgetType.labelMinScale) {
                Text(text)
                    .font(.custom(WidgetType.labelFace, fixedSize: size * WidgetType.labelMinScale))
                    .kerning(0.6 * WidgetType.labelMinScale)
                    .lineLimit(WidgetType.labelLines)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func marked<Words: View>(step: CGFloat, @ViewBuilder _ words: () -> Words) -> some View {
        if let symbol {
            HStack(alignment: .firstTextBaseline, spacing: WidgetType.symbolGap) {
                WidgetStatusSymbol(symbol: symbol, step: step)
                words()
            }
        } else {
            words()
        }
    }
}

/// The small widget's single label.
struct WidgetChip: View {
    let text: String

    var body: some View {
        WidgetLabelText(text: text.uppercased())
            .foregroundStyle(Ink.ink)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background { WidgetGround().clipShape(RoundedRectangle(cornerRadius: Round.chip)) }
    }
}

/// The status line's symbol, grown with the words beside it so it never
/// shrinks to a speck at the larger sizes, and stepped down with them so it
/// never takes their room.
struct WidgetStatusSymbol: View {
    let symbol: String
    var step: CGFloat = 1
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = WidgetType.symbolSize

    var body: some View {
        Image(systemName: symbol).font(.system(size: size * step, weight: .semibold))
    }
}

/// The medium widget's status word, above the title.
struct WidgetStatusLine: View {
    let text: String
    let symbol: String

    var body: some View {
        WidgetLabelText(text: text.uppercased(), symbol: symbol)
            .foregroundStyle(Ink.dim)
            // Its full height always: the title is what gives way.
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Art, Lamp and Off: the same three keys, radius and wire names as the
/// Dynamic Island's.
struct WidgetKeyRow: View {
    let reading: WidgetReading
    /// False on the Settings page, whose preview must never send anything.
    let interactive: Bool

    var body: some View {
        WidgetKeys(reading: reading, interactive: interactive)
            // Capped here, below the rest of the widget, so a key's word is
            // never cut (WidgetType.keyCap).
            .dynamicTypeSize(...WidgetType.keyCap)
    }
}

/// The three keys at the largest of WidgetType.keySteps at which all three
/// words fit their keys, so one key never sets smaller than the others.
private struct WidgetKeys: View {
    let reading: WidgetReading
    let interactive: Bool
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = WidgetType.keySize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(WidgetType.keySteps, id: \.self) { step in
                row(size * step)
            }
        }
    }

    private func row(_ points: CGFloat) -> some View {
        EqualKeysLayout(spacing: 6) {
            key("Art", spoken: "Album art", mode: .art, points: points)
            key("Lamp", spoken: "Lamp", mode: .lamp, points: points)
            key("Off", spoken: "Off", mode: .off, points: points)
        }
    }

    @ViewBuilder private func key(_ title: String, spoken: String, mode: WallMode, points: CGFloat) -> some View {
        let on = reading.selectedKey == mode.wire
        let face = WidgetKeyFace(title: title, on: on, inert: reading.keysInert, points: points)
        // A current, selected key is a label. Re-sending an accepted mode is
        // not harmless: "art" releases an Archive replay, and any mode ends a
        // guest code or a check on the wall. While a check runs, no key sends.
        if interactive && !reading.keysInert && !(on && reading.settled) {
            Button(intent: SetWallModeIntent(mode: mode)) { face }
                .buttonStyle(.plain)
                .accessibilityLabel(spoken)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("widget.key.\(mode.wire)")
        } else {
            face
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

private struct WidgetKeyFace: View {
    let title: String
    let on: Bool
    let inert: Bool
    let points: CGFloat

    var body: some View {
        Text(title)
            .font(.custom(on ? WidgetType.keySelectedFace : WidgetType.keyFace, fixedSize: points))
            .foregroundStyle(on ? Ink.ground : Ink.ink)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: Round.chip)
                    .fill(on ? Ink.ink : Ink.ink.opacity(0.10))
                    .widgetAccentable(on)
            }
            .contentShape(RoundedRectangle(cornerRadius: Round.chip))
            .opacity(inert ? 0.4 : 1)
    }
}

/// Three keys of one width. Asked for its ideal width, it answers three
/// times the widest key's, so the ViewThatFits above passes over a size at
/// which any one word would not fit its third of the row.
private struct EqualKeysLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        guard let width = proposal.width, width.isFinite else {
            let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(width: (ideal.map(\.width).max() ?? 0) * CGFloat(subviews.count) + gaps,
                          height: ideal.map(\.height).max() ?? 0)
        }
        let each = max(0, (width - gaps) / CGFloat(max(1, subviews.count)))
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: each, height: proposal.height)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let each = max(0, (bounds.width - gaps) / CGFloat(max(1, subviews.count)))
        for (i, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (each + spacing), y: bounds.minY),
                          proposal: ProposedViewSize(width: each, height: bounds.height))
        }
    }
}

// MARK: - The two sizes

/// The wall alone, full bleed. A label only when the picture is not current,
/// the wall is dark or a check is up.
struct WallWidgetSmall: View {
    let reading: WidgetReading
    let frame: Data?
    let side: Int?

    var body: some View {
        SmallWidgetContent(reading: reading, frame: frame, side: side)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

private struct SmallWidgetContent: View {
    let reading: WidgetReading
    let frame: Data?
    let side: Int?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WidgetPanelFace(frame: frame, side: side, duty: reading.duty, dark: reading.dark)
            if let chip = reading.chip {
                WidgetChip(text: chip)
                    .dynamicTypeSize(...WidgetType.chipCap)
                    .padding([.leading, .bottom], WidgetType.chipInset)
                    .padding(.trailing, WidgetType.chipTrailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibility)
    }
}

/// The panel against three edges, the words and keys in a column beside it.
struct WallWidgetMedium: View {
    let reading: WidgetReading
    let frame: Data?
    let side: Int?
    var interactive = true

    var body: some View {
        MediumWidgetContent(reading: reading, frame: frame, side: side, interactive: interactive)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

/// One way to set the medium widget's words, tried in order until one fits
/// the height the keys leave. The last is taken whether it fits or not.
enum MediumWordsFit: Hashable {
    /// A song's title in at most this many lines, ending after a whole word.
    case song(lines: Int, step: CGFloat, subtitle: Bool)
    /// Any other title, whole, at this step. Never cut.
    case natural(step: CGFloat, subtitle: Bool)
    /// The subtitle set as the title, when the two do not fit together
    /// (WidgetReading.promotesSubtitle): the status already says when, and
    /// the time left or the place is what the widget is for.
    case promoted(step: CGFloat)
    /// The title on one line, shrunk to fit: only when its widest word
    /// fits the column at none of the title's sizes.
    case squeezed

    /// The order for a title whose widest word fits at `step`. The render
    /// harness measures the same list.
    ///
    /// A song sets its artist only beside its title at `step`, whole or on
    /// its two lines. Past that the artist gives way, and the title steps
    /// down in size before it ends after a whole word: the title wins. A
    /// subtitle the reading keeps beside a song (a dimmed picture's age,
    /// what the wall is changing to) stays, and the title steps down beside
    /// it instead.
    ///
    /// A subtitle the reading keeps (WidgetReading.keepsSubtitle) is never
    /// dropped. The title steps down beside it, then the subtitle takes the
    /// title's place when it may, then the title steps down further.
    ///
    /// Any other subtitle is set only while the title keeps a natural size,
    /// and gives way before the title steps down.
    static func order(_ reading: WidgetReading, step: CGFloat, hasSubtitle: Bool) -> [MediumWordsFit] {
        let sizes = WidgetType.titleSizes(from: step)
        if reading.titleIsSong {
            let lines = WidgetType.songLines
            if reading.keepsSubtitle && hasSubtitle {
                return sizes.map { .song(lines: lines, step: $0, subtitle: true) }
            }
            var out: [MediumWordsFit] = []
            if hasSubtitle { out.append(.song(lines: lines, step: step, subtitle: true)) }
            out += sizes.map { .song(lines: lines, step: $0, subtitle: false) }
            return out
        }
        if reading.keepsSubtitle && hasSubtitle {
            let usual = sizes.filter { $0 >= WidgetType.titleShrinkScale }
            var out = usual.map { MediumWordsFit.natural(step: $0, subtitle: true) }
            if reading.promotesSubtitle { out += usual.map { .promoted(step: $0) } }
            out += sizes.filter { $0 < WidgetType.titleShrinkScale }.map { .natural(step: $0, subtitle: true) }
            return out
        }
        var out: [MediumWordsFit] = []
        if hasSubtitle && step >= WidgetType.titleMinScale { out.append(.natural(step: step, subtitle: true)) }
        out += sizes.map { .natural(step: $0, subtitle: false) }
        return out
    }
}

extension WidgetReading {
    /// A counting timer's end, for a live countdown.
    var countingDown: Date? {
        if let ends = timerEnds, ends > at { return ends }
        return nil
    }

    /// Whether the medium widget has a subtitle line to set.
    var hasSubtitle: Bool { countingDown != nil || subtitle != nil }
}

private struct MediumWidgetContent: View {
    let reading: WidgetReading
    let frame: Data?
    let side: Int?
    let interactive: Bool

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                WidgetPanelFace(frame: frame, side: side, duty: reading.duty, dark: reading.dark)
                    .frame(width: geo.size.height, height: geo.size.height)
                    .accessibilityHidden(true)
                column
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            MediumWords(reading: reading)
                // The words are offered all the height the keys and the gap
                // above them leave, so the keys stay put at every size.
                .layoutPriority(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(reading.accessibility)
            if reading.showsKeys {
                Spacer(minLength: 8)
                WidgetKeyRow(reading: reading, interactive: interactive)
            }
        }
    }
}

/// The medium widget's words. The title's size comes first: the first of
/// WidgetType.titleSizes at which its widest word fits the column. At that
/// size, the first of MediumWordsFit.order that fits the height. The status
/// is never dropped: it says whether the picture is current. Nothing is cut
/// mid-word.
struct MediumWords: View {
    let reading: WidgetReading

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(WidgetType.titleSizes(from: 1), id: \.self) { step in
                words(step: step)
            }
            // A word too wide even at the smallest size.
            MediumWordsBlock(reading: reading, fit: .squeezed)
        }
    }

    /// The words with the title at one step of its size. Asked how wide it
    /// would like to be, it answers with the title's widest word, so the
    /// ViewThatFits above passes over a step that word does not fit.
    private func words(step: CGFloat) -> some View {
        WidestWordLayout {
            widestWord(step: step)
            ViewThatFits(in: .vertical) {
                ForEach(MediumWordsFit.order(reading, step: step, hasSubtitle: reading.hasSubtitle), id: \.self) { fit in
                    MediumWordsBlock(reading: reading, fit: fit)
                }
            }
        }
    }

    /// The title's words, never drawn, one to a line, at this step: as wide
    /// as the widest of them.
    private func widestWord(step: CGFloat) -> some View {
        let words = WordFit.words(WordFit.display(reading.title))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(words.indices, id: \.self) { i in
                WidgetTitle.text(words[i], step: step).lineLimit(1)
            }
        }
        .fixedSize()
        .hidden()
    }
}

/// The title's face at one step of its size.
enum WidgetTitle {
    static func style(_ text: Text, step: CGFloat) -> Text {
        text
            .font(WidgetType.title(step: step))
            .tracking(-0.3 * step)
            .foregroundStyle(Ink.ink)
    }

    static func text(_ string: String, step: CGFloat) -> Text {
        style(Text(string), step: step)
    }
}

/// The medium widget's words set one way: the status, the title and the
/// subtitle as `fit` says. Internal so the render harness measures the very
/// views the widget chooses between.
struct MediumWordsBlock: View {
    let reading: WidgetReading
    let fit: MediumWordsFit

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            switch fit {
            case .song(let lines, let step, let showsSubtitle):
                WordFitText(text: reading.title, lines: lines) { text, _ in WidgetTitle.style(text, step: step) }
                if showsSubtitle { subtitle }
            case .natural(let step, let showsSubtitle):
                WidgetTitle.text(reading.title, step: step)
                    .fixedSize(horizontal: false, vertical: true)
                if showsSubtitle { subtitle }
            case .promoted(let step):
                promoted(step: step)
            case .squeezed:
                squeezed
                if reading.keepsSubtitle { subtitle }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let status = reading.status {
            WidgetStatusLine(text: status, symbol: reading.statusSymbol)
                .padding(.bottom, 6)
        }
    }

    /// A song ends after a whole word on one line. Anything else shrinks
    /// onto it whole.
    @ViewBuilder private var squeezed: some View {
        let step = WidgetType.titleSizes(from: 1).last ?? WidgetType.titleShrinkScale
        if reading.titleIsSong {
            WordFitText(text: reading.title, lines: 1) { text, _ in WidgetTitle.style(text, step: step) }
        } else {
            WidgetTitle.text(reading.title, step: step)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
    }

    /// Whole or ending after a whole word, in its lines
    /// (WidgetReading.subtitleLines). An optional subtitle that would be cut
    /// is left out. One the reading keeps never is: it shrinks onto one
    /// line instead.
    @ViewBuilder private var subtitle: some View {
        if let ends = reading.countingDown {
            // A live countdown. Built only from a range that runs forwards:
            // Text(timerInterval:) traps on a reversed one. Short enough to
            // fit whole, and without "left" when it does not.
            ViewThatFits(in: .horizontal) {
                countdown(ends, left: true).fixedSize()
                countdown(ends, left: false).fixedSize()
                countdown(ends, left: false).minimumScaleFactor(0.5)
            }
        } else if let subtitle = reading.subtitle {
            WordFitText(text: subtitle, lines: reading.subtitleLines, hidesWhenCut: !reading.keepsSubtitle, lead: 3,
                        ellipsis: !reading.timed, shortens: reading.subtitleShortens, telling: !reading.timed,
                        steps: reading.keepsSubtitle ? WidgetType.subtitleSteps : [1]) { text, step in
                text
                    .font(.custom(reading.timed ? WidgetType.labelFace : WidgetType.subtitleFace,
                                  size: WidgetType.subtitleSize * step, relativeTo: .caption))
                    .foregroundStyle(Ink.ink.opacity(0.86))
            }
        }
    }

    private func countdown(_ ends: Date, left: Bool) -> some View {
        (Text(timerInterval: reading.at...ends, countsDown: true) + Text(left ? " left" : ""))
            .font(WidgetType.countdown)
            .foregroundStyle(Ink.ink.opacity(0.86))
            .lineLimit(1)
            .padding(.top, 3)
    }

    /// The subtitle in the title's place and size: a timer's time left on
    /// one line, a place in two, whole.
    @ViewBuilder private func promoted(step: CGFloat) -> some View {
        if let ends = reading.countingDown {
            WidgetTitle.style(Text(timerInterval: reading.at...ends, countsDown: true) + Text(" left"), step: step)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        } else {
            WordFitText(text: reading.subtitle ?? reading.title, lines: reading.subtitleLines,
                        ellipsis: !reading.timed, shortens: reading.subtitleShortens) { text, _ in
                WidgetTitle.style(text, step: step)
            }
        }
    }
}

/// Two subviews: a measure, never drawn, and the words. Offered a width, it
/// is the words, laid out in that width. Asked for its ideal size, which is
/// how ViewThatFits(in: .horizontal) weighs a choice, it is the measure, so
/// the words are taken only at a step where the title's widest word fits.
private struct WidestWordLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        guard proposal.width != nil else { return subviews[0].sizeThatFits(.unspecified) }
        return subviews[1].sizeThatFits(proposal)
    }

    /// The words get the proposal they were measured in, not the size they
    /// came back at: offered less width, their labels would pick again.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, proposal: .zero)
        subviews[1].place(at: bounds.origin, proposal: proposal)
    }
}

/// The ground and corner a Home Screen gives the widget, for the Settings
/// page and the render harness. The widget itself keeps containerBackground,
/// and the system draws its own mask.
struct WidgetCanvas<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .background(Ink.ground)
            .clipShape(RoundedRectangle(cornerRadius: Round.hero, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}
