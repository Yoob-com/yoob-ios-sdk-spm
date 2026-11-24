import SwiftUI
import Yoob

struct ContentView: View {
    /// The character last picked, remembered between launches (the demo opened from the home screen starts on it).
    @AppStorage("character") private var character = "luna-realistic"
    @State private var avatar = ContentView.makeAvatar(UserDefaults.standard.string(forKey: "character") ?? "luna-realistic")
    @State private var conversation: YoobConversation?
    /// Astrid talks in full mode: Yoob's own voice (Duotone) over the session's live credential.
    @State private var duotone: YoobDuotoneConversation?
    /// `--talk` starts one conversation per launch (the task re-runs when the launch argument picks the character).
    private static var autoTalked = false

    static func makeAvatar(_ character: String) -> YoobAvatar {
        YoobAvatar(.cloud(character: character) { try await Backend.credentials(for: character) })
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            stage


            VStack(spacing: 12) {
                captions
                status
                HStack(spacing: 10) {
                    Button(action: toggleTalk) {
                        Label(isTalking ? "End" : "Talk", systemImage: isTalking ? "phone.down.fill" : "mic.fill")
                            .frame(minWidth: 84)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isTalking ? .red : .accentColor)
                    .disabled(!canSpeak && !isTalking)

                    if isTalking { MicrophoneControls(microphone: avatar.microphone) }

                    Spacer(minLength: 0)
                    Button(action: sayHello) {
                        Image(systemName: avatar.phase == .speaking && !isTalking ? "stop.fill" : "waveform")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Play sample")
                    .disabled(!canSpeak || isTalking)
                }
                Picker("Character", selection: $character) {
                    Text("Realistic").tag("luna-realistic")
                    Text("Anime").tag("luna-anime-v2")
                    Text("Astrid").tag("r2-f08-astrid")
                }
                .pickerStyle(.segmented)
                .disabled(isTalking)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        #if DEBUG || YOOB_CHECKS
        .onAppear {
            if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--character=") }) {
                character = String(arg.dropFirst("--character=".count))
            }
        }
        #endif
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .task(id: character) {
            if avatar.character != character {
                await avatar.close()
                avatar = Self.makeAvatar(character)
            }
            try? await avatar.prepare()
            #if DEBUG || YOOB_CHECKS
            // Automated checks: `simctl launch … --say-hello` speaks once the character is ready.
            if ProcessInfo.processInfo.arguments.contains("--say-hello") { sayHello() }
            // `--talk`: starts Talk once ready; `--talk-text=<words>` then sends them as a typed turn (no microphone needed).
            if ProcessInfo.processInfo.arguments.contains("--talk"), !Self.autoTalked {
                Self.autoTalked = true
                toggleTalk()
                if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--talk-text=") }) {
                    let text = String(arg.dropFirst("--talk-text=".count))
                    for _ in 0..<100 where duotone?.state != .listening { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await duotone?.send(text: text)
                }
                // `--talk-end-after=<seconds>`: presses End then (while she is still speaking, to check it never hangs).
                if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--talk-end-after=") }),
                   let seconds = Double(arg.dropFirst("--talk-end-after=".count)) {
                    try? await Task.sleep(for: .seconds(seconds))
                    if isTalking { toggleTalk() }
                }
            }
            #endif
        }
    }

    /// The Luna app's Home look (language-companions `FaceHomeView.swift`): her 9:16 picture filling the screen with her
    /// face in the upper half, on Luna's night colour, a black gradient over the top bar and a night gradient under the
    /// controls, so the text stays legible over any part of the picture.
    private var stage: some View {
        ZStack {
            GeometryReader { box in
                let width = max(box.size.width, box.size.height * 9 / 16), height = width * 16 / 9
                ZStack {
                    Self.night
                    // The Luna app's call screen: 0.22 s into speech, 0.35 s back.
                    YoobAvatarView(avatar, fade: 0.22, fadeOut: 0.35)
                        .frame(width: width, height: height)
                        .position(x: box.size.width / 2, y: height / 2 - max(0, height - box.size.height) * 0.35)
                }
                .frame(width: box.size.width, height: box.size.height).clipped()
            }
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 170)
                Spacer()
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Self.night.opacity(0.6), location: 0.35),
                                       .init(color: Self.night.opacity(0.92), location: 0.75), .init(color: Self.night, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 480)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// Luna's night (language-companions `Palette.swift` LunaColor.night).
    private static let night = Color(red: 0.039, green: 0.059, blue: 0.141)

    private var isTalking: Bool {
        if let state = duotone?.state { return state != .idle && state != .ended }
        guard let state = conversation?.state else { return false }
        return state != .idle && state != .ended
    }

    private var canSpeak: Bool {
        switch avatar.phase {
        case .ready, .speaking: true
        default: false
        }
    }

    @ViewBuilder private var captions: some View {
        if let duotone, isTalking {
            VStack(alignment: .leading, spacing: 4) {
                if !duotone.assistantTranscript.isEmpty { Text(duotone.assistantTranscript).font(.callout).lineLimit(3) }
                if !duotone.userTranscript.isEmpty {
                    Text(duotone.userTranscript).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let conversation, isTalking {
            VStack(alignment: .leading, spacing: 4) {
                if !conversation.assistantTranscript.isEmpty {
                    Text(conversation.assistantTranscript).font(.callout).lineLimit(3)
                }
                if !conversation.userTranscript.isEmpty {
                    Text(conversation.userTranscript).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var status: some View {
        if let duotone, isTalking {
            Text(duotoneText(duotone.state)).font(.subheadline)
        } else if let duotone, let error = duotone.lastError {
            Text(error.localizedDescription).font(.subheadline).multilineTextAlignment(.center)
        } else if let conversation, isTalking {
            Text(conversationText(conversation.state)).font(.subheadline)
        } else {
            switch avatar.phase {
            case .notPrepared, .warming:
                Label("Getting ready…", systemImage: "hourglass").font(.subheadline)
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading \(avatar.manifest?.displayName ?? "character") · \(Int(progress.fraction * 100))%")
                        .font(.subheadline)
                    ProgressView(value: progress.fraction)
                }
            case .ready:
                Text(conversation?.lastError?.localizedDescription ?? "Ready. Tap Talk.").font(.subheadline)
            case .speaking:
                Text("Speaking").font(.subheadline)
            case .failed(let error), .stopped(let error):
                VStack(spacing: 8) {
                    Text(error.localizedDescription).font(.subheadline).multilineTextAlignment(.center)
                    Button("Try again") { Task { try? await avatar.prepare() } }
                }
            }
        }
    }

    private func conversationText(_ state: YoobConversation.State) -> String {
        switch state {
        case .connecting: "Connecting…"
        case .listening: "Listening. Just speak."
        case .thinking: "Thinking…"
        case .speaking: "Speaking. Talk to interrupt."
        case .idle, .ended: ""
        }
    }

    /// Astrid's persona for the demo. Without one Duotone speaks as its own demo persona ("Tap's AI voice").
    private static let astridPrompt = """
        You are Astrid, talking with the user on a live video call. You are warm, curious and easygoing, with a light \
        sense of humour. Keep every reply short: one or two spoken sentences, then let them talk, and ask a question back \
        now and then. Speak naturally, like a friend, never like an assistant reading a list. If they ask who you are, \
        you are Astrid; do not call yourself an AI voice, Duotone or Tap.
        """

    private func duotoneText(_ state: YoobDuotoneConversation.State) -> String {
        switch state {
        case .connecting: "Connecting…"
        case .listening: "Listening. Just speak."
        case .thinking: "Thinking…"
        case .speaking: "Speaking. Talk to interrupt."
        case .idle, .ended: ""
        }
    }

    private func toggleTalk() {
        if isTalking { conversation?.stop(); duotone?.stop(); return }
        // Full mode: every character talks in Yoob's own voice (Duotone), on the session the token server opened.
        var options = YoobDuotoneConversation.Options()
        if character == "r2-f08-astrid" {
            // Her voice and persona. w0744 is the console's Duotone voice for Astrid.
            options.voice = "w0744"
            options.instructions = Self.astridPrompt
        }
        let duotone = YoobDuotoneConversation(avatar: avatar, options: options)
        self.duotone = duotone
        Task { try? await duotone.start() }
    }

    private func sayHello() {
        if avatar.phase == .speaking { avatar.interrupt(); return }
        guard let url = Bundle.main.url(forResource: "hello-24k", withExtension: "pcm"),
              let pcm = try? Data(contentsOf: url) else { return }
        // Stream it in 100 ms packets, the way a realtime voice or TTS stream arrives.
        Task {
            for offset in stride(from: 0, to: pcm.count, by: 4800) {
                try avatar.speak(pcm: pcm.subdata(in: offset..<min(pcm.count, offset + 4800)), sampleRate: 24000)
                try await Task.sleep(for: .milliseconds(20))
            }
            avatar.endSpeech()
        }
    }
}

/// Mute, input level and input choice for a live conversation.
struct MicrophoneControls: View {
    let microphone: YoobMicrophone

    var body: some View {
        HStack(spacing: 8) {
            Button { microphone.setMuted(!microphone.isMuted) } label: {
                Image(systemName: microphone.isMuted ? "mic.slash.fill" : "mic.fill")
            }
            .buttonStyle(.bordered)
            .tint(microphone.isMuted ? .red : nil)
            .accessibilityLabel(microphone.isMuted ? "Unmute" : "Mute")

            Gauge(value: microphone.level) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .frame(width: 56)
                .accessibilityLabel("Microphone level")

            if microphone.inputs.count > 1 {
                Menu {
                    Button("Automatic") { try? microphone.select(inputID: nil) }
                    ForEach(microphone.inputs) { input in
                        Button(input.name) { try? microphone.select(inputID: input.id) }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .accessibilityLabel("Choose microphone")
            }
        }
    }
}
