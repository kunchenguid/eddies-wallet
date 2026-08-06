import SwiftUI

/// The one modal-sheet body layout in the app.
///
/// Every sheet that hosts content plus a primary action is built from it, so a
/// parent never has to discover that a sheet scrolls in order to find the
/// control that finishes the job:
///
/// - The actions sit in their own bar below the scroll region, never inside
///   it. They stay on screen at every detent, on every device size, and above
///   the software keyboard, so nothing a parent must tap can be pushed under
///   the fold by longer copy, a bigger text size, or a shorter sheet.
/// - The scroll region scrolls only when the content genuinely does not fit
///   (`.scrollBounceBehavior(.basedOnSize)`), so a sheet whose content fits
///   never rubber-bands as though it were hiding something.
/// - While overflowing content still continues below the viewport, its last
///   visible line fades out at the bar instead of ending at an invisible edge.
///   The fade clears at the end of the content, so seeing it means exactly one
///   thing: there is more to scroll.
///
/// Sheets choose their height with `ewFormSheetPresentation()` or
/// `ewDetailSheetPresentation()` rather than one-off detent lists.
struct SheetForm<Content: View, Actions: View>: View {
    /// Keeps a line of body copy readable on an iPad-width sheet instead of
    /// running the full width of the card. The action bar uses the same width
    /// so a button always lines up with the field above it.
    private static var contentWidth: CGFloat { 620 }
    /// Tall enough to read as a soft dissolve rather than a drawn edge.
    private static var fadeHeight: CGFloat { EW.Space.six }

    private let content: Content
    private let actions: Actions
    @State private var contentHeight: CGFloat = 0
    @State private var contentBottom: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    init(@ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.content = content()
        self.actions = actions()
    }

    /// A hairline of slack keeps a sub-point rounding difference from claiming
    /// that content which exactly fits is scrollable.
    private var contentOverflows: Bool {
        viewportHeight > 0 && contentHeight > viewportHeight + 1
    }

    private var hasMoreContentBelow: Bool {
        contentOverflows && contentBottom > viewportHeight + 1
    }

    private var showsScrollFade: Bool { hasMoreContentBelow }

    private var scrollFadeIdentifier: String {
        showsScrollFade ? "sheet-form-scroll-fade-visible" : "sheet-form-scroll-fade-hidden"
    }

    private var hasActions: Bool { Actions.self != EmptyView.self }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .padding(EW.Space.screenMargin)
                    .frame(maxWidth: Self.contentWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(
                        ContentMetricsReader(
                            height: $contentHeight,
                            bottom: $contentBottom
                        )
                    )
            }
            .scrollBounceBehavior(.basedOnSize)
            .coordinateSpace(name: SheetFormCoordinateSpace.scroll)
            .accessibilityIdentifier(scrollFadeIdentifier)
            .background(HeightReader(height: $viewportHeight))
            .overlay(alignment: .bottom) { scrollFade }

            if hasActions {
                actionBar
            }
        }
        .background(EW.Color.appBackground)
    }

    /// Only drawn while there really is more content below, and never over the
    /// action bar, so the signal cannot be mistaken for decoration.
    @ViewBuilder
    private var scrollFade: some View {
        if showsScrollFade {
            LinearGradient(
                colors: [EW.Color.appBackground.opacity(0), EW.Color.appBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.fadeHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var actionBar: some View {
        VStack(spacing: EW.Space.two) {
            actions
        }
        .padding(.horizontal, EW.Space.screenMargin)
        .padding(.top, EW.Space.three)
        .padding(.bottom, EW.Space.three)
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(EW.Color.appBackground)
    }
}

extension SheetForm where Actions == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, actions: { EmptyView() })
    }
}

private enum SheetFormCoordinateSpace {
    static let scroll = "sheet-form-scroll"
}

/// Reports the content's size and moving bottom edge in its scroll viewport.
private struct ContentMetricsReader: View {
    @Binding var height: CGFloat
    @Binding var bottom: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let contentBottom = proxy.frame(in: .named(SheetFormCoordinateSpace.scroll)).maxY

            Color.clear
                .onAppear {
                    height = proxy.size.height
                    bottom = contentBottom
                }
                .onChange(of: proxy.size.height) { _, newValue in height = newValue }
                .onChange(of: contentBottom) { _, newValue in bottom = newValue }
        }
    }
}

/// Reports the height of the view it backs, without affecting that layout.
private struct HeightReader: View {
    @Binding var height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { height = proxy.size.height }
                .onChange(of: proxy.size.height) { _, newValue in height = newValue }
        }
    }
}

extension View {
    /// Sheets that host a form the software keyboard can cover open at full
    /// height only: a half-height sheet plus a keyboard leaves too little room
    /// for the fields and the decision the parent came to make.
    func ewFormSheetPresentation() -> some View {
        presentationDetents([.large])
    }

    /// Read-only detail sheets carry no keyboard, so they keep the lighter
    /// half-height opening and can still be dragged to full height.
    func ewDetailSheetPresentation() -> some View {
        presentationDetents([.medium, .large])
    }
}
