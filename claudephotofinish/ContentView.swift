import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var gateFlash = false
    @State private var fullscreenLapID: UUID? = nil
    @State private var justCopied = false
    @State private var showTuning = false

    /// Live lookup of the fullscreen lap from `camera.crossings`. Reading
    /// through the published array (instead of a captured copy) means the
    /// overlay re-renders when `markLapPoint` mutates the record.
    private var fullscreenLap: LapRecord? {
        guard let id = fullscreenLapID else { return nil }
        return camera.crossings.first(where: { $0.id == id })
    }

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
        .background(Color(.systemBackground))
        .preferredColorScheme(.light)
        .onAppear { camera.startSession() }
        .onChange(of: camera.crossings.count) { _, _ in
            gateFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { gateFlash = false }
        }
        .overlay {
            if let lap = fullscreenLap, let data = lap.thumbnailData, let img = UIImage(data: data) {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { geo in
                                ZStack {
                                    // Invisible tap target — captures every tap on
                                    // the image and converts it to source coords.
                                    // mirrorX flips the X axis for front-camera laps
                                    // so the stored userMarkedPoint.x lives in
                                    // processing-buffer space (comparable to dB/dA).
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture(coordinateSpace: .local) { loc in
                                            let sp = layoutToSource(layoutPoint: loc,
                                                                    layoutSize: geo.size,
                                                                    fill: false,
                                                                    mirrorX: lap.isFrontCamera)
                                            camera.markLapPoint(id: lap.id, point: sp)
                                        }

                                    // Gate line — geometric center column where
                                    // detection actually happens (gateColumn = 90).
                                    Rectangle()
                                        .fill(Color.red.opacity(0.8))
                                        .frame(width: 2, height: geo.size.height)
                                        .position(x: geo.size.width / 2,
                                                  y: geo.size.height / 2)
                                        .allowsHitTesting(false)

                                    // Interpolated gate line (cyan) — where the
                                    // leading edge sits in the *displayed* frame,
                                    // i.e. the algorithm's sub-frame interpolated
                                    // crossing position. Drawn alongside the red
                                    // line so we can compare both at a glance.
                                    let gateColumn = camera.engine.gateColumn
                                    let shiftedSourceX: CGFloat = {
                                        let g = CGFloat(gateColumn)
                                        let dB = CGFloat(lap.dBefore)
                                        let dA = CGFloat(lap.dAfter)
                                        if lap.direction == "L>R" {
                                            return lap.usedPreviousFrame ? g - dB : g + dA
                                        } else { // "R>L"
                                            return lap.usedPreviousFrame ? g + dB : g - dA
                                        }
                                    }()
                                    let shiftedLayoutX = detectionDotX(
                                        sourceX: shiftedSourceX,
                                        layoutSize: geo.size,
                                        fill: false,
                                        mirrorX: lap.isFrontCamera)
                                    Rectangle()
                                        .fill(Color.cyan.opacity(0.8))
                                        .frame(width: 2, height: geo.size.height)
                                        .position(x: shiftedLayoutX,
                                                  y: geo.size.height / 2)
                                        .allowsHitTesting(false)

                                    // Detector dot (yellow) — sits on the cyan
                                    // interpolated line, not the red center line,
                                    // because the dot represents the detector's
                                    // chosen crossing point in both X and Y.
                                    let detY = detectionDotY(sourceY: lap.gateY,
                                                             layoutSize: geo.size,
                                                             fill: false)
                                    Circle()
                                        .fill(Color.yellow)
                                        .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                        .frame(width: 14, height: 14)
                                        .position(x: shiftedLayoutX, y: detY)
                                        .allowsHitTesting(false)

                                    // User-marked ground truth dot (green).
                                    // p.x is in processing-buffer space; the
                                    // mirrorX flip puts it back into the
                                    // visible thumbnail X for front-cam laps,
                                    // so the green dot lands exactly where
                                    // the user originally tapped (round-trip
                                    // identity with layoutToSource above).
                                    if let p = lap.userMarkedPoint {
                                        let ux = detectionDotX(sourceX: p.x,
                                                               layoutSize: geo.size,
                                                               fill: false,
                                                               mirrorX: lap.isFrontCamera)
                                        let uy = detectionDotY(sourceY: Int(p.y.rounded()),
                                                               layoutSize: geo.size,
                                                               fill: false)
                                        Circle()
                                            .fill(Color.green)
                                            .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                            .frame(width: 14, height: 14)
                                            .position(x: ux, y: uy)
                                            .allowsHitTesting(false)
                                    }
                                }
                            }
                        }
                        .overlay(alignment: .bottom) {
                            VStack(spacing: 2) {
                                Text(String(format: "interp: %.0f / %.0f  (%.2f)",
                                            lap.dBefore, lap.dAfter, lap.interpolationFraction))
                                Text("dir: \(lap.direction)  |  frame: \(lap.usedPreviousFrame ? "prev (N-1)" : "curr (N)")")
                                if let p = lap.userMarkedPoint {
                                    Text(String(format: "marked: x=%.0f y=%.0f  Δy=%+d",
                                                p.x, p.y, Int(p.y.rounded()) - lap.gateY))
                                        .foregroundColor(.green)
                                } else {
                                    Text("tap image to mark actual crossing point")
                                        .foregroundColor(.gray)
                                }
                            }
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(6)
                            .padding(.bottom, 12)
                        }

                    // Close button (tap-to-dismiss is repurposed for marking)
                    Button(action: { fullscreenLapID = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white, Color.black.opacity(0.6))
                            .padding(16)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: fullscreenLapID)
        .sheet(isPresented: $showTuning) {
            tuningPanel
        }
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

    // MARK: - Copy run data

    /// Build a markdown table of the current run and stash it on the
    /// pasteboard so it can be pasted into chat for analysis alongside
    /// the paired DETECT/DETECT_DIAG logs.
    private func copyRunDataMarkdown() {
        let laps = camera.crossings
        var md = "| # | time | blob WxH | detY | userY | Δy | dir | interp |\n"
        md += "|---|------|----------|------|-------|----|----|--------|\n"
        for lap in laps {
            let w = Int(lap.componentBounds.width.rounded())
            let h = Int(lap.componentBounds.height.rounded())
            let userY = lap.userMarkedPoint.map { String(Int($0.y.rounded())) } ?? "—"
            let deltaY = lap.userMarkedPoint.map {
                String(format: "%+d", Int($0.y.rounded()) - lap.gateY)
            } ?? "—"
            let interp = String(format: "%.0f/%.0f (%.2f)",
                                lap.dBefore, lap.dAfter, lap.interpolationFraction)
            md += String(
                format: "| %d | %.3f | %dx%d | %d | %@ | %@ | %@ | %@ |\n",
                lap.crossingNumber, lap.time, w, h, lap.gateY,
                userY, deltaY, lap.direction, interp
            )
        }
        UIPasteboard.general.string = md
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
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
                    .foregroundStyle(camera.isDetecting ? .green : .primary)
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
            .frame(width: 108, height: 192)
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
                HStack(spacing: 10) {
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
                    Button(action: copyRunDataMarkdown) {
                        HStack(spacing: 3) {
                            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                            Text(justCopied ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(justCopied ? .green : .blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color(.tertiarySystemBackground))
                        )
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

    /// Map a source-coordinate Y (thumbnail is generated at 180x320, same as the
    /// detector process resolution) to a Y offset in the displayed image's layout
    /// frame, accounting for aspect-fill vs aspect-fit.
    private func detectionDotY(sourceY: Int, layoutSize: CGSize, fill: Bool) -> CGFloat {
        let srcW: CGFloat = 180, srcH: CGFloat = 320
        let sx = layoutSize.width / srcW
        let sy = layoutSize.height / srcH
        let scale = fill ? max(sx, sy) : min(sx, sy)
        return layoutSize.height / 2 + (CGFloat(sourceY) - srcH / 2) * scale
    }

    /// Map a source-coordinate X (in the 180×320 processing buffer space) to
    /// a layout X in the displayed image's frame. When `mirrorX` is true,
    /// the source X is reflected across (srcW-1)/2 first, because the
    /// front-camera thumbnail is `rot90CW(src)` while the processing buffer
    /// is `transpose(src)` — the two differ by a horizontal flip on the
    /// dest X axis. See LapRecord.isFrontCamera for the full reasoning.
    private func detectionDotX(sourceX: CGFloat, layoutSize: CGSize, fill: Bool, mirrorX: Bool = false) -> CGFloat {
        let srcW: CGFloat = 180, srcH: CGFloat = 320
        let sx = layoutSize.width / srcW
        let sy = layoutSize.height / srcH
        let scale = fill ? max(sx, sy) : min(sx, sy)
        let effectiveX = mirrorX ? (srcW - 1 - sourceX) : sourceX
        return layoutSize.width / 2 + (effectiveX - srcW / 2) * scale
    }

    /// Inverse of the dot-positioning math: given a tap location in the
    /// image's layout frame, return the corresponding point in source
    /// 180×320 coordinates. Clamped to valid source range. When `mirrorX`
    /// is true, the X output is reflected across (srcW-1)/2 so the stored
    /// value lives in processing-buffer X space (the same space as
    /// gateColumn ± dB/dA), which is what we want to log and compare against
    /// algorithm output. The round-trip layoutToSource → detectionDotX with
    /// the same mirrorX flag is identity, so the green tap dot still lands
    /// exactly where the user tapped.
    private func layoutToSource(layoutPoint: CGPoint, layoutSize: CGSize, fill: Bool, mirrorX: Bool = false) -> CGPoint {
        let srcW: CGFloat = 180, srcH: CGFloat = 320
        let sx = layoutSize.width / srcW
        let sy = layoutSize.height / srcH
        let scale = fill ? max(sx, sy) : min(sx, sy)
        guard scale > 0 else { return .zero }
        var x = (layoutPoint.x - layoutSize.width / 2) / scale + srcW / 2
        let y = (layoutPoint.y - layoutSize.height / 2) / scale + srcH / 2
        if mirrorX { x = srcW - 1 - x }
        return CGPoint(
            x: min(max(x, 0), srcW - 1),
            y: min(max(y, 0), srcH - 1)
        )
    }

    private func lapCard(_ lap: LapRecord) -> some View {
        let index = lap.crossingNumber - 1
        let lt = lapTime(for: lap)
        let isBest = bestLapTime != nil && index > 0 && lt == bestLapTime
        let cardW: CGFloat = 44
        let cardH: CGFloat = 58
        let cardSize = CGSize(width: cardW, height: cardH)
        let dotY = detectionDotY(sourceY: lap.gateY, layoutSize: cardSize, fill: true)
        let userDot: CGPoint? = lap.userMarkedPoint.map {
            CGPoint(
                x: detectionDotX(sourceX: $0.x, layoutSize: cardSize, fill: true,
                                 mirrorX: lap.isFrontCamera),
                y: detectionDotY(sourceY: Int($0.y.rounded()), layoutSize: cardSize, fill: true)
            )
        }

        return HStack(spacing: 12) {
            if let data = lap.thumbnailData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardW, height: cardH)
                    .overlay {
                        Rectangle()
                            .fill(Color.red.opacity(0.6))
                            .frame(width: 1)
                    }
                    .overlay(alignment: .topLeading) {
                        Circle()
                            .fill(Color.yellow)
                            .overlay(Circle().stroke(Color.white, lineWidth: 0.5))
                            .frame(width: 5, height: 5)
                            .position(x: cardW / 2, y: dotY)
                    }
                    .overlay(alignment: .topLeading) {
                        if let ud = userDot {
                            Circle()
                                .fill(Color.green)
                                .overlay(Circle().stroke(Color.white, lineWidth: 0.5))
                                .frame(width: 5, height: 5)
                                .position(x: ud.x, y: ud.y)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onTapGesture { fullscreenLapID = lap.id }
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 44, height: 58)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Lap \(index + 1)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
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
        .background(Color(.secondarySystemBackground))
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
                    .background(Color(.systemGray4))
                    .foregroundStyle(.primary)
                    .clipShape(Capsule())
            }

            Button(action: { camera.switchCamera() }) {
                Image(systemName: "camera.rotate.fill")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
                    .background(Color(.systemGray4))
                    .foregroundStyle(.primary)
                    .clipShape(Circle())
            }

            Button(action: { showTuning = true }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
                    .background(Color(.systemGray4))
                    .foregroundStyle(.primary)
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Shutter cap log-scale mapping
    //
    // Slider position in [0,1] maps to shutter duration from 1/30s (33.3 ms)
    // at pos=0 down to 1/2000s (0.5 ms) at pos=1. Log scale so the useful
    // range (1/120 … 1/1000) takes up most of the slider travel.
    private func sliderPosToShutterMs(_ pos: Double) -> Double {
        return 1000.0 / (30.0 * pow(2000.0 / 30.0, pos))
    }
    private func shutterMsToSliderPos(_ ms: Double) -> Double {
        let ratio = 1000.0 / (30.0 * ms)
        guard ratio > 0 else { return 0 }
        return log(ratio) / log(2000.0 / 30.0)
    }

    // MARK: - 5. Camera Tuning Panel

    private var tuningPanel: some View {
        NavigationStack {
            Form {
                liveReadoutSection
                modeSection
                if camera.isManualExposure {
                    manualExposureSection
                } else {
                    autoExposureSection
                }
                detectionSection
            }
            .navigationTitle("Camera Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showTuning = false }
                }
            }
        }
    }

    private var liveReadoutSection: some View {
        Section("Live readout") {
            HStack {
                Text("Exposure").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f ms", camera.currentExposureMs))
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("ISO").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f", camera.currentISO))
                    .font(.system(.body, design: .monospaced))
            }
            Text("Updates once per second. Works in idle too — you don't have to press Start.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var modeSection: some View {
        Section("Mode") {
            Toggle("Manual exposure", isOn: $camera.isManualExposure)
            Text(camera.isManualExposure
                 ? "Shutter and ISO locked. No auto-adapt."
                 : "Auto-exposure adapts; shutter capped below.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var autoExposureSection: some View {
        Section("Auto-exposure shutter cap") {
            Toggle("Use iOS default (no cap override)",
                   isOn: Binding(
                    get: { camera.maxExposureCapMs == nil },
                    set: { camera.maxExposureCapMs = $0 ? nil : 4.0 }))
            Text("ON = baseline: what does the active format pick on its own?")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if camera.maxExposureCapMs != nil {
                capSliderRow
                presetRow
            }

            Text("Shorter shutter = less blur. Sensor raises ISO to compensate.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var capSliderRow: some View {
        let capMs = camera.maxExposureCapMs ?? 4.0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Max shutter")
                Spacer()
                Text(String(format: "%.2f ms  (1/%.0fs)", capMs, 1000.0 / capMs))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.blue)
            }
            Slider(value: Binding(
                get: { shutterMsToSliderPos(capMs) },
                set: { camera.maxExposureCapMs = sliderPosToShutterMs($0) }
            ), in: 0...1) {
                Text("Max shutter")
            } minimumValueLabel: {
                Text("1/30").font(.caption2)
            } maximumValueLabel: {
                Text("1/2000").font(.caption2)
            }
        }
    }

    private var presetRow: some View {
        let presets: [(String, Double)] = [
            ("1/60", 1000.0 / 60),
            ("1/120", 1000.0 / 120),
            ("1/250", 1000.0 / 250),
            ("1/500", 1000.0 / 500),
            ("1/1000", 1000.0 / 1000),
        ]
        return HStack(spacing: 6) {
            ForEach(presets, id: \.0) { preset in
                Button(preset.0) { camera.maxExposureCapMs = preset.1 }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var detectionSection: some View {
        Section("Detection tuning") {
            HStack {
                Text("Min h/w ratio")
                Spacer()
                Text(String(format: "%.2f", camera.minHeightWidthRatio))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.blue)
            }
            Slider(value: $camera.minHeightWidthRatio, in: 0.5...3.0, step: 0.05)
            Text("Reject blobs shorter than this × their width. 1.5 = blob must be 50% taller than wide. Higher = stricter (rejects more hand swipes but may reject leaning bodies).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var manualExposureSection: some View {
        Group {
            Section("Manual shutter") {
                HStack {
                    Text("Exposure")
                    Spacer()
                    Text(String(format: "%.2f ms", camera.manualExposureMs))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                Slider(value: $camera.manualExposureMs, in: 0.5...33.0, step: 0.25)
            }

            Section("Manual ISO") {
                HStack {
                    Text("ISO")
                    Spacer()
                    Text(String(format: "%.0f", camera.manualISO))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                Slider(value: $camera.manualISO, in: 25...3200, step: 25)
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
