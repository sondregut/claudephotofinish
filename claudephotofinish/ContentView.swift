import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var gateFlash = false
    @State private var fullscreenLap: LapRecord? = nil

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            timerAndPreview
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider().background(Color.gray.opacity(0.3))
            lapList
            Divider().background(Color.gray.opacity(0.3))
            bottomControls
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { camera.startSession() }
        .onChange(of: camera.crossings.count) { _, _ in
            gateFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { gateFlash = false }
        }
        .overlay {
            if let lap = fullscreenLap, let data = lap.thumbnailData, let img = UIImage(data: data) {
                Color.black.ignoresSafeArea()
                    .overlay {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay {
                                Rectangle()
                                    .fill(Color.red.opacity(0.8))
                                    .frame(width: 2)
                            }
                            .overlay(alignment: .bottom) {
                                VStack(spacing: 2) {
                                    Text(String(format: "interp: %.0f / %.0f  (%.2f)",
                                                lap.dBefore, lap.dAfter, lap.interpolationFraction))
                                    Text("dir: \(lap.direction)  |  frame: \(lap.usedPreviousFrame ? "prev (N-1)" : "curr (N)")")
                                }
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(6)
                                .padding(.bottom, 12)
                            }
                    }
                    .onTapGesture { fullscreenLap = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: fullscreenLap != nil)
    }

    // MARK: - Computed

    private var bestLapTime: TimeInterval? {
        let laps = camera.crossings
        guard laps.count >= 2 else { return nil }
        var best: TimeInterval?
        for i in 1..<laps.count {
            let lt = laps[i].time - laps[i - 1].time
            if best == nil || lt < best! { best = lt }
        }
        return best
    }

    private func lapTime(for lap: LapRecord) -> TimeInterval {
        let index = lap.crossingNumber - 1
        if index == 0 { return camera.crossings[0].time }
        return camera.crossings[index].time - camera.crossings[index - 1].time
    }

    // MARK: - 1. Status Banner

    private var statusBanner: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: camera.isPhoneStable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text(camera.isPhoneStable ? "Stable" : "Moving")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(camera.isPhoneStable ? .green : .red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(statusBannerColor)
    }

    private var statusColor: Color {
        if !camera.isPhoneStable { return .red }
        if camera.isDetecting { return .green }
        return .gray
    }

    private var statusText: String {
        if !camera.isPhoneStable { return "HOLD STILL" }
        if camera.isDetecting { return "RUNNING — CLAUDE TEST PROJECT" }
        return "Ready"
    }

    private var statusBannerColor: Color {
        if !camera.isPhoneStable { return Color.red.opacity(0.15) }
        if camera.isDetecting { return Color.green.opacity(0.1) }
        return Color.gray.opacity(0.08)
    }

    // MARK: - 2. Timer + Camera Preview

    private var timerAndPreview: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run #\(camera.runNumber)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { context in
                    let elapsed = camera.timerStart.map { context.date.timeIntervalSince($0) } ?? 0
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text(formatTimeMajor(elapsed))
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                        Text(formatTimeMinor(elapsed))
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .opacity(0.5)
                    }
                    .foregroundStyle(camera.isDetecting ? .green : .white)
                    .contentTransition(.numericText())
                }

                if let last = camera.crossings.last {
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text(formatTimeMajor(last.time))
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                        Text(formatTimeMinor(last.time))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .opacity(0.5)
                    }
                    .foregroundStyle(.green)
                }

                HStack(spacing: 4) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 11))
                    Text("\(camera.crossings.count) crossing\(camera.crossings.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            ZStack {
                Color.black
                CameraPreviewView(session: camera.captureSession)
                Rectangle()
                    .fill(gateLineColor)
                    .frame(width: gateFlash ? 4 : 2)
                    .animation(.easeOut(duration: 0.15), value: gateFlash)
            }
            .frame(width: 120, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private var gateLineColor: Color {
        if gateFlash { return .green }
        if camera.isDetecting { return .red }
        if !camera.isPhoneStable { return .gray.opacity(0.3) }
        return .red.opacity(0.5)
    }

    // MARK: - 3. Lap List

    @ViewBuilder
    private var lapList: some View {
        if camera.crossings.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "figure.run")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No laps yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Run through the gate to start recording")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Practice")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if let best = bestLapTime {
                        HStack(spacing: 4) {
                            Text("Best")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(formatTime(best))
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(camera.crossings.reversed()) { lap in
                                lapCard(lap)
                                    .id(lap.id)
                            }
                        }
                    }
                    .onChange(of: camera.crossings.count) { _, _ in
                        if let last = camera.crossings.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .top) }
                        }
                    }
                }
            }
        }
    }

    private func lapCard(_ lap: LapRecord) -> some View {
        let index = lap.crossingNumber - 1
        let lt = lapTime(for: lap)
        let isBest = bestLapTime != nil && index > 0 && lt == bestLapTime
        let isStart = index == 0

        return HStack(spacing: 12) {
            if let data = lap.thumbnailData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 58)
                    .overlay {
                        Rectangle()
                            .fill(Color.red.opacity(0.6))
                            .frame(width: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onTapGesture { fullscreenLap = lap }
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 44, height: 58)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(isStart ? "Start" : "Lap \(index)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isStart ? .blue : .white)
                Text(formatTime(lap.time))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatTime(lt))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isBest ? .green : .orange)

                if isBest {
                    Text("BEST")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - 4. Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 16) {
            Button(action: {
                if camera.isDetecting { camera.stopDetection() }
                else { camera.startDetection() }
            }) {
                Text(camera.isDetecting ? "Stop" : "Start")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(camera.isDetecting ? Color.red : Color.green)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
            }

            Button(action: { camera.resetSession() }) {
                Text("Reset")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 70, height: 44)
                    .background(Color(.systemGray5))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }

            Button(action: { camera.switchCamera() }) {
                Image(systemName: "camera.rotate.fill")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
                    .background(Color(.systemGray5))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Time Formatting

    private func formatTime(_ interval: TimeInterval) -> String {
        let totalMs = Int(interval * 1000)
        let mins = totalMs / 60000
        let secs = (totalMs % 60000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d.%03d", mins, secs, ms)
    }

    private func formatTimeMajor(_ interval: TimeInterval) -> String {
        let total = Int(interval * 100)
        let mins = total / 6000
        let secs = (total % 6000) / 100
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatTimeMinor(_ interval: TimeInterval) -> String {
        let total = Int(interval * 100)
        let hundredths = total % 100
        return String(format: ".%02d", hundredths)
    }
}
