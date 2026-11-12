#if canImport(SwiftUI)
import SwiftUI

/// Supported declarative renderer, including optional per-layer design settings.
/// Existing native flows remain controlled by the host app.
public struct AplynaFlowView: View {
    private let configuration: AplynaConfiguration
    private let onViewed: (String) -> Void
    private let onStepCompleted: (String) -> Void
    private let onComplete: () -> Void
    @State private var index = 0

    public init(configuration: AplynaConfiguration, onViewed: @escaping (String) -> Void, onStepCompleted: @escaping (String) -> Void = { _ in }, onComplete: @escaping () -> Void) {
        self.configuration = configuration
        self.onViewed = onViewed
        self.onStepCompleted = onStepCompleted
        self.onComplete = onComplete
    }
    public var body: some View {
        if configuration.mode == "visual", configuration.steps.indices.contains(index) {
            let step = configuration.steps[index]
            let padding = step.design?.padding?.edgeInsets ?? EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24)
            let art = ElementStyle(step: step, layer: .art)
            let title = ElementStyle(step: step, layer: .title)
            let body = ElementStyle(step: step, layer: .body)
            let button = ElementStyle(step: step, layer: .button)
            GeometryReader { geometry in
                let width = max(0, geometry.size.width - padding.leading - padding.trailing)
                ScrollView {
                    VStack(spacing: step.design?.gap ?? 18) {
                        if step.design?.showProgress ?? true {
                            HStack(spacing: 5) {
                                ForEach(configuration.steps.indices, id: \.self) { i in
                                    Capsule().fill(i <= index ? Color(hex: "#8B9687") : Color(hex: "#E7EAE5")).frame(height: 3)
                                }
                            }.padding(.bottom, 6)
                        }
                        if let layout = step.layout {
                            LayoutNodeView(node: layout, step: step, availableWidth: width, availableHeight: max(0, geometry.size.height - padding.top - padding.bottom - ((step.design?.showProgress ?? true) ? 27 : 0)), root: true, action: {
                                onStepCompleted(step.id)
                                if index + 1 < configuration.steps.count { index += 1 } else { onComplete() }
                            })
                        } else {
                        StyledElement(style: art, availableWidth: width) {
                            Image(systemName: symbol(step.symbol))
                                .font(.system(size: 106, weight: .ultraLight))
                                .accessibilityHidden(true)
                        }
                        StyledElement(style: title, availableWidth: width) {
                            styledText(step.title, style: title)
                        }
                        StyledElement(style: body, availableWidth: width) {
                            styledText(step.body, style: body)
                        }
                        Spacer(minLength: 0)
                        StyledElement(style: button, availableWidth: width, action: {
                            onStepCompleted(step.id)
                            if index + 1 < configuration.steps.count { index += 1 } else { onComplete() }
                        }) {
                            HStack(spacing: 10) {
                                styledText(step.button, style: button)
                                    .frame(maxWidth: button.width == .fit ? nil : .infinity, alignment: button.textFrameAlignment)
                                Image(systemName: "arrow.right").font(.system(size: 18))
                            }
                        }
                        }
                    }
                    .frame(minHeight: max(0, geometry.size.height - padding.top - padding.bottom))
                    .padding(padding)
                }.background(designFill(step.design?.background ?? "#FFFFFF", gradient: step.design?.gradient))
            }
            .onAppear { onViewed(step.id) }
            .onChange(of: index) { _ in onViewed(configuration.steps[index].id) }
        }
    }
    private func styledText(_ value: String, style: ElementStyle) -> some View {
        Text(value)
            .underline(style.underline)
            .strikethrough(style.strikethrough)
            .kerning(style.letterSpacing)
            .font(style.font)
            .foregroundStyle(Color(hex: style.color))
            .multilineTextAlignment(style.textAlignment)
            .lineSpacing(style.fontSize * (style.lineHeight - 1))
            .frame(minHeight: style.fontSize * style.lineHeight)
            .fixedSize(horizontal: style.width == .fit, vertical: style.height == .fit)
    }
    private func symbol(_ value: String) -> String {
        ["leaf": "leaf", "sparkles": "sparkles", "heart": "heart", "chart": "chart.xyaxis.line", "check": "checkmark.circle"][value] ?? "sparkles"
    }
}
private enum Layer { case art, title, body, button }
private struct ElementStyle {
    var width: AplynaDimension = .fill
    var height: AplynaDimension = .fit
    var align = "center"
    var margin = EdgeInsets()
    var padding = EdgeInsets()
    var fontFamily = "system"
    var fontSize: Double = 16
    var fontWeight = 400
    var lineHeight = 1.5
    var textAlign = "center"
    var color = "#202720"
    var background = "transparent"
    var radius: Double = 0
    var opacity: Double = 1
    var minWidth: Double? = nil
    var maxWidth: Double? = nil
    var minHeight: Double? = nil
    var maxHeight: Double? = nil
    var fontStyle = "normal"
    var underline = false
    var strikethrough = false
    var letterSpacing: Double = -0.3
    var shape = "rectangle"
    var gradient: AplynaGradient? = nil
    var border: AplynaBorder? = nil
    var shadow: AplynaShadow? = nil
    var badge: AplynaBadge? = nil


    init(step: AplynaStep, layer: Layer) {
        let design: AplynaElementDesign?
        switch layer {
        case .art:
            height = .fixed(260); padding = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
            margin.bottom = 12; background = step.accent; color = "#4B5A4E"; radius = 24
            design = step.design?.layers?.art
        case .title:
            fontSize = 34; fontWeight = 600; lineHeight = 1.2
            design = step.design?.layers?.title
        case .body:
            fontSize = 15; lineHeight = 1.6; color = "#7D847B"
            design = step.design?.layers?.body
        case .button:
            fontSize = 16; fontWeight = 600; lineHeight = 1.3; color = "#FFFFFF"; background = "#202720"; radius = 14
            padding = EdgeInsets(top: 17, leading: 20, bottom: 17, trailing: 20)
            design = step.design?.layers?.button
        }
        apply(design)
    }
    init(step: AplynaStep, node: AplynaLayoutNode) {
        if node.type == "stack" || node.type == "spacer" {
            apply(node.design)
        } else {
            let layer: Layer = node.type == "illustration" ? .art : node.type == "button" ? .button : node.role == "headline" ? .title : .body
            // Layout elements carry their own styling; legacy layer overrides
            // belong only to the original fixed-layout renderer.
            self = ElementStyle(defaultLayer: layer, accent: step.accent)
            apply(node.design)
        }
    }
    private init(defaultLayer: Layer, accent: String) {
        switch defaultLayer {
        case .art: height = .fixed(260); padding = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24); margin.bottom = 12; background = accent; color = "#4B5A4E"; radius = 24
        case .title: fontSize = 34; fontWeight = 600; lineHeight = 1.2
        case .body: fontSize = 15; lineHeight = 1.6; color = "#7D847B"
        case .button: fontSize = 16; fontWeight = 600; lineHeight = 1.3; color = "#FFFFFF"; background = "#202720"; radius = 14; padding = EdgeInsets(top: 17, leading: 20, bottom: 17, trailing: 20)
        }
    }
    mutating func apply(_ design: AplynaElementDesign?) {
        guard let design else { return }
        width = design.width ?? width; height = design.height ?? height; align = design.align ?? align
        margin = design.margin?.edgeInsets ?? margin; padding = design.padding?.edgeInsets ?? padding
        fontFamily = design.fontFamily ?? fontFamily; fontSize = design.fontSize ?? fontSize
        fontWeight = design.fontWeight ?? fontWeight; lineHeight = design.lineHeight ?? lineHeight
        textAlign = design.textAlign ?? textAlign; color = design.color ?? color
        background = design.background ?? background; radius = design.radius ?? radius; opacity = design.opacity ?? opacity
        minWidth = design.minWidth; maxWidth = design.maxWidth; minHeight = design.minHeight; maxHeight = design.maxHeight
        fontStyle = design.fontStyle ?? fontStyle; underline = design.underline ?? underline
        strikethrough = design.strikethrough ?? strikethrough; letterSpacing = design.letterSpacing ?? letterSpacing
        shape = design.shape ?? shape; gradient = design.gradient; border = design.border; shadow = design.shadow; badge = design.badge

    }
    var font: Font {
        let value = Font.system(size: fontSize, weight: weight, design: fontDesign)
        return fontStyle == "italic" ? value.italic() : value
    }
    var cornerRadius: Double { shape == "pill" ? 9999 : radius }
    var fill: AnyShapeStyle { designFill(background, gradient: gradient) }
    func fillWidth(_ available: Double) -> Double { max(minWidth ?? 0, min(available, maxWidth ?? available)) }
    func fillHeight(_ available: Double) -> Double { max(minHeight ?? 0, min(available, maxHeight ?? available)) }
    var weight: Font.Weight { [300: .light, 400: .regular, 500: .medium, 600: .semibold, 700: .bold][fontWeight] ?? .regular }
    var fontDesign: Font.Design { fontFamily == "serif" ? .serif : fontFamily == "rounded" ? .rounded : .default }
    var textAlignment: TextAlignment { textAlign == "left" ? .leading : textAlign == "right" ? .trailing : .center }
    var textFrameAlignment: Alignment { textAlign == "left" ? .leading : textAlign == "right" ? .trailing : .center }
    var frameAlignment: Alignment { align == "left" ? .leading : align == "right" ? .trailing : .center }
}
private struct LayoutNodeView: View {
    let node: AplynaLayoutNode
    let step: AplynaStep
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    var parentDirection = "vertical"
    var root = false
    let action: () -> Void
    private var style: ElementStyle { ElementStyle(step: step, node: node) }
    private var width: CGFloat? {
        let available = max(0, availableWidth - style.margin.leading - style.margin.trailing)
        switch style.width { case .fill: return style.fillWidth(available); case .fit: return nil; case .fixed(let value): return min(value, available) }
    }
    private var height: CGFloat? {
        switch style.height { case .fixed(let value): return value; case .fill: return style.fillHeight(max(0, availableHeight - style.margin.top - style.margin.bottom)); case .fit: return nil }
    }
    private var horizontal: Bool { node.direction == "horizontal" }
    private var alignment: Alignment {
        if horizontal { return node.align == "start" ? .top : node.align == "end" ? .bottom : .center }
        return node.align == "start" ? .leading : node.align == "end" ? .trailing : .center
    }
    private var expands: Bool { horizontal ? style.width != .fit : style.height != .fit || root }
    private var hasFlexibleSpace: Bool {
        (node.children ?? []).contains { child in
            if child.type == "spacer" { return child.grow ?? true }
            let design = ElementStyle(step: step, node: child)
            return horizontal ? design.width == .fill : design.height == .fill
        }
    }
    var body: some View {
        if node.type == "spacer" {
            if parentDirection == "horizontal" {
                if node.grow ?? true { Spacer(minLength: node.size ?? 0) } else { Color.clear.frame(width: node.size ?? 0, height: 1) }
            } else {
                if node.grow ?? true { Spacer(minLength: node.size ?? 0) } else { Color.clear.frame(height: node.size ?? 0) }
            }
        } else {
            content
                .font(style.font)
                .foregroundStyle(Color(hex: style.color))
                .multilineTextAlignment(style.textAlignment)
                .padding(style.padding)
                .frame(width: width, height: height, alignment: node.type == "stack" ? alignment : style.textFrameAlignment)
                .modifier(ElementAppearance(style: style))
                .opacity(style.opacity)
                .padding(style.margin)
        }
    }
    @ViewBuilder private var content: some View {
        switch node.type {
        case "stack":
            if node.direction == "overlay" {
                ZStack(alignment: alignment) { children }
            } else if horizontal {
                HStack(alignment: node.align == "start" ? .top : node.align == "end" ? .bottom : .center, spacing: node.gap ?? 12) { distributedChildren }
            } else {
                VStack(alignment: node.align == "start" ? .leading : node.align == "end" ? .trailing : .center, spacing: node.gap ?? 12) { distributedChildren }
            }
        case "text": Text(node.text ?? "").underline(style.underline).strikethrough(style.strikethrough).kerning(style.letterSpacing).lineSpacing(style.fontSize * (style.lineHeight - 1)).fixedSize(horizontal: false, vertical: style.height == .fit)
        case "button": Button(action: action) { HStack(spacing: 10) { Text(node.text ?? "Continue").underline(style.underline).strikethrough(style.strikethrough).kerning(style.letterSpacing).frame(maxWidth: .infinity, alignment: style.textFrameAlignment); Image(systemName: "arrow.right") } }.buttonStyle(.plain)
        case "illustration": Image(systemName: ["leaf":"leaf", "heart":"heart", "chart":"chart.xyaxis.line", "check":"checkmark.circle"][node.symbol ?? ""] ?? "sparkles").font(.system(size: 106, weight: .ultraLight)).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
        default: EmptyView()
        }
    }
    @ViewBuilder private var distributedChildren: some View {
        if expands && !hasFlexibleSpace && ["center", "end"].contains(node.justify ?? "start") { Spacer(minLength: 0) }
        let values = node.children ?? []
        ForEach(Array(values.enumerated()), id: \.element.id) { index, child in
            childView(child)
            if expands && !hasFlexibleSpace && node.justify == "space-between" && index < values.count - 1 { Spacer(minLength: 0) }
        }
        if expands && !hasFlexibleSpace && ["start", "center"].contains(node.justify ?? "start") { Spacer(minLength: 0) }
    }
    @ViewBuilder private var children: some View { ForEach(node.children ?? []) { child in childView(child) } }
    private func childView(_ child: AplynaLayoutNode) -> AnyView {
        let children = node.children ?? [], innerWidth = max(0, (width ?? availableWidth) - style.padding.leading - style.padding.trailing)
        let innerHeight = max(0, (height ?? availableHeight) - style.padding.top - style.padding.bottom)
        var childWidth = innerWidth
        if horizontal {
            let fixed = children.reduce(0.0) { sum, value in
                let design = ElementStyle(step: step, node: value)
                if case .fixed(let width) = design.width { return sum + width + design.margin.leading + design.margin.trailing }
                return sum
            }
            let flexible = max(1, children.filter { value in if value.type == "spacer" { return value.grow ?? true }; return ElementStyle(step: step, node: value).width == .fill }.count)
            if ElementStyle(step: step, node: child).width == .fill { childWidth = max(0, (innerWidth - fixed - Double(max(0, children.count - 1)) * (node.gap ?? 12)) / Double(flexible)) }
        }
        return AnyView(LayoutNodeView(node: child, step: step, availableWidth: childWidth, availableHeight: innerHeight, parentDirection: node.direction ?? "vertical", action: action))
    }
}
private struct StyledElement<Content: View>: View {
    let style: ElementStyle
    let availableWidth: CGFloat
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    private var width: CGFloat? {
        let available = max(0, availableWidth - style.margin.leading - style.margin.trailing)
        switch style.width {
        case .fill: return style.fillWidth(available)
        case .fit: return nil
        case .fixed(let width): return min(width, available)
        }
    }
    private var height: CGFloat? {
        if case .fixed(let height) = style.height { return height }
        return nil
    }
    var body: some View {
        Group {
            if let action { Button(action: action) { styledContent }.buttonStyle(.plain) }
            else { styledContent }
        }
        .padding(style.margin)
        .frame(maxWidth: .infinity, alignment: style.frameAlignment)
    }
    private var styledContent: some View {
        content()
            .foregroundStyle(Color(hex: style.color))
            .padding(style.padding)
            .frame(width: width, height: height, alignment: style.textFrameAlignment)
            .modifier(ElementAppearance(style: style))
            .opacity(style.opacity)
            .contentShape(Rectangle())
    }
}
private func designFill(_ background: String, gradient: AplynaGradient?) -> AnyShapeStyle {
    guard let gradient else { return AnyShapeStyle(Color(hex: background)) }
    let radians = gradient.angle * .pi / 180
    return AnyShapeStyle(LinearGradient(colors: [Color(hex: gradient.start), Color(hex: gradient.end)],
        startPoint: UnitPoint(x: 0.5 - sin(radians) / 2, y: 0.5 + cos(radians) / 2),
        endPoint: UnitPoint(x: 0.5 + sin(radians) / 2, y: 0.5 - cos(radians) / 2)))
}
private struct ElementAppearance: ViewModifier {
    let style: ElementStyle
    func body(content: Content) -> some View {
        content
            .background(style.fill)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: style.cornerRadius)
                .strokeBorder(Color(hex: style.border?.color ?? "#00000000"), lineWidth: style.border?.width ?? 0))
            .shadow(color: Color(hex: style.shadow?.color ?? "#00000000"), radius: (style.shadow?.blur ?? 0) / 2,
                x: style.shadow?.x ?? 0, y: style.shadow?.y ?? 0)
            .overlay(alignment: style.badge?.position == "start" ? .topLeading : style.badge?.position == "end" ? .topTrailing : .top) {
                if let badge = style.badge {
                    Text(badge.text).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: badge.color)).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color(hex: badge.background), in: Capsule())
                        .padding(.horizontal, 8).offset(y: -10)
                }
            }
    }
}
private extension AplynaInsets {
    var edgeInsets: EdgeInsets { EdgeInsets(top: top, leading: left, bottom: bottom, trailing: right) }
}
private extension Color {
    init(hex: String) {
        if hex == "transparent" { self = .clear; return }
        let digits = String(hex.dropFirst()), number = UInt64(digits, radix: 16) ?? 0xdce8dd
        let rgba = digits.count == 8, shift: UInt64 = rgba ? 8 : 0
        self.init(red: Double((number >> (16 + shift)) & 255) / 255, green: Double((number >> (8 + shift)) & 255) / 255, blue: Double((number >> shift) & 255) / 255, opacity: rgba ? Double(number & 255) / 255 : 1)
    }
}
#endif
