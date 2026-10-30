//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    let artworkSize: CGFloat
    let albumArtNamespace: Namespace.ID

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace)
                .frame(width: artworkSize, height: artworkSize)
            MusicControlsView()
        }
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Button {
            musicManager.openMusicApp()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                albumArtImage
                appIconOverlay
            }
        }
        .buttonStyle(.plain)
        .help("Open the current media app")
        .accessibilityLabel("Album artwork")
        .accessibilityHint("Opens the current media app")
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        if vm.notchState == .open && !musicManager.usingAppIconForArtwork {
            AppIcon(for: musicManager.bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
        @EnvironmentObject var vm: BoringViewModel
        @ObservedObject var webcamManager = WebcamManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            songInfo
            musicSlider
            slotToolbar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
    }

    private var songInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(musicManager.songTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(musicManager.artistName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            lyrics
        }
    }

    @ViewBuilder
    private var lyrics: some View {
        if Defaults[.enableLyrics] {
            TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                let currentElapsed: Double = {
                    guard musicManager.isPlaying else { return musicManager.elapsedTime }
                    let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                    let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
                    return min(max(progressed, 0), musicManager.songDuration)
                }()
                let line: String = {
                    if musicManager.isFetchingLyrics { return "Loading lyrics…" }
                    if !musicManager.syncedLyrics.isEmpty {
                        return musicManager.lyricLine(at: currentElapsed)
                    }
                    let trimmed = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? "No lyrics found" : trimmed.replacingOccurrences(of: "\n", with: " ")
                }()
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(musicManager.isFetchingLyrics ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(musicManager.isPlaying ? 1 : 0)
                    .accessibilityLabel("Lyrics")
                    .accessibilityValue(line)
            }
        }
    }

    private var musicSlider: some View {
        TimelineView(.animation(minimumInterval: musicManager.playbackRate > 0 ? 0.1 : nil)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, 2)
            .frame(height: 46)
        }
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 4) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                slotView(for: slot)
                    .frame(minWidth: slot == .volume ? 0 : 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        let result = Array(padded.prefix(sanitizedLimit))
        // If calendar and camera are both visible alongside music, hide the edge slots
        let shouldHideEdges = Defaults[.showCalendar] && Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
        if shouldHideEdges && result.count >= 5 {
            return Array(result.dropFirst().dropLast())
        }

        return result
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(
                icon: "shuffle",
                label: "Shuffle",
                help: musicManager.isShuffled ? "Turn shuffle off" : "Turn shuffle on",
                value: musicManager.isShuffled ? "On" : "Off",
                iconColor: musicManager.isShuffled ? .effectiveAccent : .primary
            ) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", label: "Previous track", help: "Play the previous track", value: nil) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(
                icon: musicManager.isPlaying ? "pause.fill" : "play.fill",
                label: musicManager.isPlaying ? "Pause" : "Play",
                help: musicManager.isPlaying ? "Pause playback" : "Start playback",
                value: musicManager.isPlaying ? "Playing" : "Paused",
                scale: .large
            ) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", label: "Next track", help: "Play the next track", value: nil) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(
                icon: repeatIcon,
                label: "Repeat",
                help: "Change repeat mode",
                value: repeatModeLabel,
                iconColor: repeatIconColor
            ) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", label: "Back 15 seconds", help: "Skip back 15 seconds", value: nil) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", label: "Forward 15 seconds", help: "Skip forward 15 seconds", value: nil) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(width: 30, height: 30)
                .accessibilityHidden(true)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatModeLabel: String {
        switch musicManager.repeatMode {
        case .off:
            return "Off"
        case .all:
            return "All tracks"
        case .one:
            return "Current track"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .effectiveAccent
        }
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(
            icon: iconName,
            label: musicManager.isFavoriteTrack ? "Remove favorite" : "Add favorite",
            help: musicManager.isFavoriteTrack ? "Remove this track from favorites" : "Add this track to favorites",
            value: musicManager.isFavoriteTrack ? "Favorite" : "Not favorite",
            iconColor: iconColor
        ) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .effectiveAccent : .primary
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button {
                guard musicManager.volumeControlSupported else { return }
                showVolumeSlider.toggle()
            } label: {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(musicManager.volumeControlSupported ? .primary : .secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!musicManager.volumeControlSupported)
            .help(musicManager.volumeControlSupported ? "Show volume control" : "Volume control is unavailable in the current media app")
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((volumeSliderValue * 100).rounded())) percent")

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .primary,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    },
                    accessibilityLabel: "Volume",
                    accessibilityValue: "\(Int((volumeSliderValue * 100).rounded())) percent",
                    keyboardStep: 0.05
                )
                .frame(width: 64, height: 28)
                .transition(.opacity)
            }
        }
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                showVolumeSlider = false
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        .transition(.opacity)
    }

    private var shouldShowCamera: Bool {
        Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    private var isCalendarVisible: Bool {
        Defaults[.showCalendar]
    }

    private var artworkSize: CGFloat {
        shouldShowCamera && isCalendarVisible ? 90 : isCalendarVisible ? 108 : 120
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 12) {
            MusicPlayerView(artworkSize: artworkSize, albumArtNamespace: albumArtNamespace)
                .frame(minWidth: shouldShowCamera && isCalendarVisible ? 176 : 200, maxWidth: .infinity, alignment: .leading)

            if isCalendarVisible {
                CalendarView()
                    .frame(width: shouldShowCamera ? 140 : 200, height: 166)
                    .onHover { vm.isHoveringCalendar = $0 }
                    .environmentObject(vm)
                    .transition(.opacity)
            }

            if shouldShowCamera {
                CameraPreviewView(webcamManager: webcamManager)
                    .frame(width: 92, height: 92)
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .accessibilityLabel("Camera mirror")
                    .accessibilityHint("Start or stop the camera preview")
                    .transition(.opacity)
            }
        }
        .frame(height: 166, alignment: .top)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .transition(.opacity)
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void


    var body: some View {
        VStack {
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                    : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange,
                accessibilityLabel: "Playback position",
                accessibilityValue: "\(timeString(from: sliderValue)) of \(timeString(from: duration))",
                keyboardStep: 5
            )
            .frame(height: 28, alignment: .center)

            HStack {
                Text(timeString(from: sliderValue))
                Spacer()
                Text(timeString(from: duration))
            }
            .foregroundColor(
                Defaults[.playerColorTinting]
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
            )
            .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .onChange(of: currentDate) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?
    var accessibilityLabel: String = "Value"
    var accessibilityValue: String = ""
    var keyboardStep: Double = 1

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let visualHeight = CGFloat(dragging ? 8 : 4)
            let rangeSpan = range.upperBound - range.lowerBound
            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.32))
                    .frame(height: visualHeight)

                Capsule()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: visualHeight)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .focusable()
            .onMoveCommand(perform: move)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Use the arrow keys to adjust")
            .accessibilityAdjustableAction { direction in
                adjust(direction == .increment ? keyboardStep : -keyboardStep)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard width > 0 else { return }
                        dragging = true
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .down:
            adjust(-keyboardStep)
        case .right, .up:
            adjust(keyboardStep)
        default:
            break
        }
    }

    private func adjust(_ amount: Double) {
        let newValue = min(max(value + amount, range.lowerBound), range.upperBound)
        guard newValue != value else { return }
        value = newValue
        onValueChange?(newValue)
        lastDragged = Date()
    }
}
