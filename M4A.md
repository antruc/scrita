# M4A: la transcripción cambia al reimportar el M4A exportado

Estado al 2026-11-14. Causa confirmada: frases largas del VAD, no el M4A.
Arreglo probado en el teléfono: las frases de más de 22 s se parten antes de
decodificar, y un trozo con muy pocas palabras se reintenta en dos mitades.
Queda un fallo sin arreglo: un trozo corto que sale en inglés (1 min M4A).
No quitar la opción M4A. Sin commit.

## Siguiente acción (10 min, build debug en el teléfono)

1. `flutter test` (prueba nueva: `quietCuts`).
2. Compila en debug y transcribe el audio de 1 min (WAV y M4A).
3. En la lista `phrases` ninguna línea debe pasar de 22 s y el texto debe
   salir en español. Si aún hay inglés, baja `asrMaxPhrase`
   (`lib/models.dart`). Si hay palabras partidas, súbelo o sube `asrCutSlack`.

En el resumen, `phrases decoded` cuenta ahora los trozos decodificados;
`longest` y `within 0.5 s of the cap` siguen midiendo las frases del VAD.

## Prueba del 2026-11-13 (teléfono, build debug)

Resultados en `Downloads/3min.txt`, `Downloads/1min.txt`,
`Downloads/multiple.txt`.

| Frase del VAD | Resultado |
|---|---|
| 6.8 a 21.9 s | Bien |
| 23.6 a 27.6 s | Inestable: de bien a mezcla de idiomas |
| 31.3 a 71.7 s | Inglés y oraciones perdidas |

- 1 min WAV también falla (frase de 46.8 s). El M4A sale peor solo porque el
  VAD no cortó: una frase de 71.7 s.
- Con los mismos cortes, una frase de 26 s cambia de texto entre WAV y M4A;
  las de 20 a 22 s no.
- No se hizo el control de determinismo (dos pasadas del mismo WAV).

Arreglo: `quietCuts` (`lib/transcript.dart`) parte en trozos iguales, cada
corte en la décima de segundo más silenciosa a 1.5 s o menos de su posición;
`drain()` (`lib/pipeline.dart`) decodifica cada trozo.

## Prueba del 2026-11-14 con el corte (mismos audios)

- 1 min WAV: completo y en español. 3 min M4A: completo, restos sueltos.
- Quedan 2 trozos cortos que fallan, los dos en el pasaje "por su amplio
  abanico..., por su alta eficiencia" (el modelo oye "for sure"):
  - 3 min WAV, 47.8 s +11.9 s: solo "Especially if", pierde la oración.
  - 1 min M4A, 36.7 s +18.5 s: empieza en "In 2021" y sigue en inglés.
- Parakeet v3 no tiene entrada de idioma (ni Ultra: misma arquitectura). Sin
  arreglo confirmado: https://github.com/NVIDIA-NeMo/Speech/discussions/14620

Reintento probado en el teléfono el 2026-11-14: el WAV de 3 min recupera la
oración (47.8 s +5.5 s y 53.3 s +6.4 s, las dos con `(retry)`). Los otros
tres audios salen igual que antes. Sigue abierto el trozo en inglés del M4A
de 1 min: tiene palabras de sobra y el reintento no lo ve.

Reintento: un trozo de 8 s o más con menos
de 0.5 palabras por segundo se decodifica otra vez en dos mitades, que se
quedan si dan más palabras (`asrRetryWordRate`, `asrRetryMinSeconds`). En la
lista `phrases` esas líneas terminan en `(retry)`. Cubre el primer fallo, no
el segundo.

Verificar: transcribir el WAV de 3 min. La línea de 47.8 s debe salir como
dos líneas con `(retry)` y el texto debe incluir "por su amplio abanico".

# Historial (antes del arreglo)

## Síntoma

Grabación de la app (WAV 48 kHz mono) guardada en Documentos como M4A. Al
importar ese M4A y transcribirlo, el texto cambia considerablemente respecto
a la transcripción del WAV original.

## Prueba pedida el 2026-11-12 (hecha el 13, sin el paso 3)

1. Compila en debug. Los cambios de esta sesión no se han compilado ni
   analizado (no hay Flutter en la máquina de trabajo): si falla el build,
   mira primero `_showTimings` y `phraseLog`.
2. Transcribe el WAV de 3 min. El aviso dice `Debug: timing summary ready`:
   pulsa Copy y guarda el texto.
3. Transcribe otra vez el mismo WAV y guarda el texto (control de
   determinismo).
4. Importa el M4A de esa grabación, transcribe y guarda el texto.
5. Pega los tres resúmenes en la sesión nueva.

El texto copiado termina con una línea por frase del VAD:
`phrases (start +length: text):` y debajo `35.9 s +20.1 s: primeros 40
caracteres...`.

## Cómo leer el resultado

- **El inglés y las oraciones perdidas caen en las frases de más de 30 s:**
  el arreglo está en acortar las frases largas (`vadMaxSpeech` y cómo corta
  sherpa-onnx pasado el tope, `lib/models.dart`).
- **Caen en frases de unos 20 s:** el problema es el corte a mitad de palabra
  o el propio modelo, no la duración.
- **Las dos pasadas del mismo WAV dan textos distintos:** el pipeline no es
  determinista, y eso va antes que todo lo demás.
- **Las dos pasadas dan el mismo texto:** la diferencia con el M4A viene de
  que unos milisegundos de desplazamiento mueven los cortes del VAD.

## Prueba del 2026-11-11 (teléfono, build debug)

Lectura continua de un texto en español, un solo hablante. Resultados en
`Downloads/30segundos.txt` y `Downloads/3minutos.txt`.

| | Frases | En el tope de 20 s | Frase más larga |
|---|---|---|---|
| 30 s WAV | 2 | 1 | 23.6 s |
| 30 s M4A | 2 | 1 | 22.8 s |
| 3 min WAV | 9 | 8 | 35.3 s |
| 3 min M4A | 8 | 7 | 55.8 s |

1. 30 s: WAV y M4A dan el mismo texto, solo cambian dos comas. El codificador
   AAC a 64 kbps no daña la transcripción.
2. 3 min: los dos salen mal, cada uno a su manera. Los dos mezclan inglés en
   el primer tramo ("The gato is the animal domestic most popular mascot") y
   cada uno pierde oraciones enteras distintas. El M4A cambia "38 años y tres
   días" por "28 años andas".
3. Decodificación en paralelo del M4A de 3 min: `3 parallel part(s), samples
   missing at part seams: 0 (expected 0)`. No falta ninguna muestra. No
   descarta bloques mal colocados.

Lectura:

- En lectura continua el VAD (umbral 0.1) casi nunca encuentra una pausa de
  0.5 s. Casi todas las frases terminan por el tope `vadMaxSpeech`, que corta
  en la primera bajada de 0.1 s, a veces a mitad de palabra.
- El tope no es un límite duro: hay frases de 35 y 56 s que Parakeet
  decodifica enteras.
- Sin confirmar: que el inglés y las oraciones perdidas vengan de las frases
  largas. Encaja (el M4A tiene la frase de 55.8 s y pierde más texto), pero
  el resumen de entonces no decía qué frase produjo qué texto. Para eso es la
  lista de frases nueva.
- Descartado como causa principal: la decodificación en paralelo. El WAV no
  pasa por `decodeParts` y también falla. El arreglo del PTS (usar el PTS solo
  para el primer bloque de cada parte) no está justificado por esta prueba.

## Auditoría (solo lectura de código, nada ejecutado)

Flujo: `exportToDocuments` (`lib/store.dart`) -> `encodeM4a` (`lib/audio.dart`)
-> `encodeM4a` en `android/app/src/main/kotlin/dev/antruc/scrita/MainActivity.kt`.
Al reimportar: `decodeToWav` -> `decodeParts` -> `runPipeline`.

1. Corregido: bitrate fijo de 64 kbps sin importar canales. Ahora
   `m4aBitRate * channels`. No afecta a grabaciones de la app (mono).
2. Sin corregir: el retardo del codificador AAC no se compensa. El audio
   decodificado queda desplazado unos 33 a 44 ms (estimado, no medido), lo que
   mueve las ventanas del VAD y la diarización. Con frases cortadas por el
   tope, ese desplazamiento basta para cambiar los cortes y el texto.
3. Sin error encontrado: cabecera WAV, marcas de tiempo, fin de flujo y muxer
   en el bucle de codificación.
4. Sin error encontrado: 64 kbps mono a 48 kHz. La prueba de 30 s lo confirma
   en este teléfono.
5. Sin diferencia: el WAV original y el M4A decodificado pasan por el mismo
   remuestreo y los mismos modelos.

## Cambios sin commit y sin compilar

- `MainActivity.kt`: `KEY_BIT_RATE` pasa a `m4aBitRate * channels`, comentario
  actualizado.
- `lib/screens/home_screen.dart:567`: error de sintaxis que rompía el build
  (venía del commit `b811648`), `tr(...)` ahora va interpolado en la cadena.
- `lib/pipeline.dart`: campo `phraseLog` en los tiempos, con una línea por
  frase decodificada (inicio, duración, primeros 40 caracteres), añadida en
  `drain()`.
- `lib/screens/transcript_screen.dart`, `_showTimings`: el aviso queda en
  `Debug: timing summary ready` con el botón Copy. Copy y `debugPrint` llevan
  el resumen completo más la lista de frases.

## Si al final se decide quitar la opción

Tocar: `encodeM4a` en `MainActivity.kt` y `lib/audio.dart`, `exportM4a` en
`lib/prefs.dart`, `exportAudioExt` y el bloque de `encodeM4a` en
`lib/store.dart`, el ajuste de formato en `lib/screens/settings_screen.dart`,
las claves `audioFormat`, `audioFormatWhenSaving`, `m4aRecommended`, `m4aHint`
en `assets/l10n/*.json` y la mención en `README.md`.
