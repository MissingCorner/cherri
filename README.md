# Cherri — Live Meeting Interpreter for macOS

Cherri (formerly MIAgent) sits between your meeting app (Zoom, Teams, Meet, …) and your real
audio devices, and runs both directions of the conversation through
**`gpt-realtime-translate`** — OpenAI's dedicated simultaneous-interpretation
model. It is translation-only *by design* (it cannot be prompted, cannot
answer questions, and streams translated speech while the speaker is still
talking), auto-detects the spoken input language (70+ languages), and outputs
in 13 target languages.

```
                        ┌─────────────────────────────────────────────┐
 Zoom / Teams           │                 Cherri app                 │
 ┌──────────────┐       │                                             │
 │ Speaker  ────┼──► Interpreter Line Output ──► GPT Realtime (A) ──┐ │
 │ (virtual)    │       │        │                                  │ │
 │              │       │        └── original (ducked) ──► mix ◄────┘ │──► Your real
 │              │       │                                  │          │    speakers
 │ Microphone ◄─┼── Interpreter Line Input ◄── GPT Realtime (B) ◄──── │◄── Your real
 │ (virtual)    │       │                                             │    microphone
 └──────────────┘       │        Live captions in your language       │
                        └─────────────────────────────────────────────┘
```

* **Inbound**: the meeting app plays into the virtual *Interpreter Line
  Output* device. Cherri captures it, translates it into your language, and
  plays it to your real speakers as an overdub — the original audio is ducked
  (lowered) while the translation speaks, so you keep the room's tone but
  hear the translation clearly. Captions of the translation appear in the UI.
* **Outbound**: Cherri captures your real microphone, translates what you
  say into the meeting language, and plays it into the virtual *Interpreter
  Line Input* device, which the meeting app uses as its microphone. In
  **conference mode** (default) the meeting hears your real voice
  continuously, dimmed while the interpreter speaks over it — like a
  conference interpreter feed. Toggle it off ("My voice" section) and the
  meeting hears only the translated voice.

## Components

| Path | What it is |
|---|---|
| [Driver/MIAgentAudio.c](Driver/MIAgentAudio.c) | Core Audio HAL virtual driver (`AudioServerPlugIn`): two loopback pairs — each a visible one-directional device for meeting apps plus a hidden companion (tap/feed) used by Cherri, so app pickers only show the correct direction |
| [App/Sources](App/Sources) | SwiftUI app: audio routing, ducking mix, Realtime API sessions, captions |
| [Makefile](Makefile) | Builds everything with Command Line Tools only (no Xcode needed) |

## Requirements

- macOS 26+ (Apple Silicon; edit `TARGET` in the Makefile for Intel)
- Xcode Command Line Tools (`xcode-select --install`)
- An OpenAI API key with Realtime API access

## Build & install

Build the driver and the app:

```bash
make
```

Install the virtual audio driver (asks for your password; restarts Core Audio —
any audio playing on the Mac will glitch for a second):

```bash
make install-driver
```

After this, **System Settings → Sound** shows two new devices:
*Interpreter Line Output* and *Interpreter Line Input*.

Launch the app:

```bash
make run
```

## Using it in a meeting

1. In Cherri: pick the **meeting language** and **your language**, your real
   microphone and real speakers/headphones, paste your OpenAI API key, and
   press **Start**.
2. In Zoom/Teams audio settings:
   - **Speaker** → `Interpreter Line Output`
   - **Microphone** → `Interpreter Line Input`
3. Talk normally. You hear the meeting overdubbed in your language (original
   ducked underneath) with live captions; the meeting hears your speech
   translated into their language.

Keep your Mac's *system* default output on your real speakers — only the
meeting app should point at the virtual devices.

## Translation providers & engines

Two providers, selectable in **Translation service** (each with its own API
key, stored in the keychain):

- **OpenAI** — the two engines below.
- **Google Gemini** — `gemini-3.5-live-translate-preview` via the Gemini Live
  API: continuous streaming translation, auto-detected input language (70+),
  adaptive voice, target language per direction. Like OpenAI's translate
  model it accepts no prompts/context — interpreter-only by design. Audio in
  at 16 kHz PCM16, out at 24 kHz.

With OpenAI selected, two engines are available in **Meeting context**:

| | Fast (default) | Context-aware |
|---|---|---|
| Model | `gpt-realtime-translate` | `gpt-realtime-2.1` |
| Latency | Streams mid-sentence | Turn-based (waits for pauses) |
| Voice | Adapts to each speaker | Fixed voice |
| Meeting context / glossary | Not supported by the model | Injected into the interpreter prompt (terminology only) |
| Strictness | Enforced by the model itself | Enforced by a hardened prompt |

Use context-aware for jargon-heavy meetings (product names, legal/medical
terms, participant names); use fast for everything else.

## Strict-translation guardrails

Both directions use the dedicated Realtime translation endpoint
(`wss://api.openai.com/v1/realtime/translations`) with
`gpt-realtime-translate`. Strictness is enforced by the model itself: it was
trained exclusively as an interpreter, supports no custom prompting or voice
selection, and only ever emits translation. Questions in the audio get
translated, never answered.

## Notes & current limitations

- **Latency**: `gpt-realtime-translate` streams translation *while* the
  speaker talks (200 ms audio chunks), so the overdub trails by only enough
  context to translate accurately — much tighter than turn-based VAD models.
- **Echo**: the mic is captured through macOS's VoiceProcessingIO unit
  (the FaceTime echo canceller) with your selected output device as the
  reference, so the overdub playing from open speakers is subtracted from the
  mic signal before it reaches the outbound translator. If voice processing
  can't start for a device combo, the app falls back to plain capture and
  says so in the status line — use headphones in that case.
- The virtual devices are fixed at 2ch / 44.1 or 48 kHz, Float32.
- Two Realtime sessions run while started; mind API cost for long meetings.
- The driver is ad-hoc signed — fine for your own machine; distributing to
  other Macs needs a Developer ID signature + notarization.

## Release packaging

```bash
make package          # build/Cherri-<version>.pkg — app + driver installer
```

The pkg installs Cherri.app to /Applications and the driver to
/Library/Audio/Plug-Ins/HAL, restarting Core Audio at the end. Signing is
automatic: with **Developer ID Application/Installer** certificates in the
keychain (Apple Developer Program) it produces a distribution-ready package —
then notarize it:

```bash
APPLE_ID=you@example.com TEAM_ID=XXXXXXXXXX APP_PASSWORD=app-specific-pw make notarize
```

Without Developer ID certs it signs with the best local identity (e.g. the
self-signed "Cherri Dev"): fine for this Mac, but Gatekeeper blocks it on
other machines. The app is signed with hardened runtime plus the
`audio-input` entitlement either way.

## Uninstall

```bash
make uninstall-driver
```
