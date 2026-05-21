import SwiftUI

// MARK: - QueuePanelView
//
// Floating panel above the NowPlayingBar queue button.
// Shows current + upcoming tracks; supports jump-to and remove.

public struct QueuePanelView: View {
    @ObservedObject var ctrl: AppController
    @Binding var isPresented: Bool

    public init(ctrl: AppController, isPresented: Binding<Bool>) {
        self.ctrl = ctrl
        _isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("播放队列")
                    .font(Theme.font(Theme.fontMD, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(Theme.divider)

            // Track list
            if ctrl.queue.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.mutedText)
                    Text("队列为空")
                        .font(Theme.font(Theme.fontSM))
                        .foregroundStyle(Theme.mutedText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(ctrl.queue.enumerated()), id: \.element.id) { idx, track in
                                queueRow(track: track, idx: idx)
                            }
                        }
                    }
                    .onAppear {
                        let ci = ctrl.queueIndex
                        if ci >= 0 {
                            DispatchQueue.main.async {
                                withAnimation { proxy.scrollTo(ci, anchor: .top) }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 320, height: 420)
        .background(Theme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
        .shadow(color: .black.opacity(0.4), radius: 20)
    }

    @ViewBuilder
    private func queueRow(track: Track, idx: Int) -> some View {
        let isCurrent = idx == ctrl.queueIndex
        HStack(spacing: 10) {
            // Play indicator or index
            Group {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("\(idx + 1)")
                        .font(Theme.font(Theme.fontXS))
                        .foregroundStyle(Theme.mutedText)
                        .monospacedDigit()
                }
            }
            .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(Theme.font(Theme.fontSM, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.primaryText)
                    .lineLimit(1)
                Text(track.artist)
                    .font(Theme.font(Theme.fontXS))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            // Remove button
            Button {
                ctrl.removeFromQueue(at: idx)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.mutedText)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .background(isCurrent ? Theme.accent.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .id(idx)
        .onTapGesture {
            Task { await ctrl.jumpToQueueIndex(idx) }
        }
    }
}
