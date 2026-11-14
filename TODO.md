# TODO

Status on 2026-11-14. Two open topics, in this order:

1. **Wrong language and lost text.** Mostly fixed and tested on the phone.
   One failure is left: a short piece that comes out in English.
2. **Parakeet Ultra.** A retrained model that may transcribe better. Nothing
   changed in the app, and the conversion script is still to be written.

The M4A export was audited along the way and is not the cause of anything
below. Keep the option.

## Next action

Record 1 minute reading a different Spanish text, transcribe it in a debug
build, tap Copy on the `Debug: timing summary ready` notice and read the
`phrases` list.

- **No English:** the failure left is tied to a few words of the test text.
  Stop here.
- **English again:** measure Parakeet Ultra with the same WAVs (see
  "Parakeet Ultra", plan step 2).

---

## 1. Wrong language and lost text

### Problem

Reading Spanish without pauses, the transcript mixed in English ("The gato
is the animal domestic most popular mascot") and dropped whole sentences.
It was first noticed when a recording saved to Documents as M4A and imported
back gave a different text than the original WAV, so M4A was the first
suspect.

### Cause

Two separate things:

1. **Long phrases.** The VAD (threshold 0.1) rarely finds a 0.5 s pause in
   continuous reading, so phrases end by the `vadMaxSpeech` cap. The cap is
   soft: past 20 s sherpa-onnx waits for a 0.1 s dip in speech, which took up
   to 51.7 s more. Parakeet v3 degrades with phrase length:

   | VAD phrase | Result |
   |---|---|
   | 6.8 to 21.9 s | Good |
   | 23.6 to 27.6 s | Unstable: from good to mixed languages |
   | 31.3 to 71.7 s | English and lost sentences |

2. **No language input.** Parakeet v3 detects the language again in every
   piece it decodes, and it cannot be told the language: the exported
   encoder, decoder and joiner only take audio and decoder state. A piece
   that starts with something ambiguous can flip to English at any length.
   In the test text, "por su" is heard as "for sure" and "en 2021" as
   "in 2021". The question is open in the NeMo repository with no answer
   from NVIDIA and no confirmed workaround. A user there reports that
   blocking other languages' tokens after decoding damages clean speech.

M4A is not a cause: the original WAV fails too. The M4A only shifts the audio
by a few milliseconds, which moves the VAD cuts and so changes which phrases
come out long.

### Tests (phone, debug build)

One speaker reading a Spanish text about cats. Raw results are in
`Downloads/3min.txt`, `Downloads/1min.txt` and `Downloads/multiple.txt`,
outside the repository.

| Audio | Before | With the cut | With the cut and the retry |
|---|---|---|---|
| 1 min WAV | English, 2 sentences lost | Complete, Spanish | Same |
| 1 min M4A | All English, half lost | One 18.5 s piece in English | Same |
| 3 min WAV | One sentence lost | Still lost: 11.9 s decode to "Especially if" | Recovered |
| 3 min M4A | One piece in English | Complete | Same |

- Eight more recordings of 8 to 49 s confirmed the length table above.
- With identical cuts, a 26 s phrase gives different text from WAV and from
  M4A, and phrases of 20 to 22 s do not. Near the limit, any tiny change in
  the audio changes the text.
- Never done: transcribing the same WAV twice to check the pipeline is
  deterministic.

### Implemented

1. **Cut long phrases.** `quietCuts` (`lib/transcript.dart`) splits a phrase
   longer than `asrMaxPhrase` (22 s) into even pieces. Each cut moves up to
   `asrCutSlack` (1.5 s) to the quietest 0.1 s, so it does not land
   mid-word. `drain()` in `lib/pipeline.dart` decodes each piece.
2. **Retry on too few words.** A piece of at least `asrRetryMinSeconds`
   (8 s) that decodes to fewer than `asrRetryWordRate` (0.5) words per second
   is decoded again in two halves. The halves are kept only if they give more
   words. Normal reading is about 2 words per second; the failing piece gave
   2 words in 11.9 s.
3. **Debug phrase list.** The timing summary ends with one line per decoded
   piece: `47.8 s +5.5 s: first 40 characters... (retry)`. `phrases decoded`
   counts pieces; `longest` and `within 0.5 s of the cap` still measure VAD
   phrases.
4. **M4A bitrate** is 64 kbps per channel instead of a fixed 64 kbps. No
   effect on the app's own mono recordings.

All four constants are in `lib/models.dart` with the measurements they come
from. `quietCuts` has a test in `test/transcript_test.dart`; the retry has
none because it needs the real model.

### Still open

- **A piece in English with plenty of words.** 1 min M4A, 36.7 s +18.5 s:
  starts at "In 2021" and stays in English, losing half a sentence. Counting
  words cannot see it.
- **Stray words inside good pieces:** "is Estados Unidos", "in 2021",
  "masjot".

### What could be done

Most promising first.

1. **Test another text** (the next action above). Tells whether the English
   is tied to this text.
2. **Measure Parakeet Ultra on the same WAVs.** Same architecture, so it has
   no language input either. It may flip less often; nobody has measured it.
3. **Lead-in audio.** A user in the NeMo discussion saw the model pick the
   right language when the audio starts with a clear phrase. Each piece
   could be decoded with the last seconds of the previous one in front, and
   the repeated words dropped by their timestamps. About 20 lines, unproven.
4. **Language check on the output.** Compare each piece's language with the
   rest of the transcript and retry the odd one in halves. Needs a language
   detector for 25 languages, and interviews that really mix languages would
   trigger it.
5. **A model with a language setting** (Whisper, Canary). Removes the cause.
   A big change: another model, another download size, another speed.
6. **Compensate the AAC encoder delay.** The decoded M4A is shifted an
   estimated 33 to 44 ms (not measured). Fixing it would make an imported
   M4A cut like its WAV. Low value now that long phrases are cut.

### M4A audit (code reading)

Flow: `exportToDocuments` (`lib/store.dart`) -> `encodeM4a` (`lib/audio.dart`)
-> `encodeM4a` in `MainActivity.kt`. On import: `decodeToWav` ->
`decodeParts` -> `runPipeline`.

- No error found in the WAV header, timestamps, end of stream or muxer.
- 64 kbps mono at 48 kHz does not hurt: a 30 s recording gives the same text
  from WAV and from M4A, two commas apart.
- Parallel decoding of imports loses no samples (`samples missing at part
  seams: 0`). The WAV never goes through `decodeParts` and fails too.
- The original WAV and the decoded M4A go through the same resampling and
  models.

If the M4A option is ever removed, touch: `encodeM4a` in `MainActivity.kt`
and `lib/audio.dart`, `exportM4a` in `lib/prefs.dart`, `exportAudioExt` and
the `encodeM4a` block in `lib/store.dart`, the format setting in
`lib/screens/settings_screen.dart`, the keys `audioFormat`,
`audioFormatWhenSaving`, `m4aRecommended`, `m4aHint` in `assets/l10n/*.json`
and the mention in `README.md`.

---

## 2. Parakeet Ultra

### What it is

Parakeet TDT 0.6B v3 retrained by Moondream (2026-09-22). Same architecture,
same tokenizer, same 25 languages, CC-BY-4.0. It does not touch
`lib/pipeline.dart`: only the files `lib/models.dart` downloads change.

| WER | v3 | Ultra |
|---|---|---|
| English, 7 Open ASR sets | 6.26 | 5.80 |
| FLEURS, 25 languages | 11.62 | 9.55 |
| Spanish FLEURS | 3.12 | 2.72 |
| With noise, 9 conditions | 6.72 | 5.82 |
| Long audio, TED talks | 2.71 | 1.94 |

Moondream's figures, fp32 on GPU with their own engine (Photon), which cuts
long audio into segments of at most 30 s. In int8 with sherpa-onnx, third
party measurements: Spanish 4.55 to 3.81, English 11.16 to 8.51, German 6.82
to 5.42, at the same speed. Same download as today, about 671 MB.

### Is it worth it

- **For the wrong language problem: not on its own.** No language input, and
  the model card says nothing about language confusion. A better average WER
  says nothing about a rare flip.
- **As a general upgrade: maybe.** Plan step 2 decides, before touching the
  app.

### Found so far

- **The safetensors keys are not NeMo style.** They are `transformers`
  (`ParakeetForTDT`): `encoder.subsampling.*`, `self_attn.q_proj`,
  `decoder.lstm.*`, `encoder_projector`, `joint.head`. So the conversion
  has to load NVIDIA's v3 in NeMo and copy the weights over it with a rename
  table, and stop if a key does not fit, changes shape or is left unfilled.
- **The rename table has to be checked against a real NeMo checkpoint.** A
  first draft of the script used names from memory and was never run; it was
  deleted and will be written again.
- **Weights are fp16** (1.25 GB): convert to float32 before exporting.
- **There is a new VAD head** (`vad_head.*`, 6 tensors). Discarded.
- **Redux discarded:** in sherpa-onnx int8 it weighs the same and transcribes
  worse than v3. Its advantages only exist in Photon.

### Decisions taken

1. **Own conversion**, not a third party's from Hugging Face.
2. **Silero stays.** sherpa-onnx only accepts Silero and ten-vad, the tuned
   phrase cutting would be lost, and outside Photon the new VAD saves no
   compute.
3. **New file names.** `missingDownloads` compares only name and size.
   Ultra's decoder and joiner can weigh exactly the same as v3's with other
   bytes, and the phone would keep the old ones next to the new encoder.

### Plan

1. **Write the conversion script and convert.** There is no script in the
   repository. It runs on Linux or WSL with 16 GB of RAM and about 10 GB
   free, and the run is about 40 min, mostly download and export:

   ```bash
   pip install "nemo_toolkit[asr]" onnx onnxruntime safetensors huggingface_hub sherpa-onnx
   ```

   ```bash
   curl -SLO https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/es.wav
   ```

   The script should end by printing three texts of that WAV: v3 in NeMo,
   Ultra in NeMo, Ultra int8 in sherpa-onnx.
   - **The three look alike:** good conversion, go to step 2.
   - **A key does not fit:** fix the rename table and run again.
   - **Ultra is garbage and v3 is fine:** a square matrix ended up with
     another orientation than in NeMo. A shape check cannot see this one.
2. **Measure on PC.** With sherpa-onnx, transcribe with v3 and with Ultra:
   the 697.6 s reference interview, and the 1 min and 3 min WAVs of topic 1.
   If Ultra is not clearly better, stop here.
3. **`tool/fetch_models.dart`.** Take the 4 files from `build/ultra/` instead
   of the k2-fsa tarball (line 204) and give them new names, for example
   `asr2-encoder.int8.onnx`.
4. **`lib/models.dart`.**
   - Constants `asrEncoder`, `asrDecoder`, `asrJoiner`, `asrTokens` with the
     new names.
   - `modelsUrl` to a new tag `models-v2`.
   - `rtfKey` to `parakeet-ultra|titanet-small|...` so the RTF is measured
     again.
   - Delete the 4 old files and their `.part` at start, about 5 lines in
     `prepareModels`. It runs before the download check, so the old files
     free their space before the new ones come down.
   - Check `asrMaxPhrase` and the retry constants again: they were measured
     on v3.
5. **Upload** the 4 files to the tag `models-v2` with `gh release create`.
6. **Attribution.** `NOTICE`, `lib/main.dart:104` and the debug text in
   `lib/screens/transcript_screen.dart`: "Moondream Parakeet Ultra, based on
   NVIDIA's parakeet-tdt-0.6b-v3, CC-BY-4.0, converted to ONNX int8 by
   Scrita".
7. **Update text.** One new key in the 25 JSON files of `assets/l10n/` for
   those who already had the model: "improved model, N MB". Today they would
   see the first install text.
8. **Test on the phone.** Update over an install with v3: it downloads,
   transcribes, and the old files are gone.

### How a phone updates today

1. Opens the new app. `home_screen.dart:61` sees files missing.
2. The onboarding opens with only the download slide.
3. The app cannot be used until it finishes (`onboarding_screen.dart:204`).
   There is no "later" option.

Keeping the old model until there is Wi-Fi is not planned: it would need two
sets of hashes.

### Open risks

- Key mapping not validated (the first run settles it).
- Improvement measured by third parties, not on our audio (step 2).
- One known regression of Ultra: clean VoxPopuli 3.02 to 3.10.
- Current users download 671 MB again.

---

## Sources

- https://github.com/NVIDIA-NeMo/Speech/discussions/14620
- https://moondream.ai/blog/introducing-parakeet-redux-and-ultra
- https://huggingface.co/moondream/parakeet-ultra
- https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-redux-int8
- https://huggingface.co/tpmaerk/parakeet-ultra-sherpa-onnx-int8
- https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/nemo/parakeet-tdt-0.6b-v3/export_onnx.py
