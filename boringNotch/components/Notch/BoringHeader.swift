//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var body: some View {
        HStack(spacing: 0) {
            TabSelectionView()
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: vm.closedNotchSize.width)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                    OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                } else {
                    if Defaults[.showMirror] {
                        Button {
                            vm.toggleCameraPreview()
                        } label: {
                            Label("Camera mirror", systemImage: "web.camera")
                                .labelStyle(.iconOnly)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Show or hide the camera mirror")
                        .accessibilityValue(vm.isCameraExpanded ? "Shown" : "Hidden")
                    }
                    if Defaults[.settingsIconInNotch] {
                        Button {
                            SettingsWindowController.shared.showWindow()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                                .labelStyle(.iconOnly)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Open Browww settings")
                    }
                    if Defaults[.showBatteryIndicator] {
                        BoringBatteryView(
                            batteryWidth: 30,
                            isCharging: batteryModel.isCharging,
                            isInLowPowerMode: batteryModel.isInLowPowerMode,
                            isPluggedIn: batteryModel.isPluggedIn,
                            levelBattery: batteryModel.levelBattery,
                            maxCapacity: batteryModel.maxCapacity,
                            timeToFullCharge: batteryModel.timeToFullCharge,
                            isForNotification: false
                        )
                    }
                }
            }
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
