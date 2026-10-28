//  MadeByFooter.swift: the "Made by" credit (pixel portrait, name and profile link) in Settings and the popover.
//
//  SPDX-License-Identifier: MIT
//  Copyright (c) 2026 Yahya Elghobashy

import AppKit
import SwiftUI

/// Who made the app, and where the credit links.
enum MadeBy {
    static let name = "Yahya Elghobashy"
    static let profileURL = URL(string: "https://github.com/YahyaElghobashy")!
    static let profileLabel = "github.com/YahyaElghobashy"
}

/// Settings footer: pixel portrait, name and link. Clicking opens `MadeBy.profileURL`.
/// `.card` closes a Settings or About pane; `.inline` fits tight panels and sidebars.
/// A status menu can carry `MadeBy.menuItem()` instead.
struct MadeByFooter: View {
    enum Style { case card, inline }

    var style: Style = .card

    @Environment(\.openURL) private var openURL
    @MadeByLocal private var hovering = false

    var body: some View {
        Button {
            openURL(MadeBy.profileURL)
        } label: {
            label
        }
        .buttonStyle(MadeByPressStyle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.16)) { hovering = inside }
            if #unavailable(macOS 15.0) {
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .madeByLinkPointer()
        .help(MadeBy.profileLabel)
        .accessibilityLabel(Text(verbatim: "Made by \(MadeBy.name)"))
        .accessibilityHint(Text(verbatim: "Opens \(MadeBy.profileLabel) in your browser"))
        .accessibilityAddTraits(.isLink)
    }

    @ViewBuilder private var label: some View {
        switch style {
        case .card:
            HStack(spacing: 12) {
                MadeByAvatar(size: 44, winking: hovering)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "MADE BY")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: MadeBy.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(verbatim: MadeBy.profileLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                arrow
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.075 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(hovering ? 0.16 : 0.08), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .inline:
            HStack(spacing: 7) {
                MadeByAvatar(size: 22, winking: hovering)
                (Text(verbatim: "Made by ").foregroundColor(.secondary)
                    + Text(verbatim: MadeBy.name).fontWeight(.semibold))
                    .font(.system(size: 11))
                    .lineLimit(1)
                arrow
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: style == .card ? 11 : 9, weight: .bold))
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            .offset(x: hovering ? 1.5 : 0, y: hovering ? -1.5 : 0)
            .accessibilityHidden(true)
    }
}

extension MadeByFooter {
    /// For AppKit screens: `stack.addArrangedSubview(MadeByFooter.hostingView())`.
    @preconcurrency @MainActor static func hostingView(style: Style = .card) -> NSView {
        let view = NSHostingView(rootView: MadeByFooter(style: style))
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}

extension MadeBy {
    /// Status-menu item, for a menu with no Settings window beside it: the portrait, "Made by …", a hover wink,
    /// and a click that opens `profileURL` and closes the menu. Add it as the menu's last item.
    /// It is a custom view because macOS 26+ menus no longer draw `NSMenuItem.image`.
    @preconcurrency @MainActor static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Made by \(name)",
                              action: #selector(MadeByMenuTarget.openProfile(_:)), keyEquivalent: "")
        item.target = MadeByMenuTarget.shared
        item.toolTip = profileLabel
        item.view = MadeByMenuItemView()
        return item
    }
}

@MainActor private final class MadeByMenuTarget: NSObject {
    static let shared = MadeByMenuTarget()

    @objc func openProfile(_ sender: Any?) {
        NSWorkspace.shared.open(MadeBy.profileURL)
    }
}

/// The menu row, drawn in AppKit: while a menu tracks the mouse, it reports hover only as the item's
/// highlight plus a redraw, and SwiftUI views would not refresh until the menu closes.
@MainActor private final class MadeByMenuItemView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel("Made by \(MadeBy.name)")
        setAccessibilityHelp("Opens \(MadeBy.profileLabel) in your browser")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        let row = bounds.insetBy(dx: 5, dy: 1)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
        }

        let avatar = NSRect(x: row.minX + 9, y: (row.midY - 11).rounded(), width: 22, height: 22)
        if let image = highlighted ? MadeByArt.wink : MadeByArt.face {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .none
            NSBezierPath(roundedRect: avatar, xRadius: 5.3, yRadius: 5.3).addClip()
            image.draw(in: avatar)
            NSGraphicsContext.restoreGraphicsState()
        }

        let font = NSFont.menuFont(ofSize: 0)
        let ink: NSColor = highlighted ? .white : .labelColor
        let text = NSMutableAttributedString(string: "Made by ", attributes: [
            .font: font, .foregroundColor: highlighted ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor])
        text.append(NSAttributedString(string: MadeBy.name, attributes: [
            .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold), .foregroundColor: ink]))
        let size = text.size()
        text.draw(at: NSPoint(x: avatar.maxX + 8, y: (row.midY - size.height / 2).rounded()))

        let arrowConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [highlighted ? .white : .secondaryLabelColor]))
        if let arrow = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(arrowConfig) {
            arrow.draw(in: NSRect(x: row.maxX - 10 - arrow.size.width, y: (row.midY - arrow.size.height / 2).rounded(),
                                  width: arrow.size.width, height: arrow.size.height))
        }
    }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        NSWorkspace.shared.open(MadeBy.profileURL)
    }

    override func accessibilityPerformPress() -> Bool {
        enclosingMenuItem?.menu?.cancelTracking()
        NSWorkspace.shared.open(MadeBy.profileURL)
        return true
    }
}

/// The pixel portrait on its space tile. Winks while the footer is hovered.
struct MadeByAvatar: View {
    var size: CGFloat = 44
    var winking = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let corner = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        Group {
            if let image = winking ? MadeByArt.wink : MadeByArt.face {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(crisp ? .none : .medium)
            } else {
                Color(red: 0.34, green: 0.19, blue: 0.54)
            }
        }
        .frame(width: size, height: size)
        .clipShape(corner)
        .overlay(corner.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    /// Whole device pixels per art cell keep nearest-neighbour sharp; anything else is smoothed.
    private var crisp: Bool {
        let perCell = size * displayScale / MadeByArt.cells
        return perCell >= 1 && abs(perCell - perCell.rounded()) < 0.01
    }
}

/// `@State` without the macro: the macOS 26+/27 SDKs make the `@State` attribute an Xcode-only
/// macro, and this app builds with the Command Line Tools. Same storage, different spelling.
@propertyWrapper
private struct MadeByLocal<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        storage = SwiftUI.State(wrappedValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
}

private struct MadeByPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private extension View {
    @ViewBuilder func madeByLinkPointer() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }
}

/// 44 x 44 pixel art, one cell per pixel: two PNGs (portrait and wink), embedded below.
@MainActor enum MadeByArt {
    static let cells: CGFloat = 44
    static let face = decode(faceBase64)
    static let wink = decode(winkBase64)

    private static func decode(_ base64: String) -> NSImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }

    // BEGIN ART: base64 PNGs, do not hand-edit.
    private static let faceBase64 = "iVBORw0KGgoAAAANSUhEUgAAACwAAAAsCAMAAAApWqozAAAAUVBMVEVqP6MJCArNvv8lHBwuKCsXExYlHyH///9vtTK48npWMIpfSz5vTzieclDvqnTRlWaEWz7Ei19DJHC4g1v/6aj39PIbEhAyGVfV1daZmJgjED+FsAn8AAAChElEQVQ4y6WV7ZajIAyGzZBgtxA+hnHs7v1f6L5Bbau1sz8251hTeXgJIcZh+D8jov2Dj59Q52ig4d9GxOKYHXnZPR9PPGI22G4sr/HsZIU7hcs5FkyR9zi5hTRIVlfkFb90llaWMa3rL+pH9tdlIM8k0sU9fC+2TbLfB33tdrmaBgYsFVjaZiIz8BE9XVcbNgd6wL0lDRgJBAX/LTO+0x87WJx3nvaGwD0iPyhDAyGD5SARgSgMlMWFNQ6w4768aHoy7YFjghyUkVonvGNTyhHzLY+HDULDQzfb+l0VllO2svJb0I8NWpJyZA+LKUW7c0yFkIxjzFdkVhRI33/N0h0f1BJyhz9Xw+lRDVFby7Wl1GpuqjEknJSjlQH8tdKOcmo6Ta1ZzOYpPDskGx4XeJNmyRkEmIw8bF7wd+FnWDjFafr+niZssGxe9PJ5AtMDLo9pUegVJo2c+trTVOLmKWDlF5hbDX11sLaxxUPCazyBE/KEgyulJK2LZ0cZQzuFOa8lgQ3WrTw45Ac8wz5wcS7ciZwT1GtaZmbWxsZ84epwt5gCllWrpFqr4vwa/lfUyx15wLMT7KeEgGqDqZaA2FXcfAbPs9bW6Ha7/YbhRlVzo/kNHDAYGOA4YkJgFFOc38GMksthXJTHALbyWxjSLeWiNwul5FzrTvgAS0Qi8vpKISPF/QDPFBV6Goulr0Xajw5/ng2NA4eQG94TZJlR+LvhHWwtMXLsqlo4WMd7B/f+qjm4GEvgUNXaF53DZC+0taTeO1Anap3X0yks1sCF2r15Le1fTmBspn8ZxMW1TmV7QEdYli+PWDfuLdT6+frkLr7A23cKXUnEW+fvN7GPxfJB6thfLPpXkX5zaoMAAAAASUVORK5CYII="
    private static let winkBase64 = "iVBORw0KGgoAAAANSUhEUgAAACwAAAAsCAMAAAApWqozAAAAVFBMVEVqP6MJCArNvv8lHBwuKCsXExYlHyH///9vtTK48npWMIpfSz5vTzieclDvqnTRlWaEWz7Ei19DJHC4g1v/6aj39PIqGhQbEhAyGVfV1daZmJgjED+qfL0UAAACiUlEQVQ4y6WV7XrbIAyFrSKRLCA+Sp062/3f546wncSO0/2YnroQ83KQBBbD8H9GRNsXHz+hztFAw7+NiMUxO/KyeX866BGzwdawvPqzkRXuFB7nWDBF3uPkZtIgWboir/i5s7SwjGldf1bfs7/OA3kmkS7u0fdiYZL9f9CXbueLaWDAUoGlbSYygz68p8tiw9qBHnBvSQNGAkHBb8uM7/THBhbnnaetwXEPz3fK0IDLYDlIhCMKA2V+YY0d7LgvL5qeTLvjmCA7ZaTWCW/YlHLEfMvjLkBoeOhmW7+rwnLKdqz86vQjQEtSjuxhMaVoLcdUCMnY+3xBZkWB9Phrlt7xQS0hd/hzMewe1RC1tVxbSq3mphpDwk45WhjAXwvtKKem49jac4y2STZ8muFVmiVnsOOIwBL+rldrgr8LP8PCKY7j9/c4IsCSgF5TRKTyeQDTAy4pXs2HK2ChV5g0cupejGOJadkdBaz8AnOrAat3Vp9CjDUewAl5glQpJWmdeyYfQzuEOa9qKdVVmUN+wBPsAw/nwp3IOUG9pnlmZm1szBeeDneLKWBZtZNUa1XsX8PvivNyRx7w5KQgwhBw2mCqJcB3FTcdwdOktTW63W6/YWioam40vYEDBgMDPJ0wITAOU5zewYwjl8NpVj4FsJXfwpBuKRe9mSsl51o3wjtYIhKRl08KGSnuB3iiqNDTWCx9LdJ2dPjzbCgc2ITc8J0gy4yDvxnewFYSI8euqoWDVbx3cK+vmoOLsQQOVa180TFM9kFbSeq1A+dErfJ6OoTFCrjQ/SzrXP7lAEYw/WYQF5dzKusL2sMy3zxi1biXUKvny5u7+Ayv9xSqkoi3yt8bsctivpA69hc8vFhxw/4qwAAAAABJRU5ErkJggg=="
    // END ART
}
