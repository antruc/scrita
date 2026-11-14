# ULTRA: cambiar Parakeet v3 por Moondream Parakeet Ultra

Estado al 2026-11-12. Nada cambiado en la app. Script de conversión escrito
(`tool/convert_ultra.py`) pero NO ejecutado: falta correrlo en Linux o WSL.

## Siguiente acción (unos 40 min, casi todo descarga y exportación)

En Linux o WSL, con 16 GB de RAM y unos 10 GB libres:

```bash
pip install "nemo_toolkit[asr]" onnx onnxruntime safetensors huggingface_hub sherpa-onnx
```

```bash
curl -SLO https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/es.wav
```

```bash
python tool/convert_ultra.py es.wav
```

Al final imprime tres textos del mismo WAV: v3 en NeMo, Ultra en NeMo, Ultra
int8 en sherpa-onnx.

- **Los tres se parecen:** conversión buena, sigue en el paso 2.
- **`Key mapping failed`:** el script lista las claves que no encajan. Se
  corrige la tabla `RENAMES` del script y se vuelve a correr.
- **Ultra sale basura y v3 sale bien:** una matriz cuadrada quedó con otra
  orientación que en NeMo. Es el único fallo que la comprobación de formas no
  ve.

## Qué es Ultra y por qué

Parakeet TDT 0.6B v3 reentrenado por Moondream (2026-09-22). Misma
arquitectura, mismo tokenizer, mismos 25 idiomas, CC-BY-4.0. No toca
`lib/pipeline.dart`: solo cambian los archivos que baja `lib/models.dart`.

| WER | v3 | Ultra |
|---|---|---|
| Inglés, 7 sets Open ASR | 6.26 | 5.80 |
| FLEURS, 25 idiomas | 11.62 | 9.55 |
| Español FLEURS | 3.12 | 2.72 |
| Con ruido, 9 condiciones | 6.72 | 5.82 |
| Audio largo, charlas TED | 2.71 | 1.94 |

Cifras de Moondream en fp32 sobre GPU. En int8 con sherpa-onnx, mediciones de
terceros: español 4.55 a 3.81, inglés 11.16 a 8.51, alemán 6.82 a 5.42, con
la misma velocidad. Descarga igual que hoy, unos 671 MB.

## Lo que se encontró en esta sesión

- **Las claves del safetensors NO son estilo NeMo.** Son de `transformers`
  (`ParakeetForTDT`): `encoder.subsampling.*`, `self_attn.q_proj`,
  `decoder.lstm.*`, `encoder_projector`, `joint.head`. Por eso el script
  carga el v3 de NVIDIA en NeMo y le copia encima los pesos con una tabla de
  renombres. Para si una clave no encaja, cambia de forma o queda sin llenar.
- **Los nombres NeMo de la tabla son de memoria, no verificados** contra un
  checkpoint real. La primera corrida los valida.
- **Pesos en fp16** (1.25 GB); el script los pasa a float32 antes de exportar.
- **Hay una cabeza VAD nueva** (`vad_head.*`, 6 tensores). Se descarta.
- **Redux descartado:** en sherpa-onnx int8 pesa lo mismo y transcribe peor
  que v3. Sus ventajas solo existen en el motor Photon de Moondream.

## Decisiones tomadas

1. **Conversión propia**, no la de un tercero en Hugging Face.
2. **Silero se queda.** sherpa-onnx solo acepta Silero y ten-vad, el corte de
   frases calibrado (`vadThreshold`, `vadMinSilence`, `vadMaxSpeech`) se
   perdería, y fuera de Photon el VAD nuevo no ahorra cómputo.

## Plan

1. **Convertir** (la siguiente acción de arriba).
2. **Medir en PC.** Con sherpa-onnx, transcribir la entrevista de referencia
   de 697.6 s con el v3 actual y con Ultra. Comparar los textos a ojo. Si
   Ultra no se nota mejor, parar aquí.
3. **`tool/fetch_models.dart`.** Tomar los 4 archivos de `build/ultra/` en
   vez del tarball de k2-fsa (línea 204) y darles nombres nuevos, por ejemplo
   `asr2-encoder.int8.onnx`.
4. **`lib/models.dart`.**
   - Constantes `asrEncoder`, `asrDecoder`, `asrJoiner`, `asrTokens` con los
     nombres nuevos.
   - `modelsUrl` a un tag nuevo `models-v2`.
   - `rtfKey` a `parakeet-ultra|titanet-small|...` para recalcular el RTF.
   - Borrar los 4 archivos de nombre viejo y sus `.part` al arrancar, unas 5
     líneas en `prepareModels`.
5. **Subir** los 4 archivos al tag `models-v2` con `gh release create`.
6. **Atribución.** `NOTICE`, `lib/main.dart:104` y el texto de depuración en
   `lib/screens/transcript_screen.dart:516`: "Moondream Parakeet Ultra,
   basado en parakeet-tdt-0.6b-v3 de NVIDIA, CC-BY-4.0, convertido a ONNX
   int8 por Scrita".
7. **Texto de actualización.** Una clave nueva en los 25 JSON de
   `assets/l10n/` para quien ya tenía el modelo: "modelo mejorado, N MB". Hoy
   vería el texto de primera instalación.
8. **Probar en el teléfono.** Actualizar sobre una instalación con v3:
   descarga, transcribe, y los archivos viejos ya no están.

## Por qué nombres nuevos

`missingDownloads` compara solo nombre y tamaño. El decoder y el joiner de
Ultra pueden pesar exactamente lo mismo que los de v3 con otros bytes, y el
teléfono se quedaría con los viejos sin avisar, combinados con el encoder
nuevo. Con nombres nuevos eso no puede pasar, a cambio de borrar los viejos a
mano (paso 4).

## Cómo se actualiza un teléfono hoy

1. Abre la app nueva. `home_screen.dart:61` ve que faltan archivos.
2. Se abre el onboarding con solo la diapositiva de descarga.
3. No puede salir ni usar la app hasta que termine
   (`onboarding_screen.dart:204`). No hay opción de "más tarde".
4. Con el borrado del paso 4 en `prepareModels`, que corre antes de la
   comprobación de descargas, los archivos viejos liberan su espacio antes
   de bajar los nuevos.

Seguir usando el modelo viejo hasta tener Wi-Fi no está planeado: pediría
mantener dos juegos de hashes.

## Riesgos abiertos

- Mapeo de claves sin validar (lo resuelve la primera corrida).
- Mejora medida por terceros, no en la entrevista de referencia (paso 2).
- Una regresión conocida de Ultra: VoxPopuli limpio 3.02 a 3.10.
- Usuarios actuales vuelven a bajar 671 MB.

## Fuentes

- https://moondream.ai/blog/introducing-parakeet-redux-and-ultra
- https://huggingface.co/moondream/parakeet-ultra
- https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-redux-int8
- https://huggingface.co/tpmaerk/parakeet-ultra-sherpa-onnx-int8
- https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/nemo/parakeet-tdt-0.6b-v3/export_onnx.py
