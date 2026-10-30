//
//  HoverButton.swift
//  boringNotch
//
//  Created by Kraigo on 04.09.2024.
//

import SwiftUI

struct HoverButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var icon: String
    var label: String
    var help: String
    var value: String?
    var iconColor: Color = .primary
    var scale: Image.Scale = .medium
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let size = CGFloat(scale == .large ? 40 : 30)

        Button(action: action) {
            Image(systemName: icon)
                .font(scale == .large ? .title3.weight(.semibold) : .body.weight(.medium))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.12) : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
        }
    }
}
