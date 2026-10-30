//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI


struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Picker("Panel", selection: Binding(
            get: { coordinator.currentView },
            set: { view in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    coordinator.currentView = view
                }
            }
        )) {
            Text("Home").tag(NotchViews.home)
            if Defaults[.boringShelf] {
                Text("Shelf").tag(NotchViews.shelf)
            }
            Text("Usage").tag(NotchViews.usage)
            Text("Timer").tag(NotchViews.timer)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .font(.system(size: 12))
        .frame(height: 28)
        .fixedSize(horizontal: true, vertical: false)
        .help("Switch between Home, Shelf, Oh My Pi usage and the session timer")
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
