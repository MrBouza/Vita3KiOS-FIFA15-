// Vita3K project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

import SwiftUI

/// Hinoki's brand: cypress green and paper, and the mark (three hinoki scale leaves, the centre one with
/// the Y found under real hinoki leaves). Drawn in code so it stays sharp at any size; the same geometry as
/// dist/image/hinoki-mark.svg (a 100-unit square, the mark scaled to 72%).
enum HinokiBrand {
    static let cypress = Color(red: 0x22 / 255, green: 0x39 / 255, blue: 0x2E / 255)
    static let paper = Color(red: 0xF1 / 255, green: 0xE6 / 255, blue: 0xD2 / 255)

    /// One leaf, base at (50, 84), tip at (50, 16)
    static var leaf: Path {
        var path = Path()
        path.move(to: CGPoint(x: 50, y: 16))
        path.addCurve(to: CGPoint(x: 50, y: 84), control1: CGPoint(x: 65, y: 33), control2: CGPoint(x: 65, y: 67))
        path.addCurve(to: CGPoint(x: 50, y: 16), control1: CGPoint(x: 35, y: 67), control2: CGPoint(x: 35, y: 33))
        path.closeSubpath()
        return path
    }

    /// A side leaf: 70% size, turned by `degrees` about the shared base
    static func sideLeaf(_ degrees: Double) -> Path {
        let transform = CGAffineTransform(translationX: 50, y: 84)
            .rotated(by: degrees * .pi / 180)
            .scaledBy(x: 0.7, y: 0.7)
            .translatedBy(x: -50, y: -84)
        return leaf.applying(transform)
    }

    static var y: Path {
        var path = Path()
        path.move(to: CGPoint(x: 50, y: 67))
        path.addLine(to: CGPoint(x: 50, y: 53))
        path.addLine(to: CGPoint(x: 44, y: 45))
        path.move(to: CGPoint(x: 50, y: 53))
        path.addLine(to: CGPoint(x: 56, y: 45))
        return path
    }
}

/// The mark on its own (on a cypress tile by default, like the app icon)
struct HinokiMark: View {
    var ground: Color = HinokiBrand.cypress
    var mark: Color = HinokiBrand.paper
    var tile = true

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            if tile {
                context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: side * 0.225, style: .continuous),
                             with: .color(ground))
            }
            // 100-unit square, the mark at 72% around the centre
            let unit = side / 100
            context.translateBy(x: side / 2, y: side / 2)
            context.scaleBy(x: unit * 0.72, y: unit * 0.72)
            context.translateBy(x: -50, y: -50)
            let edge = StrokeStyle(lineWidth: 4, lineJoin: .round)
            for degrees in [-40.0, 40.0] {
                let side = HinokiBrand.sideLeaf(degrees)
                context.fill(side, with: .color(mark))
                context.stroke(side, with: .color(ground), style: StrokeStyle(lineWidth: 4.2, lineJoin: .round))
            }
            context.fill(HinokiBrand.leaf, with: .color(mark))
            context.stroke(HinokiBrand.leaf, with: .color(ground), style: edge)
            context.stroke(HinokiBrand.y, with: .color(ground), style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The mark and the wordmark side by side
struct HinokiLockup: View {
    var markSize: CGFloat = 44

    var body: some View {
        HStack(spacing: markSize * 0.3) {
            HinokiMark()
                .frame(width: markSize, height: markSize)
            VStack(alignment: .leading, spacing: 1) {
                Text("hinoki")
                    .font(.system(size: markSize * 0.62, weight: .semibold))
                    .kerning(-markSize * 0.02)
                Text("PS Vita emulator · built on Vita3K")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hinoki, PS Vita emulator built on Vita3K")
    }
}
