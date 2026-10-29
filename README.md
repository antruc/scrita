# Scrita

**Record audio and get a transcript, with who said what when several people
speak. No cloud: everything happens on the phone. Internet is used once, to
download the voice model.**

![Android 11+](https://img.shields.io/badge/Android-11%2B-3DDC84?logo=android&logoColor=white)
![Flutter 3.44+](https://img.shields.io/badge/Flutter-3.44%2B-02569B?logo=flutter&logoColor=white)
![Offline](https://img.shields.io/badge/transcription-offline-success)
![sherpa-onnx](https://img.shields.io/badge/engine-sherpa--onnx-orange)
[![License: GPL v3+](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

Scrita is an Android app that turns speech into text: a voice note, a
lecture, a meeting or an interview, with one speaker or up to six. It records
(or imports an audio file), tells the voices apart and produces a timestamped
transcript:

```
Date: 2026-10-09 10:32
Duration: 00:42:17
Participants: Interviewer, Lucy

[00:00:04] Interviewer:
Good morning, thanks for coming. Could you introduce yourself?

[00:00:09] Lucy:
Sure, my name is...
```

## Contents

- [Features](#features)
- [Using the app](#using-the-app)
- [Building and installing](#building-and-installing)
- [How it works](#how-it-works)
- [Development](#development)
- [Known limitations](#known-limitations)
- [Roadmap](#roadmap)
- [License](#license)
- [Credits](#credits)

## Features

- **Private:** the audio never leaves the phone. Internet is used only to
  download the voice model once from this repository's GitHub releases. No
  accounts, no ads and no analytics.
- **Speaker separation:** tells 1 to 6 voices apart and lets you name them.
- **25 languages, one model:** NVIDIA Parakeet TDT 0.6B v3 recognizes
  Spanish, English and 23 other European languages, with punctuation and
  capitalization, and detects the language on its own.
- **Record or import:** record in the app, open a WAV, OPUS, OGG, M4A,
  MP3, AAC, FLAC, AMR or 3GP file, or share a voice note straight from
  WhatsApp or any other app.
- **Runs in the background:** records and transcribes with the screen off,
  with progress shown in a notification.
- **Edit the result:** fix a paragraph's text, change its speaker, join or
  delete paragraphs, or select words and assign them to another speaker, with
  undo. Play back the original audio while you review.
- **Export:** copy or share the `.txt`, or save it to `Documents/Scrita`
  together with the audio. The app records 48 kHz WAV; when saved to
  Documents it is converted to M4A (default, ~29 MB per hour) or kept as WAV.
  Imported files keep their own format.
- **Backup:** one `.zip` with all audio, transcripts and settings, and a
  restore option for moving to a new phone.
- **Customizable:** recording modes (clean voice, noise reduction, group,
  unprocessed), light/dark theme, wallpaper colors by default (Material You,
  Android 12+) or a fixed palette, and a Spanish or English interface that
  follows the phone's language.

## Using the app

1. Open the app. The first launch asks for the microphone and notification
   permissions, then downloads the voice model (~670 MB) while a short
   tutorial plays. It checks free space first, and asks before using mobile
   data. The tutorial is in **Settings → View
   tutorial**.
2. Tap **Record** and allow the microphone and notification permissions.
   You can turn the screen off or switch apps; recording continues.
3. Tap **Stop recording**. The audio appears under **Not transcribed**.
4. Open it, tap **Transcribe** and choose how many people speak. The
   notification shows the progress.

   To transcribe an existing file instead, tap the audio file icon
   (**Transcribe an audio file**) on the home screen, or share it to
   **Scrita** from another app. It goes straight to step 4.
5. When it finishes, the transcript moves to **Transcripts**. Tap
   **Name participants** to name them and tap a paragraph to correct it.
6. Share, copy or **Save to Documents** from the transcript's menu.

> Some brands (Xiaomi, Huawei, Oppo, Vivo, some Samsung) kill background
> apps even with a notification. If recording stops with the screen off, set
> **Settings → Apps → Scrita → Battery → Unrestricted**. See
> [dontkillmyapp.com](https://dontkillmyapp.com) for your brand.

## Building and installing

There is no prebuilt APK yet: build it from source. It takes about 15 minutes
the first time, most of it Gradle and model downloads.

### Requirements

| What | Version / size |
|---|---|
| [Flutter](https://docs.flutter.dev/get-started/install) | 3.44 or later |
| Android SDK | Platform API 37, Build-Tools, Command-line Tools, Platform-Tools |
| JDK | The one bundled with Android Studio (JBR 21) is enough |
| Phone | Android 11 (API 30) or later, arm64 recommended |
| Disk | ~6 GB free (Flutter, NDK, Gradle cache, ~710 MB of models) |

Linux, macOS and Windows all work. Run `flutter doctor` and make sure
**Flutter** and **Android toolchain** pass.

### Build

1. Clone the repository:

   ```bash
   git clone https://github.com/antruc/scrita.git
   ```

2. Enter it and fetch the Dart packages:

   ```bash
   cd scrita && flutter pub get
   ```

3. Fetch the models:

   ```bash
   dart run tool/fetch_models.dart
   ```

   The small models (diarization and VAD, ~42 MB) go into `assets/models/`
   and are bundled into the APK. The script also downloads the Parakeet
   archive, but only to stamp its sizes and hashes in `lib/models.dart` and
   to leave the files in `build/release-models/` for publishing: Parakeet is
   not in the APK. The app downloads it (~670 MB) on first launch. Every
   download is checked against `tool/models.lock.json`, which the first run
   creates.

4. Build one APK per CPU architecture:

   ```bash
   flutter build apk --release --split-per-abi
   ```

The APKs land in `build/app/outputs/flutter-apk/`. Most current phones use
`app-arm64-v8a-release.apk`.

### Install

1. On the phone, enable **Developer options** (tap **Build number** 7 times)
   and turn on **USB debugging**.
2. Connect it over USB and accept the debugging prompt.
3. Install the APK:

   ```bash
   adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
   ```

Or build and launch in one step with `flutter run --release`. Debug builds
are several times slower.

### Troubleshooting

| Symptom | Fix |
|---|---|
| The app says the models are missing | Run `dart run tool/fetch_models.dart` and rebuild |
| Android licenses not accepted | Install **Android SDK Command-line Tools**, then `flutter doctor --android-licenses` |
| Gradle complains about the Java version | `flutter config --jdk-dir <Android Studio>/jbr` |
| Gradle runs out of memory | Set `org.gradle.jvmargs=-Xmx4g` in `android/gradle.properties` |
| `adb devices` shows `unauthorized` | Unlock the phone and accept the debugging prompt |

## How it works

```
WAV 48 kHz ──► diarization ──► VAD ──► ASR per phrase ──► speaker per word ──► .txt + .json
               (who speaks?)  (phrases) (what is said?)   (splits the phrase on a change)
```

1. **Recording** to 48 kHz mono WAV, straight to disk. Imported formats are
   decoded with Android's codecs. Before transcribing, audio is resampled to
   16 kHz with sherpa-onnx's resampler.
2. **Diarization** of the whole recording with pyannote segmentation 3.0 and
   TitaNet small embeddings. Giving the number of participants makes
   clustering much more reliable.
3. **Silero VAD** splits the recording into phrases. Past 20 s it ends a
   phrase at the next dip in speech, which can fall mid-word. This removes
   the silences where models hallucinate.
4. **Speech recognition** of each phrase with Parakeet TDT 0.6B v3.
5. **Speaker per word:** each word takes the diarization speaker at its
   timestamp, and a phrase is split where the speaker changes.
6. A `.json` (to reopen and edit) and the `.txt` are saved.

Everything runs in a separate isolate, so the interface never freezes. On the
test phone, transcribing takes about 0.22× the length of the recording.

### Models

| Use | Model | Size |
|---|---|---|
| Speech recognition | NVIDIA Parakeet TDT 0.6B v3, int8 (`sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8`) | ~670 MB |
| Speaker embedding | NVIDIA NeMo TitaNet small (`nemo_en_titanet_small`) | ~40 MB |
| Speaker segmentation | `sherpa-onnx-pyannote-segmentation-3-0` | ~1.5 MB |
| Voice activity detection | Silero VAD | ~0.6 MB |

The models are not in the repository. `tool/fetch_models.dart` downloads them
from the [sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases).
The small ones go into `assets/models/` and are bundled into the APK.
Parakeet is too big for it: the app downloads it on first launch from the
`models-v1` release of this repository (`modelsUrl` in `lib/models.dart`),
resumes a cut download and checks each file's SHA-256.

To publish the model (once, or with a new tag when it changes). The app's own
releases live in the same repository under their own tags; `--latest=false`
keeps the model from showing as the latest release:

```bash
gh release create models-v1 --latest=false --title "Voice model v1" build/release-models/asr-encoder.int8.onnx build/release-models/asr-decoder.int8.onnx build/release-models/asr-joiner.int8.onnx build/release-models/asr-tokens.txt
```

## Development

```bash
flutter run          # debug mode: r = hot reload, R = hot restart, q = quit
flutter analyze      # linter (flutter_lints)
dart format .        # formatter
flutter test         # pure logic tests
```

| Path | What it does |
|---|---|
| [lib/main.dart](lib/main.dart) | App start, theme (Material You or fixed palette) and language |
| [lib/pipeline.dart](lib/pipeline.dart) | Diarization → VAD → ASR in an isolate |
| [lib/transcript.dart](lib/transcript.dart) | Turns, cleanup, resampling and .txt/.json format (pure logic, tested) |
| [lib/models.dart](lib/models.dart) | Downloads Parakeet, copies the bundled models to disk, picks threads and builds the sherpa-onnx configs |
| [lib/recorder.dart](lib/recorder.dart) | 48 kHz mono WAV recording |
| [lib/audio.dart](lib/audio.dart) | Channel to `MainActivity.kt`: import decoding, M4A encoding, shared audio, free space, network type |
| [lib/background.dart](lib/background.dart) | Foreground service (`flutter_foreground_task`) |
| [lib/store.dart](lib/store.dart) | Transcript history and export to `Documents/Scrita` |
| [lib/backup.dart](lib/backup.dart) | Full .zip backup and restore |
| [lib/prefs.dart](lib/prefs.dart) | Settings (`shared_preferences`) and the learned time estimate |
| [lib/l10n.dart](lib/l10n.dart) | Spanish/English strings, inline as `tr('es', 'en')` |
| [lib/screens/](lib/screens/) | Onboarding (permissions, model download, tutorial), home, transcript viewer/editor and settings |
| [tool/fetch_models.dart](tool/fetch_models.dart) | Downloads the models and stamps their sizes, hashes and version in `lib/models.dart` |
| [tool/make_icon.py](tool/make_icon.py) | Draws the launcher icons in `assets/icon/`; apply them with `dart run flutter_launcher_icons` |
| [android/app/src/main/](android/app/src/main/) | Manifest (permissions, foreground service) and `MainActivity.kt` (audio decoding, share target) |

Do not edit `modelsVersion` in `lib/models.dart` by hand:
`tool/fetch_models.dart` rewrites it, and a new value makes phones copy the
models again.

In debug and profile builds, each transcription ends with a timing summary
(also in `flutter logs`). Measure with `flutter run --profile`.

<details>
<summary><b>Foreground service</b></summary>

- Recording starts a `microphone` type service. Android 14+ requires starting
  it with the app visible and the microphone permission granted, which is
  why it starts right before recording.
- Transcribing an imported audio uses the `dataSync` type, since there is no
  microphone. Android 15 limits that type to 6 h per day.
- While the service runs, the back button minimizes the app instead of
  closing it. Closing it from "recents" stops the service (`stopWithTask`).

</details>

<details>
<summary><b>Tuning</b></summary>

- **Threads:** the app counts the phone's big cores (faster than the slowest
  cluster) and uses at most 4. If it cannot read the frequencies, it uses 2.
- **VAD** in `lib/models.dart`: `vadThreshold` (0.1, low so quiet and far
  voices are kept), `vadMinSilence` (0.5 s) and `vadMaxSpeech` (20 s).
- `mergeGap` in `buildTurns`: the longest pause (in seconds) that joins two
  fragments of the same person.
- `speakerMinRun` in `lib/transcript.dart` (1 s): the shortest run split off
  a phrase as another speaker. Raise it if stray words land on the wrong
  speaker; lower it if a short "yes" from the other one is lost.

</details>

## Known limitations

- **Memory:** diarization needs the whole audio at 16 kHz, about 230 MB per
  hour of recording.
- When two people talk at once, the fragment goes to only one of them.
- Numbers and proper names are sometimes wrong: review them by hand.
- Speaker boundaries can be off by about one word, and occasionally a whole
  paragraph gets the wrong speaker. Fix it with **Assign to** in the editor.
- Imported files of 60 s or more are decoded in 3 parallel parts; the text
  may differ slightly at a seam from a single-pass decode.

## Roadmap

- [ ] Export to .docx and .srt besides .txt.
- [ ] Play a single paragraph's audio while editing it.

## License

Copyright (C) 2026 antruc

Scrita is free software: you can redistribute it and/or modify it under the
terms of the [GNU General Public License](LICENSE) as published by the Free
Software Foundation, either version 3 or (at your option) any later version
(`GPL-3.0-or-later`). It comes with no warranty.

The models are not part of the repository and have their own licenses. If
you distribute an APK that includes them, or host them for download, you must
comply with those licenses too.

### Model licenses

| Model | License |
|---|---|
| NVIDIA Parakeet TDT 0.6B v3 | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) |
| NVIDIA NeMo TitaNet small | Apache-2.0 (the [NeMo Toolkit](https://github.com/NVIDIA/NeMo/blob/main/LICENSE) license, per its [NGC page](https://catalog.ngc.nvidia.com/orgs/nvidia/nemo/models/titanet_small)) |
| pyannote segmentation 3.0 | MIT |
| Silero VAD | MIT |

Parakeet's CC-BY-4.0 allows commercial use and redistribution with
attribution and a note of changes. Scrita gives both in [NOTICE](NOTICE),
also shown in the app under **Settings → About → View licenses**. Anyone
redistributing an APK with the model must keep that NOTICE.

### Package licenses

| Package | License |
|---|---|
| Flutter SDK (`flutter`, `flutter_localizations`) | BSD-3-Clause |
| `sherpa_onnx` (includes onnxruntime, MIT) | Apache-2.0 |
| `record`, `path_provider`, `path`, `share_plus`, `shared_preferences`, `ffi`, `url_launcher` | BSD-3-Clause |
| `file_picker`, `flutter_foreground_task`, `audioplayers`, `archive` | MIT |
| `dynamic_color` | Apache-2.0 |

All are compatible with GPL-3.0. The app lists every package's license text
under **Settings → About → View licenses**, including the Silero and
pyannote MIT texts that `tool/fetch_models.dart` downloads with the models.

## Credits

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) by k2-fsa: the
  on-device speech engine, and the ONNX conversions of every model.
- [NVIDIA NeMo](https://github.com/NVIDIA/NeMo): Parakeet TDT 0.6B v3 and
  TitaNet small.
- [pyannote.audio](https://github.com/pyannote/pyannote-audio): speaker
  segmentation.
- [Silero VAD](https://github.com/snakers4/silero-vad): voice activity
  detection.
- [Flutter](https://flutter.dev) and the package authors listed above.
