import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// How round this display's corners are. Apple has no public API for it, so
/// the values come by panel height; only home-button phones and unknown panels
/// fall through to square.
///
/// Read from the scene's current screen every time: iPhone Duo moves the app
/// between its outer and inner display while it runs, and the two panels are
/// rounded differently.
@MainActor
enum DisplayCorners {
    static var radius: CGFloat {
        guard let screen = currentScreen else { return 0 }
        if screen.traitCollection.userInterfaceIdiom == .pad { return 18 }
        switch Int(max(screen.nativeBounds.width, screen.nativeBounds.height)) {
        case 2622, 2736, 2868: return 62
        case 2556, 2796: return 55
        // iPhone Duo inner display. Its outer display rounds only the
        // camera side this much (the hinge side barely at all); the larger
        // value is used, since a card has one radius for all four corners.
        case 2853: return 44.8
        case 2034: return 49.5
        case 2778: return 53.33
        case 2532: return 47.33
        case 2340: return 44
        case 1792: return 41.5
        case 2436, 2688: return 39
        default: return 0
        }
    }

    /// The screen the foreground scene is on, not `UIScreen.main`, which a
    /// two-display iPhone cannot answer.
    private static var currentScreen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }
}

/// Where Safari-style grid cards sit, as one pure calculation, so the page can
/// land exactly on its card (and grow back out of it) without measuring
/// anything. The browser and the overview both use it with the same scroll.
///
/// A card is the page alone, without the status bar's strip above it, in the
/// page's own proportions, with its title under it.
struct PageGridGeometry {
    let screen: CGSize
    let count: Int
    /// The status bar's height: the page starts below it, and so does a card
    /// grown back to the page.
    var topInset: CGFloat = 0
    /// The overview's buttons at the bottom; the last row scrolls clear of them.
    var bottomClearance: CGFloat = 0

    static let sideInset: CGFloat = 16
    static let gutter: CGFloat = 14
    /// Room under each card for its icon and title.
    static let titleHeight: CGFloat = 28
    static let rowGap: CGFloat = 12
    static let topGap: CGFloat = 14

    /// A card's corners: the display's curve, scaled with the card.
    @MainActor static var cornerRadius: CGFloat { max(14, DisplayCorners.radius * 0.42) }
    /// A tapped card growing back into its page.
    static let openMotion = Animation.spring(duration: 0.4, bounce: 0)

    /// Two columns on a phone, three on a wide window.
    var columns: Int { screen.width >= 700 ? 3 : 2 }

    /// The part of the screen the page fills.
    var pageHeight: CGFloat { max(0, screen.height - topInset) }

    var cardSize: CGSize {
        let columns = CGFloat(columns)
        let width = max(1, (screen.width - Self.sideInset * 2 - Self.gutter * (columns - 1)) / columns)
        return CGSize(width: width, height: width * pageHeight / max(screen.width, 1))
    }

    var rowHeight: CGFloat { cardSize.height + Self.titleHeight + Self.rowGap }
    private var contentTop: CGFloat { topInset + Self.topGap }
    private var rows: Int { (count + columns - 1) / columns }
    var contentHeight: CGFloat { contentTop + CGFloat(rows) * rowHeight + bottomClearance }
    var maxScroll: CGFloat { max(0, contentHeight - screen.height) }

    /// The card's frame on screen, with the grid scrolled by `scroll`.
    func frame(index: Int, scroll: CGFloat) -> CGRect {
        let row = index / columns
        let column = index % columns
        let size = cardSize
        return CGRect(
            x: Self.sideInset + CGFloat(column) * (size.width + Self.gutter),
            y: contentTop + CGFloat(row) * rowHeight - scroll,
            width: size.width,
            height: size.height
        )
    }

    /// The card grown to the whole page: below the status bar, edge to edge.
    var pageFrame: CGRect {
        CGRect(x: 0, y: topInset, width: screen.width, height: pageHeight)
    }

    /// The scroll that puts this card's row in the middle of the space between
    /// the status bar and the buttons, as far as the grid allows.
    func scroll(showing index: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let card = frame(index: min(max(0, index), count - 1), scroll: 0)
        let visibleMiddle = (topInset + (screen.height - bottomClearance)) / 2
        return clamped(card.midY - visibleMiddle)
    }

    func clamped(_ scroll: CGFloat) -> CGFloat {
        min(maxScroll, max(0, scroll))
    }

    /// Past either end the grid follows the finger at a third of its pace.
    func rubberBanded(_ scroll: CGFloat) -> CGFloat {
        if scroll < 0 { return scroll / 3 }
        if scroll > maxScroll { return maxScroll + (scroll - maxScroll) / 3 }
        return scroll
    }

    /// Whether a card is on screen, or a row away from it.
    func isNear(index: Int, scroll: CGFloat) -> Bool {
        let card = frame(index: index, scroll: scroll)
        return card.maxY > -rowHeight && card.minY < screen.height + rowHeight
    }
}

/// Moves the grid frame by frame once the finger lets go: it coasts and slows
/// like a system scroll view, and springs back past either end.
///
/// SwiftUI's own animation can't do this: it would show the grid at its end
/// position at once to every card that comes into view, so a card that only
/// fits on screen at the end would sit there while the others scroll past.
/// Here `scroll` is the true position every frame, so only the cards really
/// on screen are drawn, and they are drawn where they are.
///
/// The display link asks for up to 120 frames a second and iOS gives what the
/// screen runs at: 60 in Low Power Mode, or on a display without ProMotion.
@MainActor
final class GridScrollDriver: NSObject {
    /// How much speed is kept every millisecond, like UIScrollView's normal rate.
    private static let deceleration: Double = 0.998
    /// The spring back to an end, or to a given place: critically damped,
    /// settling in about half a second.
    private static let stiffness: Double = 180
    private static var damping: Double { 2 * stiffness.squareRoot() }

    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval?
    private var velocity: Double = 0
    /// A fixed place to spring to; with none it coasts, then keeps in bounds.
    private var target: Double?
    /// A steady speed (points a second) until stopped or an end is reached:
    /// a card held at the grid's edge scrolls it.
    private var glideSpeed: Double?
    private var read: () -> CGFloat = { 0 }
    private var write: (CGFloat) -> Void = { _ in }
    private var bounds: () -> ClosedRange<CGFloat> = { 0...0 }

    var isRunning: Bool { link != nil }

    /// Coasts on from `velocity` (points a second, in the scroll's direction).
    func coast(
        velocity: CGFloat,
        read: @escaping () -> CGFloat,
        write: @escaping (CGFloat) -> Void,
        bounds: @escaping () -> ClosedRange<CGFloat>
    ) {
        self.velocity = Double(velocity)
        target = nil
        start(read: read, write: write, bounds: bounds)
    }

    /// Springs to `place`.
    func spring(
        to place: CGFloat,
        read: @escaping () -> CGFloat,
        write: @escaping (CGFloat) -> Void,
        bounds: @escaping () -> ClosedRange<CGFloat>
    ) {
        if !isRunning { velocity = 0 }
        target = Double(place)
        start(read: read, write: write, bounds: bounds)
    }

    /// Moves at a steady `speed` until stopped.
    func glide(
        speed: CGFloat,
        read: @escaping () -> CGFloat,
        write: @escaping (CGFloat) -> Void,
        bounds: @escaping () -> ClosedRange<CGFloat>
    ) {
        velocity = 0
        target = nil
        glideSpeed = Double(speed)
        start(read: read, write: write, bounds: bounds)
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTime = nil
        velocity = 0
        target = nil
        glideSpeed = nil
    }

    private func start(
        read: @escaping () -> CGFloat,
        write: @escaping (CGFloat) -> Void,
        bounds: @escaping () -> ClosedRange<CGFloat>
    ) {
        self.read = read
        self.write = write
        self.bounds = bounds
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        // The first frame has no time behind it: it only takes a reading.
        let dt = min(1.0 / 30, max(0, now - (lastTime ?? now)))
        lastTime = now
        guard dt > 0 else { return }

        var position = Double(read())
        let range = bounds()
        let low = Double(range.lowerBound)
        let high = Double(range.upperBound)

        if let glideSpeed {
            let next = min(high, max(low, position + glideSpeed * dt))
            write(CGFloat(next))
            if next == low || next == high { stop() }
            return
        }

        if target == nil, position >= low, position <= high {
            // Coasting inside the grid.
            velocity *= pow(Self.deceleration, dt * 1000)
            position += velocity * dt
            if abs(velocity) < 8 {
                write(CGFloat(position))
                stop()
                return
            }
        } else {
            // A spring: to the given place, or back to the end it went past.
            let goal = target.map { min(high, max(low, $0)) } ?? min(high, max(low, position))
            let force = -Self.stiffness * (position - goal) - Self.damping * velocity
            velocity += force * dt
            position += velocity * dt
            if abs(position - goal) < 0.4, abs(velocity) < 8 {
                write(CGFloat(goal))
                stop()
                return
            }
        }
        write(CGFloat(position))
    }
}

/// Every open page of the section on screen as a card, in a grid like
/// Safari's. The grid scrolls under the finger; a card opens with a tap,
/// closes with its × or a swipe sideways, and long press has the rest. It
/// sits between the page and the browser's buttons, which stay on screen and
/// change their controls, so the two never stack.
struct OpenPagesOverview: View {
    let pages: OpenPagesStore
    let spaces: [ZenSpace]
    /// How a pin from here is written; folders are offered only for pins.
    let saveKind: SaveKind
    /// The card the page itself stands in for right now.
    var hiddenCardID: String?
    /// The card growing back into its page, and how far it has got.
    var expandingCardID: String?
    var expansion: CGFloat
    /// A page that is not part of the grid yet.
    var excludedCardID: String?
    /// 0 with only the page on screen, 1 with the grid fully there.
    var reveal: CGFloat
    /// Status bar height: the page, and so each card, starts below it.
    var topInset: CGFloat
    /// Height of the browser's buttons, which stay over the overview.
    var bottomClearance: CGFloat
    /// How far the grid is scrolled. Kept by the browser, so the page lands on
    /// the card where the grid really shows it.
    @Binding var scroll: CGFloat
    var onOpen: (OpenPage) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var pinError: String?
    @State private var dragStartScroll: CGFloat?
    @State private var dragAxis: DragAxis?
    /// The card being swiped sideways to close it, and how far.
    @State private var swipedID: String?
    @State private var swipe: CGFloat = 0
    @State private var driver = GridScrollDriver()
    /// The card lifted to be moved elsewhere in the grid.
    @State private var draggingID: String?

    private enum DragAxis { case vertical, sideways, ignored }

    private var visiblePages: [OpenPage] {
        pages.pages.filter { $0.id != excludedCardID }
    }

    var body: some View {
        GeometryReader { proxy in
            let grid = geometry(for: proxy.size)
            ZStack {
                backdrop
                    .ignoresSafeArea()

                if pages.pages.isEmpty {
                    emptyState
                        .padding(.bottom, bottomClearance)
                        .opacity(Double(reveal))
                } else {
                    cards(grid)
                }
            }
            // A card let go of anywhere else stays where it was moved to.
            .onDrop(
                of: [.text],
                delegate: GridDropEnd(
                    draggingID: $draggingID,
                    onHover: { dragHover(atY: $0, in: grid) },
                    onEnd: { driver.stop() }
                )
            )
            .simultaneousGesture(gridGesture(grid))
            .onChange(of: pages.pages.map(\.id)) { _, _ in
                // A page can go without passing through `close`: a popup
                // that closes itself, a page that expires. The grid must not
                // stay scrolled past its new end.
                let clamped = grid.clamped(scroll)
                if clamped != scroll, dragAxis != .vertical {
                    drive(grid) { $0.spring(to: clamped, read: $1, write: $2, bounds: $3) }
                }
            }
        }
        .onDisappear { driver.stop() }
        // The cards are laid out from the reader's origin, so the finger is
        // read from there too.
        .coordinateSpace(.named(Self.gridSpace))
        // Top to bottom like the page; see the page's own frame.
        .ignoresSafeArea(edges: .vertical)
        .alert(
            Text("browser.pin_failed"),
            isPresented: Binding(get: { pinError != nil }, set: { if !$0 { pinError = nil } })
        ) {
            Button("common.done", role: .cancel) {}
        } message: {
            Text(pinError ?? "")
        }
    }

    private func geometry(for size: CGSize) -> PageGridGeometry {
        PageGridGeometry(
            screen: size,
            count: visiblePages.count,
            topInset: topInset,
            bottomClearance: bottomClearance
        )
    }

    // MARK: - Grid

    private func cards(_ grid: PageGridGeometry) -> some View {
        ZStack {
            let cards = visiblePages
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, page in
                let isExpanding = page.id == expandingCardID
                // Only what is on screen, or a row away, is drawn at all: with
                // dozens of tabs the grid still draws a handful of cards.
                if isExpanding || grid.isNear(index: index, scroll: scroll) {
                    let grown = isExpanding ? expansion : 0
                    let resting = grid.frame(index: index, scroll: scroll)
                    let target = grid.pageFrame
                    let frame = CGRect(
                        x: resting.minX + (target.minX - resting.minX) * grown,
                        y: resting.minY + (target.minY - resting.minY) * grown,
                        width: resting.width + (target.width - resting.width) * grown,
                        height: resting.height + (target.height - resting.height) * grown
                    )
                    let isCurrent = page.id == pages.activeID
                    // The others come in around the page as it shrinks.
                    let settling = isCurrent || isExpanding ? 1 : 0.92 + 0.08 * reveal
                    OpenPageCard(
                        page: page,
                        store: pages,
                        isCurrent: isCurrent && expandingCardID == nil,
                        hidesPicture: page.id == hiddenCardID,
                        size: grid.cardSize,
                        isNear: grid.isNear(index: index, scroll: scroll),
                        isExpanding: isExpanding,
                        expansion: grown,
                        isLifted: page.id == draggingID,
                        onOpen: {
                            driver.stop()
                            draggingID = nil
                            onOpen(page)
                        },
                        onClose: { close(page) },
                        onLift: {
                            driver.stop()
                            draggingID = page.id
                            return NSItemProvider(object: page.id as NSString)
                        },
                        drop: CardDrop(
                            targetID: page.id,
                            top: resting.minY,
                            draggingID: $draggingID,
                            pages: pages,
                            onHover: { dragHover(atY: $0, in: grid) },
                            onEnd: { driver.stop() }
                        )
                    ) {
                        menu(for: page)
                    }
                    .scaleEffect(frame.width / max(grid.cardSize.width, 1) * settling)
                    .position(
                        x: frame.midX + (page.id == swipedID ? swipe : 0),
                        y: frame.midY
                    )
                    .opacity(isCurrent || isExpanding ? 1 : Double(reveal))
                    .opacity(page.id == swipedID ? Double(1 - min(0.7, abs(swipe) / max(grid.cardSize.width * 1.6, 1))) : 1)
                    .zIndex(isExpanding ? 1_000 : Double(index))
                }
            }
        }
        .allowsHitTesting(reveal > 0.99)
    }

    private static let gridSpace = "OpenPagesOverview.grid"

    /// While a card is lifted: held near the top or the bottom of the grid,
    /// the grid scrolls that way, faster the closer it is to the edge. The
    /// finger is reported wherever it is, over a card or between cards.
    private func dragHover(atY y: CGFloat, in grid: PageGridGeometry) {
        guard draggingID != nil else { return }
        let zone: CGFloat = 110
        let top = topInset + zone
        let bottom = grid.screen.height - bottomClearance - zone
        let depth: CGFloat
        if y < top {
            depth = -min(1, (top - y) / zone)
        } else if y > bottom {
            depth = min(1, (y - bottom) / zone)
        } else {
            depth = 0
        }
        guard depth != 0 else {
            if driver.isRunning { driver.stop() }
            return
        }
        let speed = (depth < 0 ? -1 : 1) * (250 + 1_050 * abs(depth))
        drive(grid) { $0.glide(speed: speed, read: $1, write: $2, bounds: $3) }
    }

    /// One finger, one decision: up and down scrolls the grid, sideways on a
    /// card swipes it away. Both follow the finger and hand its speed on.
    private func gridGesture(_ grid: PageGridGeometry) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                if dragAxis == nil { chooseAxis(for: value, in: grid) }
                switch dragAxis {
                case .vertical:
                    guard draggingID == nil else { return }
                    let start = dragStartScroll ?? scroll
                    scroll = grid.rubberBanded(start - value.translation.height)
                case .sideways:
                    swipe = value.translation.width
                default:
                    break
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                dragStartScroll = nil
                switch axis {
                case .vertical:
                    if draggingID == nil { settle(value, in: grid) }
                case .sideways: releaseSwipe(value, in: grid)
                default: break
                }
            }
    }

    private func chooseAxis(for value: DragGesture.Value, in grid: PageGridGeometry) {
        // The finger catches the grid where it is.
        driver.stop()
        let width = abs(value.translation.width)
        let height = abs(value.translation.height)
        if height >= width {
            dragAxis = .vertical
            dragStartScroll = scroll
        } else if let id = cardID(at: value.startLocation, in: grid) {
            dragAxis = .sideways
            swipedID = id
            swipe = 0
        } else {
            dragAxis = .ignored
        }
    }

    /// The card under the finger.
    private func cardID(at point: CGPoint, in grid: PageGridGeometry) -> String? {
        let cards = visiblePages
        return cards.indices.first { grid.frame(index: $0, scroll: scroll).contains(point) }.map { cards[$0].id }
    }

    /// The grid coasts on at the finger's speed and comes to rest within its
    /// ends, springing back if it was pulled past one.
    private func settle(_ value: DragGesture.Value, in grid: PageGridGeometry) {
        // The finger moving up scrolls the grid down.
        let velocity = -value.velocity.height
        drive(grid) { $0.coast(velocity: velocity, read: $1, write: $2, bounds: $3) }
    }

    /// Hands the driver the scroll, and the grid's ends as they are on each
    /// frame: a card can close while the grid moves.
    private func drive(
        _ grid: PageGridGeometry,
        _ start: (
            GridScrollDriver,
            @escaping () -> CGFloat,
            @escaping (CGFloat) -> Void,
            @escaping () -> ClosedRange<CGFloat>
        ) -> Void
    ) {
        let binding = $scroll
        let pages = pages
        let excluded = excludedCardID
        start(
            driver,
            { binding.wrappedValue },
            { binding.wrappedValue = $0 },
            {
                let now = PageGridGeometry(
                    screen: grid.screen,
                    count: pages.pages.filter { $0.id != excluded }.count,
                    topInset: grid.topInset,
                    bottomClearance: grid.bottomClearance
                )
                return 0...now.maxScroll
            }
        )
    }

    /// Thrown or pulled far enough the card leaves off the side and closes;
    /// otherwise it comes back.
    private func releaseSwipe(_ value: DragGesture.Value, in grid: PageGridGeometry) {
        guard let id = swipedID, let page = visiblePages.first(where: { $0.id == id }) else {
            swipedID = nil
            swipe = 0
            return
        }
        let thrown = abs(value.velocity.width) > 700 && (value.velocity.width < 0) == (swipe < 0)
        guard swipe != 0, thrown || abs(swipe) > grid.cardSize.width * 0.5 else {
            withAnimation(.spring(duration: 0.34, bounce: 0.2)) { swipe = 0 } completion: {
                if swipe == 0 { swipedID = nil }
            }
            return
        }
        AppServices.haptics.selectionChanged()
        let destination = (swipe < 0 ? -1 : 1) * grid.screen.width
        withAnimation(.easeOut(duration: 0.2)) { swipe = destination } completion: {
            close(page)
        }
    }

    // MARK: - Backdrop

    /// The app's own background, the one the overview always had. While a
    /// card grows into its page the page stays hidden behind it: only the
    /// status bar's strip, which is no part of a card, lets the page's own
    /// show through as the grid goes.
    private var backdrop: some View {
        VStack(spacing: 0) {
            Palette.background(scheme)
                .frame(height: topInset)
                .opacity(Double(reveal))
            Palette.background(scheme)
                .opacity(expandingCardID == nil ? Double(reveal) : 1)
        }
        // Nothing reaches the browser underneath.
        .contentShape(Rectangle())
        .onTapGesture {}
        .task(id: pages.activeID ?? pages.pages.first?.id) {
            if let page = pages.active ?? pages.pages.first { await pages.loadShot(of: page) }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("kept.empty_title")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.primary)
            Text("kept.empty_message")
                .font(.system(size: 15))
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Menu

    /// Long press. Pin to space offers each space and, for a pin, its folders:
    /// the choice the browser's Pin offers.
    @ViewBuilder
    private func menu(for page: OpenPage) -> some View {
        if pages.keepsOnlyChosenPages, pages.canKeep(page) {
            Button {
                pages.toggleKeep(page.id)
            } label: {
                Label {
                    Text(page.isKept ? "browser.kept" : "browser.keep_page")
                } icon: {
                    Image(systemName: page.isKept ? "bookmark.fill" : "bookmark")
                }
            }
        }

        if let url = page.url {
            if !spaces.isEmpty, !page.model.isPrivate {
                Menu {
                    ForEach(spaces) { space in
                        let folders = saveKind == .pinned ? PinDestinationModel.folderEntries(in: space) : []
                        if folders.isEmpty {
                            Button(space.name) { pin(page, url: url, to: PinDestination(spaceId: space.id)) }
                        } else {
                            Menu(space.name) {
                                Button(space.name) { pin(page, url: url, to: PinDestination(spaceId: space.id)) }
                                ForEach(folders, id: \.folderId) { folder in
                                    Button(String(repeating: "   ", count: folder.depth) + folder.name) {
                                        pin(page, url: url, to: PinDestination(spaceId: space.id, folderId: folder.folderId))
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label {
                        Text("kept.pin_to_space")
                    } icon: {
                        Image(systemName: "pin")
                    }
                }
            }

            Button {
                UIPasteboard.general.url = url
                AppServices.haptics.selectionChanged()
            } label: {
                Label {
                    Text("kept.copy_link")
                } icon: {
                    Image(systemName: "link")
                }
            }

            SwiftUI.ShareLink(item: url) {
                Label {
                    Text("browser.share")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            close(page)
        } label: {
            Label {
                Text("kept.close_page")
            } icon: {
                Image(systemName: "xmark")
            }
        }
    }

    // MARK: - Actions

    /// The cards after it move up into the gap.
    private func close(_ page: OpenPage) {
        withAnimation(.spring(duration: 0.34, bounce: 0)) {
            _ = pages.close(page.id)
            if swipedID == page.id {
                swipedID = nil
                swipe = 0
            }
        }
    }

    /// Once the page belongs to a space it leaves the list; a failed write
    /// leaves it where it was.
    private func pin(_ page: OpenPage, url: URL, to destination: PinDestination) {
        let kind = saveKind
        Task { @MainActor in
            do {
                try await AppServices.pinWriter.addTab(
                    url: url,
                    title: page.title,
                    to: destination.spaceId,
                    // Normal tabs are never placed in a folder.
                    folderId: kind == .normal ? nil : destination.folderId,
                    kind: kind
                )
                AppServices.haptics.pinSucceeded()
                close(page)
            } catch {
                pinError = error.zenUserMessage
            }
        }
    }
}

/// A lifted card over another one: it takes that card's place in the order,
/// and the cards between slide over.
private struct CardDrop: DropDelegate {
    let targetID: String
    /// Where the card's top is in the grid, to tell the grid where the finger is.
    let top: CGFloat
    @Binding var draggingID: String?
    let pages: OpenPagesStore
    let onHover: (CGFloat) -> Void
    let onEnd: () -> Void

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }

    func dropEntered(info: DropInfo) {
        onHover(top + info.location.y)
        guard let moving = draggingID, moving != targetID else { return }
        AppServices.haptics.selectionChanged()
        withAnimation(.spring(duration: 0.32, bounce: 0)) {
            pages.move(moving, onto: targetID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onHover(top + info.location.y)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onEnd()
        draggingID = nil
        return true
    }
}

/// A lifted card between cards: it tells the grid where the finger is, and
/// let go there the order is already as it should be.
private struct GridDropEnd: DropDelegate {
    @Binding var draggingID: String?
    let onHover: (CGFloat) -> Void
    let onEnd: () -> Void

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onHover(info.location.y)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onEnd()
        draggingID = nil
        return true
    }
}

/// `focus` jumps to where an animation ends, so a card can still be on screen
/// after it left the window: it lets go of its picture only after a moment.
private let pictureDropDelay: Duration = .milliseconds(600)

/// One page: the page in small, with a close button on it, a send button for
/// later, and its icon and title under it.
private struct OpenPageCard<Menu: View>: View {
    let page: OpenPage
    let store: OpenPagesStore
    /// The page the overview was opened from: outlined, like Safari's.
    let isCurrent: Bool
    let hidesPicture: Bool
    let size: CGSize
    /// On screen or a row away: it holds its picture.
    let isNear: Bool
    /// Growing to the whole screen: it casts nothing that could show through
    /// when it fades into the live page.
    let isExpanding: Bool
    /// 1 is grown to the whole page.
    let expansion: CGFloat
    /// Picked up to be moved: its place stays, faint.
    let isLifted: Bool
    var onOpen: () -> Void
    var onClose: () -> Void
    var onLift: () -> NSItemProvider
    let drop: CardDrop
    @ViewBuilder var menu: () -> Menu

    @Environment(\.colorScheme) private var scheme

    private var radius: CGFloat { PageGridGeometry.cornerRadius }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// The controls on the card fade as it grows into its page.
    private var controlsOpacity: Double { Double(max(0, 1 - expansion * 3)) }

    var body: some View {
        OpenPageShot(page: page, store: store)
            .frame(width: size.width, height: size.height)
            .clipShape(CardOutline(radius: radius, expansion: expansion))
            .overlay {
                if isCurrent {
                    shape
                        .strokeBorder(Palette.ink(scheme).opacity(0.85), lineWidth: 2.5)
                        .allowsHitTesting(false)
                } else if scheme == .dark && !isExpanding {
                    // Dark: the shadow is lost on the background, so a faint
                    // light rim draws the card's edge.
                    shape
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
            }
            // One picture, so the page's color under it never shows through
            // while the card fades.
            .compositingGroup()
            .shadow(color: .black.opacity(isExpanding ? 0 : 0.18), radius: 8, y: 3)
            .opacity(hidesPicture ? 0 : 1)
            .contentShape(shape)
            .contentShape(.contextMenuPreview, shape)
            .contentShape(.dragPreview, shape)
            .onTapGesture(perform: onOpen)
            .contextMenu { menu() }
            // Held, then moved: like Safari, the menu gives way to the drag.
            .onDrag(onLift)
            .onDrop(of: [.text], delegate: drop)
            .opacity(isLifted ? 0.3 : 1)
            .overlay(alignment: .topTrailing) {
                closeButton
                    .opacity(hidesPicture ? 0 : controlsOpacity)
            }
            .overlay(alignment: .bottomLeading) {
                sendButton
                    .opacity(hidesPicture ? 0 : controlsOpacity)
            }
            .overlay(alignment: .bottom) {
                title
                    .offset(y: PageGridGeometry.titleHeight)
                    .opacity(hidesPicture ? 0 : controlsOpacity)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(isCurrent ? Text(verbatim: "\(page.title), \(String(localized: "kept.current_page"))") : Text(verbatim: page.title))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onOpen)
            .accessibilityAction(named: Text("kept.close_page")) { onClose() }
            .accessibilityHidden(hidesPicture)
            .task(id: isNear) {
                if isNear {
                    await store.loadShot(of: page)
                } else {
                    // Cancelled when the card comes back before the grid settles.
                    try? await Task.sleep(for: pictureDropDelay)
                    guard !Task.isCancelled else { return }
                    store.dropShot(of: page)
                }
            }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.black.opacity(0.55), in: Circle())
                // A bigger target than the circle it draws.
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(2)
        .accessibilityLabel(Text("kept.close_page"))
    }

    /// Send to desktop: wired up with the Send Tab milestone.
    private var sendButton: some View {
        Image(systemName: "laptopcomputer.and.arrow.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: 26, height: 24)
            .background(Color.black.opacity(0.35), in: Capsule())
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var title: some View {
        HStack(spacing: 6) {
            icon
            Text(page.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: size.width - 8, alignment: .center)
        .frame(height: PageGridGeometry.titleHeight)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var icon: some View {
        if let url = page.url {
            Favicon(urlString: url.absoluteString, size: 15)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
    }
}

/// A card's outline. Grown back into its page, the card meets the status
/// bar's strip with a straight edge, so its top corners square off, but only
/// over the last stretch: until then it is a card like the others.
private struct CardOutline: Shape {
    let radius: CGFloat
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let late = min(1, max(0, (expansion - 0.7) / 0.3))
        let top = radius * (1 - late * late * (3 - 2 * late))
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: top,
            style: .continuous
        ).path(in: rect)
    }
}

/// The page as it looked when it was last on screen, on its own color; its
/// favicon until then. Only the page: the status bar's strip is not part of
/// a card. The card loads and lets go of the picture.
struct OpenPageShot: View {
    let page: OpenPage
    let store: OpenPagesStore

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            (page.model.themeColor ?? Palette.background(scheme))
            if let image = page.shot {
                Color.clear
                    .overlay(alignment: .top) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            } else if let url = page.url {
                Favicon(urlString: url.absoluteString, size: 36)
            }
        }
    }
}

/// The page count in a rounded square, the way Safari shows open tabs.
struct PageCountBadge: View {
    let count: Int
    var side: CGFloat = 22

    var body: some View {
        Text(verbatim: count > 99 ? "99+" : "\(count)")
            .font(.system(size: side > 22 ? 14 : 13, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(minWidth: side, minHeight: side)
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
                    .strokeBorder(lineWidth: 2)
            )
    }
}

/// A private page in the overview, and on its way there: no picture of the
/// site, only the private page's dark surface, its eyes and its name, in the
/// system's own white.
///
/// Laid out at a card's size and only scaled to the size it is shown at: the
/// flying page is the whole screen, and type set at that size takes other
/// letter widths than the card's, so the name would shift as the card takes over.
struct PrivatePageCover: View {
    /// A focused card's width on a phone, where the layout below is set.
    private static let cardWidth: CGFloat = 276

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Palette.background(.dark)
                VStack(spacing: 10) {
                    Image("incognito")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 35)
                    Text("browser.incognito")
                        .zenFont(17, weight: .semibold, design: .rounded)
                }
                .foregroundStyle(.secondary)
                .fixedSize()
                .scaleEffect(geometry.size.width / Self.cardWidth)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .environment(\.colorScheme, .dark)
    }
}
