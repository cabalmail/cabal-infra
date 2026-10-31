import SwiftUI

extension View {
    /// Feeds the compose form's laptop arrangement (`ComposeLaptopArrangement`)
    /// and puts it in the environment: the window's fold, the form's own
    /// pieces with the keyboard ignored, the software keyboard, and the
    /// form's scroll. Returns the form to its top as the bars move below the
    /// fold, unless the user just scrolled it. Every modifier here is always
    /// present and changes only its values.
    func readsComposeLaptop(_ laptop: ComposeLaptopArrangement, proxy: ScrollViewProxy) -> some View {
        modifier(ComposeLaptopReader(laptop: laptop, proxy: proxy))
    }

    /// The compose body's laptop height and the padding under it
    /// (`ComposeLaptopPolicy.bodyFrame`), and where the body sits, read
    /// outside both. A nil arrangement (the Mac) is today's natural height.
    func composeLaptopBody(_ laptop: ComposeLaptopArrangement?) -> some View {
        let frame = laptop?.bodyFrame ?? .natural
        return self
            .frame(height: frame.height, alignment: .top)
            .padding(.bottom, frame.bridge)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                laptop?.bodyMoved(frame)
            }
    }

    /// Where the fields start: the From header's top, which the body's
    /// laptop height keeps below the fold.
    func composeLaptopFieldsStart(_ laptop: ComposeLaptopArrangement) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { top in
            laptop.fieldsMoved(top: top)
        }
    }
}

private struct ComposeLaptopReader: ViewModifier {
    let laptop: ComposeLaptopArrangement
    let proxy: ScrollViewProxy
    @Environment(\.foldState) private var fold

    func body(content: Content) -> some View {
        content
            .background {
                Color.clear
                    .onFoldPiecesChange { laptop.piecesChanged($0) }
                    .ignoresSafeArea(.keyboard)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                laptop.scrolled(fromRest: offset)
            }
            .onScrollPhaseChange { _, phase in
                laptop.scrollPhase(phase)
            }
            .onSoftwareKeyboardChange { laptop.keyboardChanged($0) }
            .onChange(of: fold, initial: true) { _, fold in
                laptop.foldChanged(fold)
            }
            .onChange(of: laptop.barsBelowFold) { _, below in
                if below { returnToRest() }
            }
            .environment(\.composeLaptop, laptop)
    }

    /// Scrolls the form back to its top, where the body sits above the
    /// fold and the fields below it: checked at once and again after the
    /// keyboard's settle, since a keyboard the user scrolled away leaves the
    /// form where they put it. With the body first and no taller than the
    /// space above the fold, scrolling its row to the bottom clamps to the
    /// form's top (measured).
    private func returnToRest() {
        guard returns else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard returns else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(ComposeBodyScrollPolicy.bodyScrollTarget, anchor: .bottom)
            }
        }
    }

    private var returns: Bool {
        ComposeLaptopPolicy.returnsToRest(
            host: laptop.host, isScrolling: laptop.isScrolling, sinceUserScroll: laptop.secondsSinceUserScroll
        )
    }
}
