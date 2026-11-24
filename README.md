# Yoob for iOS

Talking characters that render on the iPhone. You give Yoob speech audio; it plays the audio and moves the face in sync,
at 25 fps, entirely on the device. Add full mode for a live spoken conversation in Yoob's own voice with no provider key, or bring
your own LLM and voice.

- **Small install.** The package adds about 1.8 MB to your app. Character files (26–40 MB) download on first use from
  `assets.yoob.com` in verified, resumable chunks, and on a good connection the character's picture appears within about a second.
- **Any voice.** Talk in full mode with Yoob's own voice, or pass mono 16-bit PCM from OpenAI Realtime, Gemini Live, ElevenLabs, your
  own TTS, or a recording.
- **Private by design.** Faces render on the device. The SDK sends Yoob only what is listed under [Network](#network):
  conversation audio goes through Yoob only in full mode.

Requires iOS 18 or later and Xcode 26 or later. The current preview release is 0.7.5; see [Changes in 0.7.5](#changes-in-075), [0.7.4](#changes-in-074), [0.7.3](#changes-in-073), [0.7.2](#changes-in-072), [0.7.1](#changes-in-071), [0.7.0](#changes-in-070), [0.6.1](#changes-in-061), [0.6.0](#changes-in-060), [0.5.0](#changes-in-050), [0.4.1](#changes-in-041) and [0.4.0](#changes-in-040) if you are upgrading.

## Install

In Xcode choose **File › Add Package Dependencies…** and enter:

```
https://github.com/Yoob-com/yoob-ios-sdk-spm
```

or add it to `Package.swift`:

```swift
.package(url: "https://github.com/Yoob-com/yoob-ios-sdk-spm", from: "0.7.5")
```

Set your app's deployment target to iOS 18 or later: Xcode adds the package to an app with a lower one and only warns
when it links, but that app cannot load Yoob on iOS 17.

The package is the SDK built as `Yoob.xcframework` (iOS devices and the iOS Simulator), so your app compiles against its
interface and does not build the SDK's source.

## Quick start

### 1. Open a session on your backend

Create an API key in the [Yoob console](https://yoob.com/account/). Keep the key on your server; the app gets a
short-lived session instead. Your backend checks who is asking, rate-limits them, and asks for exactly the one
character the app wants (never `"*"`):

```sh
curl -X POST https://app.yoob.com/api/v1/avatar/sessions \
  -H "Authorization: Bearer $YOOB_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"characters": ["luna-realistic"]}'
```

```json
{ "session_token": "…", "download_token": "yg1.…", "heartbeat_seconds": 15 }
```

[`Examples/token-server`](Examples/token-server/server.mjs) is a runnable backend that does all of this. It refuses
every request until you replace its `requireUser()` with your own sign-in check; for local development, start it with
`YOOB_EXAMPLE_ALLOW_ANONYMOUS=1`. See [Security](#security).

### 2. Show the character

```swift
import SwiftUI
import Yoob

struct CharacterScreen: View {
    @State private var avatar = YoobAvatar(.cloud(character: "luna-realistic") {
        try await MyBackend.yoobSession()          // returns YoobCredentials
    })

    var body: some View {
        YoobAvatarView(avatar)
            .ignoresSafeArea()
            .task { try? await avatar.prepare() }
    }
}
```

`prepare()` opens the session, downloads what is missing and warms up the renderer. The character's poster and idle
motion show while the models download.

### 3. Make it talk

```swift
// Call for each chunk as it streams in (PCM16, mono, little-endian).
try avatar.speak(pcm: chunk, sampleRate: 24_000)

// After the last chunk. The face settles back to idle when the audio ends.
avatar.endSpeech()

// Barge-in: stop now. Returns how many samples were heard, for truncating a realtime reply.
let heard = avatar.interrupt()
```

The avatar holds the voice back for the first frame (up to `maxSyncDelay`, 1.8 s by default), so lips and voice
start together. Audio always plays, even if the character failed to load.

Speech that arrives in real time (a WebRTC or LiveKit agent) can use low-latency lips instead: each frame is drawn as
soon as a little of the audio after it is in (120 ms for the realistic Luna), and the voice plays a fixed short delay
after it arrives (127 ms) instead of waiting for the first frame:

```swift
avatar.lipSync = .instant          // .automatic (default): .standard for speak, .instant for appendAudio
```

### Your app already plays the audio?

Render without playing, and report how much has been heard:

```swift
try avatar.appendAudio(pcm: chunk, sampleRate: 24_000)
avatar.audioPlayed(samples: samplesHeardSoFar)   // call often, e.g. from your audio tap
avatar.endSpeech()
```

Here the lips are drawn the low-latency way by default (`lipSync` `.automatic`), since your player does not wait for
them. If you can delay your playback a little, about 130 ms keeps the realistic Luna's lips exactly on the voice.

## Talk with it: full mode, Yoob's own voice

Open the session with `"mode": "full"` and Yoob runs the conversation too: Duotone, Yoob's own voice (it listens, a
language model answers, and it speaks the reply while the reply is still being written). There is no second session to
ask for and no provider key; the same session that downloads the character carries the conversation:

```sh
curl -X POST https://app.yoob.com/api/v1/avatar/sessions \
  -H "Authorization: Bearer $YOOB_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"characters": ["luna-realistic"], "mode": "full", "yoob_voice": true}'
```

The response is the usual session plus `live_token` and `live_url`, a credential for **one** conversation, good for
about five minutes (`avatar.liveSession` reads them). Then:

```swift
let conversation = YoobDuotoneConversation(avatar: avatar)
try await conversation.start()                 // asks for the microphone
// conversation.state, .userTranscript and .assistantTranscript are observable, for captions.
conversation.send(text: "Tell me a joke")      // a typed turn
conversation.stop()                            // ends the call and the session
```

- **One conversation per session.** `stop()` ends the call and the metered session, so the next `start()` needs a new
  full-mode session from your backend: return one from the `credentials` closure every time it is called.
- **Voice and persona.** Without options, each character talks as itself, in its own voice. `options.instructions` (a
  prompt) and `options.voice` (a Yoob voice id such as `"w1371"`) change them.
- **Billing.** Minutes are billed to your Yoob workspace at the `full` rate. The credit is reserved when the session
  opens, shrinks as real minutes are billed, and is released when the session ends. With too little credit, opening
  the session answers `402 {"code": "quota_exceeded"}` and `start()` throws `YoobError.outOfCredit`.
- **Call host.** The call opens only on `https://*.yoob.com` (`options.liveHosts` to run your own console).
- **Errors.** If Yoob refuses or ends the call, `lastError` is `.voiceSession(code:message:)`, and its
  `localizedDescription` is a message you can show the user.

The microphone stays open while the character speaks, so the user can interrupt it; iOS voice processing removes the
character's voice from what is captured. When the user starts talking, the reply stops and the model is told exactly
how much of it was heard.

Add `NSMicrophoneUsageDescription` to your Info.plist.

## Talk with it: your own OpenAI account

Use `YoobConversation` with a `clientSecret`, and OpenAI bills your account directly:

```swift
var options = YoobConversation.Options()
options.voice = "marin"
options.instructions = "You are Luna, a warm, curious companion."
options.greet = true

let conversation = YoobConversation(avatar: avatar, options: options) {
    try await MyBackend.openAIClientSecret()   // POST /v1/realtime/client_secrets on your server
}
try await conversation.start()
```

Barge-in, captions and `send(text:)` work as in full mode. The defaults come from Yoob's latency
measurements:

| Option | Default | Why |
|---|---|---|
| `turnDetection` | `.serverVAD()`, 450 ms silence | Replies start about 0.8 s sooner than `.semantic` in Yoob's measurements |
| `noiseReduction` | `far_field` | A phone held away from the face |
| `speed` | `1.08` | Natural but snappy |

In a noisy room, raise the server VAD threshold instead of muting the microphone.

## Talk with it: Gemini Live

Bring your own Gemini voice with `YoobGeminiConversation`. It has the same states, transcripts and barge-in as
`YoobConversation`.

```swift
var options = YoobGeminiConversation.Options()
options.voice = "Kore"
options.systemInstruction = "You are Luna, a warm, curious companion."
options.greet = true

let conversation = YoobGeminiConversation(avatar: avatar, options: options) {
    try await MyBackend.geminiToken()          // an ephemeral token's `name`, created on your server
}
try await conversation.start()                 // asks for the microphone
// conversation.state, .userTranscript and .assistantTranscript are observable, for captions.
conversation.stop()
```

The app never sees your Gemini API key. Your backend creates a single-use
[ephemeral token](https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens) and returns its `name`:

```js
// POST /gemini-token on your server (Node, @google/genai)
const token = await ai.authTokens.create({
  config: {
    uses: 1,
    expireTime: new Date(Date.now() + 30 * 60_000).toISOString(),    // messages stop after this
    newSessionExpireTime: new Date(Date.now() + 60_000).toISOString(), // the app must connect before this
    liveConnectConstraints: { model: "gemini-3.8-live" },              // optional: lock the model
  },
});
return { name: token.name };
```

The REST equivalent is `POST https://generativelanguage.googleapis.com/v1beta/auth_tokens` with the `x-goog-api-key`
header. Settings locked with `liveConnectConstraints` take precedence over the ones the app sends.

The conversation connects to Gemini's `BidiGenerateContentConstrained` WebSocket with the token. It converts the
microphone's 24 kHz audio to the 16 kHz Gemini expects, and plays Gemini's 24 kHz replies through the avatar.

| Option | Default | Why |
|---|---|---|
| `model` | `gemini-3.8-live` | Google's recommended low-latency native-audio Live model |
| `voice` | Gemini's choice | Any prebuilt voice name, for example `Kore` or `Puck` |
| `activityDetection.startSensitivity` | `.high` | Quick barge-in. Use `.low` in noisy rooms. |
| `activityDetection.endSensitivity` | `.high` | Ends the user's turn sooner |
| `activityDetection.silenceMS` | `450` | The silence window Yoob measured as fastest with OpenAI |
| `activityDetection.prefixPaddingMS` | `100` | Short enough for one-word answers |
| `inputTranscription` / `outputTranscription` | `true` | Captions for both sides |

`send(text:)` sends a typed turn. `goAwayTimeLeft` is set when Gemini is about to close the connection: audio-only
sessions last up to 15 minutes. Gemini doesn't report when a user turn ends, so a spoken turn goes from `.listening`
straight to `.speaking`. `.thinking` appears after `greet` and `send(text:)`.

## Microphone controls

```swift
let mic = avatar.microphone
mic.setMuted(!mic.isMuted)
Gauge(value: mic.level) { EmptyView() }               // 0...1, about 20 updates a second
ForEach(mic.inputs) { input in                         // built-in, wired and Bluetooth inputs
    Button(input.name) { try? mic.select(inputID: input.id) }
}
```

`mic.state` is `.off`, `.starting`, `.live`, `.muted` or `.failed(error)`. Using your own voice stack? Set
`mic.onAudio` (24 kHz PCM16) and call `try await mic.start()`.

## Characters

| Id | Style | Download | On device |
|---|---|---|---|
| `luna-realistic` | Photoreal | 26 MB | 34 MB |
| `luna-anime` | Anime | 40 MB | 46 MB |

Pin a version with `YoobAvatar(source, version: "2026.09.17.1")`. Without one, the newest compatible version is used,
and an update downloads only the files that changed.

## States

`avatar.phase` is observable:

| Phase | Meaning |
|---|---|
| `.downloading(progress)` | Files are downloading. `progress.fraction` goes from 0 to 1. |
| `.warming` | Files are ready; the renderer is starting. |
| `.ready` | Idle and ready to speak. |
| `.speaking` | Audio is playing and the face follows it. |
| `.failed(error)` | Loading failed. Call `prepare()` again to resume. |
| `.stopped(error)` | The session ended and the character stopped rendering. See below. |

The session stops when the workspace is out of credit (`.outOfCredit`), when Yoob refuses the session or its API key
was revoked (`.unauthorized`), or with `.sessionEnded` when a sandbox session reaches its time limit, when the
workspace is suspended, or when Yoob can't be reached for the whole outage grace window
(`.sessionEnded("unreachable")`). The avatar then stops rendering, `speak` throws the same error, and
`avatar.onSessionEnded` is called. `prepare()` opens a new session.

```swift
avatar.onSessionEnded = { error in showBanner(error.localizedDescription) }
```

If heartbeats get no answer (network errors, timeouts, 408, 429, 5xx), the character keeps rendering while the SDK
retries (after 2 s, 6 s, then every 15 s). `avatar.isHeartbeatDegraded` becomes true and `avatar.onHeartbeatDegraded`
is called; `avatar.onHeartbeatRecovered` is called when a heartbeat succeeds again. The character stops only once
`heartbeatOutageGraceSeconds` (default 600, clamped to 0...1800) have passed since the last successful heartbeat. Pass
0 to stop at the first failure:

```swift
let avatar = YoobAvatar(.cloud(character: "luna-anime") { try await MyBackend.yoobSession() },
                        heartbeatOutageGraceSeconds: 300)
avatar.onHeartbeatDegraded = { detail in showOfflineHint() }
avatar.onHeartbeatRecovered = { hideOfflineHint() }
```

`avatar.stats` counts frames shown and skipped. `avatar.lastRendererError` says why rendering stopped, if it did.

## Network

This is everything the SDK sends to Yoob:

| Call | When | Contents |
|---|---|---|
| Character files from `assets.yoob.com` | First use and version updates | Your download grant |
| `POST app.yoob.com/api/v1/sessions/heartbeat` | Every 15 s from the start of `prepare()` | Your session token |
| `POST app.yoob.com/api/v1/sessions/end` | `close()` | Your session token |
| `app.yoob.com/api/v1/live/duotone` | Full-mode conversations | The session's live token, microphone audio (16 kHz), typed text |

Heartbeats are how session time is metered. In full mode, `app.yoob.com` carries the conversation and meters its
minutes. With your own OpenAI account or Gemini, audio goes directly from the device to that provider. Call `await avatar.close()` when the character leaves the screen.
When the app returns to the foreground, `await avatar.refreshSession()` checks the session at once and opens a new one
if Yoob ended it while the app was suspended.

## Offline and shipped files

A complete download is reused when the CDN can't be reached, but `prepare()` still opens a session with your backend,
and heartbeats must reach Yoob: a character can't run without a metered session.

To ship a character inside your app, save the signed manifest the CDN serves
(`https://assets.yoob.com/v1/characters/<id>/<version>.json`, unchanged) as `character.signed.json` next to the files it
lists, and use `.local`:

```swift
let pack = Bundle.main.url(forResource: "luna-realistic", withExtension: nil)!
let avatar = YoobAvatar(.local(pack) { try await MyBackend.yoobSession() })
```

The SDK verifies the manifest signature against its pinned key and every file's SHA-256 before use, and refuses
unsigned or modified packs with `YoobError.invalidAssets`. The files load from disk, so the character works without
the CDN, but the session is opened and metered like a cloud one.

## Performance

- **Rendering:** the realistic renderer uses the GPU and falls back to the CPU if a GPU returns empty frames (the iOS
  Simulator does). Frames are composed on the GPU when a self-check against the CPU path passes.
- **120 Hz lips:** with `lipCadence` `.blend` (the default) the mouth moves at every display refresh. Add
  `CADisableMinimumFrameDurationOnPhone` (Boolean, YES) to your app's Info.plist so ProMotion iPhones can refresh at
  120 Hz; without it the blend runs at 60 Hz.
- **Test hardware:** the engines are the ones the Luna app runs on iPhone Air (A19 Pro). On a Mac with Apple silicon they render at 45–80 fps.
- **Older iPhones:** test on your oldest supported device before shipping.
- **Simulator:** it works but renders slowly. Build Release to judge motion there.

## Example

[`Examples/QuickStart`](Examples/QuickStart) is a one-screen app with both characters, a Talk button that uses Yoob
voice, and a sample greeting (an AI-generated voice). Run [`Examples/token-server`](Examples/token-server/server.mjs)
next to it:

```sh
YOOB_API_KEY=yoob_test_… YOOB_EXAMPLE_ALLOW_ANONYMOUS=1 node Examples/token-server/server.mjs   # 127.0.0.1:3100
open Examples/QuickStart/QuickStart.xcodeproj    # run the QuickStart scheme on an iOS Simulator
```

`YOOB_EXAMPLE_ALLOW_ANONYMOUS=1` lets anyone who can reach the server mint sessions, so use it only on your own
machine. Before you deploy a token server, replace `requireUser()` with your own sign-in check. The project is
generated from `project.yml` (`xcodegen generate`) only when you change it; the checked-in project opens as is.
The token server listens on 127.0.0.1, which the Simulator reaches; on a device, point `YoobTokenURL` in the
example's Info.plist at a backend the phone can reach.

## Contributing

```sh
YOOB_API_KEY=yoob_test_… YOOB_EXAMPLE_ALLOW_ANONYMOUS=1 node Examples/token-server/server.mjs
open Examples/QuickStart/QuickStart.xcodeproj   # run on an iOS Simulator
swift test                                      # unit tests; the pack tests skip without local packs
```

Use a sandbox key (`yoob_test_`) from your own workspace on the Yoob console: its sessions are never billed.
If it says you are not a member, make your organization membership public or ask an owner to add you.

## Security

- **Keys stay on your server.** A Yoob API key never belongs in an app, a web page or a repository. The API rejects
  key calls that come from a browser, and an app binary can be taken apart, so keep the key in your server's
  environment. The app only ever holds a session token, a download grant and a voice token.
- **Test keys for development.** A `yoob_test_` key opens sandbox sessions that don't use credits and are limited in
  length (a few minutes each, with a daily total). Sandbox mode comes from the key alone; there is no request flag
  for it.
- **Grants are short-lived and per character.** A download grant covers the characters its session was opened for and
  expires soon. Heartbeats may hand the SDK a renewed grant, which it uses from the next download request on. A voice
  token opens one conversation and must be used within 5 minutes.
- **Heartbeats are enforced.** They start when `prepare()` opens the session. Explicit denials stop the character at
  once: a refused session (401 or 403), an exhausted workspace (402), or a `stop` reply for out of credit, a sandbox
  limit, a suspended workspace or a revoked key (see [States](#states)).
- **An outage doesn't stop characters.** If Yoob can't be reached (network errors, timeouts, 408, 429, 5xx), the
  character keeps rendering for up to 10 minutes after the last successful heartbeat while the SDK retries, then
  stops with `.sessionEnded("unreachable")`. `heartbeatOutageGraceSeconds` changes the window (0 to 1800). The
  current download grant keeps being used meanwhile; if it expires during the outage, new downloads fail, but a
  character that already loaded keeps rendering. When Yoob ends a session that went quiet (an app suspended in the
  background), the SDK asks your `credentials` closure for a new one.
- **Signed packs only.** Downloaded and shipped packs must carry a manifest signed by Yoob, and every file is checked
  against it.
- **Voice only goes to Yoob.** A full-mode call opens only on `https://*.yoob.com` unless you set `liveHosts`.
- **What your token server must do.** The example server does each of these; keep them when you write your own:
  1. Authenticate the user before minting anything, and fail closed.
  2. Rate-limit sessions per user.
  3. Accept only the character ids you offer, and send exactly that one character. Never `"*"`.
  4. Open full-mode sessions only for users who may talk: each one reserves credit for a conversation.
  5. Build the request body yourself. Don't pass fields from the app through to Yoob.
  6. Keep the key in the server's environment, and return Yoob's response without logging tokens.

## Changes in 0.7.5

- **New Yoob hosts.** The SDK's defaults are now `https://app.yoob.com` for the API (heartbeats, the end call and
  content keys) and `https://assets.yoob.com` for character files. They apply only when a session names no `api_base` or
  `cdn_base`; a session's own hosts still win. The examples and this README call `app.yoob.com` instead of
  `api2.yoob.com`.
- **Full mode replaces Yoob voice sessions.** This README, the example token server and QuickStart talk through full
  mode (`YoobDuotoneConversation`), which needs only the session from `app.yoob.com`. The older Yoob voice session
  (`YoobConversation(avatar:options:voiceSession:)`, opened by `/api/v1/voice/sessions`) is deprecated, and the
  contributor key script is gone: use a sandbox key from your own workspace.
- **Built with Xcode 27**, with its interface in the form Xcode 26 reads (the module named through an alias, as in
  0.7.4, not Swift 6.4's module selectors). The binary is not code-signed.
- **Speech after a call plays.** Speech played after a Yoob voice or Duotone call ended no longer stays silent: the
  engine restarts without the call's input.
- **`YoobAvatar.conversation(active:)` and `isVoicePlaying` are public**, for apps that run their own conversation loop:
  between replies the character keeps moving with her lips closed instead of returning to the idle picture.

## Changes in 0.7.4

- **Requires iOS 18.** Every character's models are encrypted and load only from memory, which needs iOS 18; on iOS 17
  the package installed but no character could play. The package and the binary now declare iOS 18. Xcode still builds
  an app with a lower deployment target, with only the linker warning "building for iOS-17.0, but linking with dylib
  … built for newer version 18.0", and that app cannot load Yoob on iOS 17: set your app's deployment target to iOS 18.
- **Built with Xcode 26.** The binary is built with the oldest Xcode it supports, and its interface names the module
  through an alias instead of Swift 6.4's module selectors (`Yoob::`), so it compiles in Xcode 26 and later.
- **Render hardware (`YoobAvatar(source, renderHardware: .neuralEngine)`).** The realistic renderer can run on the
  Neural Engine for about 2.5 times less CPU at the same frame rate, after a one-time specialization per device (about
  a minute on a Mac, longer on a phone; Core ML keeps it across launches). `.gpu` stays the default; `.automatic`
  uses the Neural Engine once it is ready. `YoobAvatar.prepareNeuralEngine(character:)` specializes ahead of time and
  `isNeuralEngineReady(character:)` tells whether it has.
- **A face can hold her body still under her moving head.** Faces whose `face.json` sets `headMotion` or `voiceMotion`
  keep the body on the still idle face's while the head moves; `idleMotion` plays the head path whenever she is
  silent. Every current CDN face, Astrid included, looks as in 0.7.3.
- **Signed by Yoob AI Ltd** (team R2D83Q685G) instead of Smart Media Internet Marketing Ltd.

## Changes in 0.7.3

- **Her head sways as in the Luna app.** The whole-picture motion (sway, tilt, breathing, voice nods) starts afresh when
  she is ready, when a conversation's call goes live and when it ends, as the Luna app's screens do. It had started when
  the view first drew her, so through a reply she could lean the other way (up to 15 px at her nose). Timed alike, her
  head now follows the Luna app's within about 1 px.

## Changes in 0.7.2

- **Astrid as the Luna app shows her.** Her still idle face now follows her speaking head, as on the Luna app's call
  screen: it glides onto her head as her speaking face fades in, follows it while she speaks, and glides back to its own
  place after her speaking face has faded out, so a fade never shows two heads. Her frames are drawn as rendered.
- **Separate fade out (`YoobAvatarView(avatar, fade: 0.22, fadeOut: 0.35)`).** `fadeOut` sets the speaking → idle
  cross-fade (default: `fade`). The QuickStart example uses the Luna app's 0.22 s in and 0.35 s out.

## Changes in 0.7.1

- **The classic anime character loads again.** `luna-anime` stopped at load with "The data couldn't be read because it
  is missing" (its models manifest has an entry without notes, which the SDK required).
- **A smaller binary.** The xcframework no longer carries debug symbols, its local symbols are stripped, and it exports
  only the `Yoob` module's symbols: the zip is 2.4 MB instead of 9.5 MB. The public API is unchanged.
- **Neutral pack file names.** An anime pack may name its audio encoder `AudioEncoder1024_fp16` and its audio features
  `bundle/feats_audio_l15.bin`; the current packs keep loading.

## Changes in 0.7.0

- **Encrypted characters.** The SDK downloads and plays the encrypted iOS packs of Astrid (`r2-f08-astrid`) and Luna
  (`luna-realistic`, `luna-anime-v2`). Each CDN chunk is opened with the session's content keys and each model file
  with the release key the Yoob console issues (`POST {api_base}/api/v1/sessions/keys`), requested only while a model
  file is still missing and kept in memory only. Model files are sealed again with a key kept in this device's Keychain;
  their plaintext never reaches disk, and they load from memory (iOS 18 or newer). Plaintext packs play as before. A
  refused key has its own error (`contentKeyNotIssued`, or an explicit error for the release limit and missing keys).
- **Astrid as the Language Companions app shows her:** her `face.json` lip lead and gain, her head path and blinks,
  and her blinking still face.
- **Luna's lips** use her packs' context encoder (3.2 s of past audio per lip frame, as in the Luna app).
- **Talk in Yoob's voice.** With a full-mode session, a conversation uses the Duotone voice; captions drop its delivery
  marks.
- **Install from the binary package** `https://github.com/Yoob-com/yoob-ios-sdk-spm` (see [Install](#install)).

## Changes in 0.6.1

- Luna keeps her sharpened lips (and her measured lip lead and articulation) with the pack the CDN serves since
  2026-10-15, whose identity is opaque (`c-198d5a14`) rather than her training name. 0.6.0 matched only the old name, so
  her lips were drawn unsharpened and pasted over the whole square. Nothing else changes.

## Changes in 0.6.0

The realistic engine is brought up to date with the Luna app's avatar runtime (September 24-25). Measurements are the
Luna app's, on the same renderer and model files, on an iPhone Air and on a Mac.

- **Lips on the voice.** Each character's lip model moves the mouth ahead of its audio (it learned the timing of its
  training footage: 83 ms for the realistic Luna, measured), so frames are now shown that much later, and
  the silence seal is judged on the audio heard when the frame shows. Frames also wait for the audio output's own
  latency (large over Bluetooth). The classic anime character is shown 30 ms later.
- **Smoother mouth motion (`lipCadence`, default `.blend`).** Each new lip frame fades in over the one before across one
  frame's time, centred on the moment its audio is heard, and the view refreshes at the display rate while it fades.
  At 120 Hz the change per refresh is far steadier (coefficient of variation 0.47 against 2.21 for whole frames shown
  at 60 Hz) with the same timing. `.steps` shows whole frames as before.
- **Sharper lips (realistic Luna).** The model's mouth picture is sharpened on the GPU and only her mouth, jaw and
  chin are taken from it; the rest of the face square is the host video's own full-resolution pixels. Mouth detail
  matches her real footage (high-frequency energy 1.93 against 1.37 before; footage 1.93) and the face square no longer
  shimmers against the host (0.33 grey levels a frame, from 2.5). Measured cost on a Mac: 0.06 ms a frame.
- **Fuller articulation (realistic Luna).** The lip model's audio window is pushed 1.2 times further from the
  closed-mouth window (a sealed frame stays exactly closed). Against her real footage: aperture correlation .701 to
  .708 and measured lip-sync confidence 5.21 to 5.36, drawn with 240 ms of audio ahead as the SDK now draws.
- **Faster start.** Frames are drawn once 240 ms of the audio after them is in (instead of 525 ms), three at a time,
  the rest of the window as silence, so the voice starts about 285 ms sooner. A frame differs from the full-window one
  by 1.7 grey levels on average.
- **Low-latency lips (`lipSync`, `instantVoiceDelay`).** `.instant` draws each frame on its own once the face's lead plus
  one frame of audio is in (120 ms for the realistic Luna, the rest mirrored), and with `speak` the voice plays 127 ms
  after it arrives and never waits for a frame. Against her footage the lips score like the full window (aperture
  correlation .691 against .699). `.automatic` (default) uses it for `appendAudio`, where your player never waits.
- **Calmer phrase ends.** The silence seal closes over four frames even when little audio is known ahead, and a lip
  frame across a jump in the head's footage fades over 120 ms.
- **Runtime fixes:** each Core ML prediction runs in its own autorelease pool (a long run of predictions otherwise kept
  every output buffer); the host video keeps its decoded group of pictures, so walking backwards stays at frame rate;
  the lip pipeline encodes the next audio while it renders the frame before.
- **Newer lip models.** Realistic-engine characters can use a 288 px lip model, a per-host paste matte with a steady
  paste in time, crops derived on the device from the host video (cached under Caches/Yoob/Crops), and a head path read
  from the pack (`CharacterManifest.calmWindow`). A character manifest may set `lipLeadMilliseconds` and
  `articulationGain`; older SDKs ignore these fields.

New API (all additive): `YoobAvatar.lipSync` (`LipSync`: `.automatic`, `.standard`, `.instant`),
`YoobAvatar.instantVoiceDelay`, `YoobAvatar.lipCadence` (`LipCadence`: `.steps`, `.blend`),
`CharacterManifest.calmWindow`, `.lipLeadMilliseconds`, `.articulationGain`.

## Changes in 0.5.0

Fixes and motion from the Luna app, which runs the same realistic engine:

- **Smoother voice on a slow network.** When the audio buffer runs dry mid-sentence, playback now waits for a 160 ms
  cushion before resuming (a short tail still starts after 120 ms). Resuming on each small packet made a jittery
  connection sound choppy and robotic.
- **Speaking motion.** Realistic characters nod on stressed syllables and sway a little more while they talk, and
  breathe in silence: one whole-picture transform of a few points, driven by the voice being heard. Turn it off with
  `YoobAvatarView(avatar, speakingMotion: false)`; it is always off with Reduce Motion. `YoobAvatar.voiceLevel` exposes
  the level it follows.
- **More resilient rendering.** A host-video frame the decoder misses reopens the reader once instead of failing the
  face, and a renderer whose frames stop being shown drops the oldest instead of stopping.

## Changes in 0.4.1

- A Yoob outage no longer stops characters after three failed heartbeats. Heartbeats that get no answer (network
  errors, timeouts, 408, 429, 5xx, unreadable replies) are retried after 2 s, 6 s, then every 15 s while the character
  keeps rendering. The session ends with `.sessionEnded("unreachable")` only when `heartbeatOutageGraceSeconds`
  (new `YoobAvatar` init parameter and property, default 600, 0...1800) has passed since the last successful
  heartbeat. Denials (401, 402, 403, terminal `stop` reasons) still stop the character at once, even during an outage.
- New `avatar.isHeartbeatDegraded`, `avatar.onHeartbeatDegraded` and `avatar.onHeartbeatRecovered`. Without
  `onHeartbeatDegraded`, the SDK logs a warning (subsystem `com.yoob.sdk`).

## Changes in 0.4.0

- `.local(url)` is now `.local(url, credentials:)`. Local packs need `character.signed.json` and a metered session.
- Heartbeats start with `prepare()` and are enforced. New `YoobError.sessionEnded`, `avatar.onSessionEnded` and
  `avatar.refreshSession()`.
- Heartbeat replies may carry a renewed download grant (`download_token`, `download_token_expires_at`; `grant` and
  `grant_expires_at` are also accepted); older replies still work. `stop` with `sandbox-limit` or `suspended` ends the
  session as `.sessionEnded`, and `key-revoked` as `.unauthorized`.
- Yoob voice connects only to `wss://*.yoob.com` unless `YoobConversation.Options.voiceHosts` says otherwise.
- The example token server fails closed without auth, allowlists characters (`YOOB_CHARACTERS`, default
  `luna-realistic,luna-anime`), rate-limits each user, always pins the voice prompt, and never passes request fields
  such as `is_sandbox` through.

## License

The SDK source is Apache-2.0. Character model files are licensed separately and are not in this repository; see
[NOTICE](NOTICE).
