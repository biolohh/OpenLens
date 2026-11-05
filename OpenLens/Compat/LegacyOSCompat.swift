import SwiftUI

// MARK: - iOS 18 back-deploy shims (wonded ios18 branch)
//
// Upstream OpenLens targets iOS 26 and uses Liquid Glass APIs directly. This
// branch lowers the deployment target to iOS 18 and routes every iOS 26-only
// call through these wrappers: on iOS 26+ they forward to the real API, so the
// app looks identical there; on iOS 18 they fall back to the closest pre-glass
// look (materials, bordered buttons, safe-area insets).
//
// When merging upstream, re-run:
//   grep -rnE "glassEffect|GlassEffectContainer|scrollEdgeEffect|sharedBackgroundVisibility|safeAreaBar|glassProminent|\.glass\b" OpenLens
// and route any new hit through a wrapper here.

extension View {
    /// `glassEffect(_:in:)` on iOS 26+, an ultra-thin material on earlier systems.
    @ViewBuilder
    func compatGlassEffect<S: Shape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(LegacyGlass.make(tint: tint, interactive: interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint {
                        shape.fill(tint)
                    }
                    shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
            }
        }
    }

    /// `scrollEdgeEffectStyle(.soft, for:)` on iOS 26+; no-op earlier (iOS 18 has no edge effect).
    @ViewBuilder
    func compatSoftScrollEdge(for edges: Edge.Set) -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }

    /// `safeAreaBar` on iOS 26+, `safeAreaInset` earlier (same layout, no edge blur).
    @ViewBuilder
    func compatSafeAreaBar<Bar: View>(
        edge: VerticalEdge,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Bar
    ) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: edge, alignment: alignment, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
        }
    }

    /// `.buttonStyle(.glassProminent)` on iOS 26+, `.borderedProminent` earlier.
    @ViewBuilder
    func compatGlassProminentButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

extension ToolbarContent {
    /// `sharedBackgroundVisibility(.hidden)` on iOS 26+. Before iOS 26 toolbar
    /// items have no shared glass background, so there is nothing to hide.
    @ToolbarContentBuilder
    func compatHiddenSharedBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// `GlassEffectContainer` on iOS 26+; on earlier systems the content is shown as is
/// (glass shapes cannot merge without Liquid Glass).
struct CompatGlassEffectContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

@available(iOS 26.0, *)
private enum LegacyGlass {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

/// `Button(role: .close)` on iOS 26+ (system X glyph, glass); before iOS 26 the
/// close role does not exist, so it draws the same X as a plain toolbar button.
struct CompatCloseButton: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            }
            .accessibilityLabel("Close")
        }
    }
}
