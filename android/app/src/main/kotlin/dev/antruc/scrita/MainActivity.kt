package dev.antruc.scrita

import android.content.Intent
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.StatFs
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

// Audio work with Android's own codecs (no extra dependency):
// - decode: opus, ogg, m4a... to a 16-bit mono WAV that lib/transcript.dart
//   reads. The original file stays as it is.
// - encodeM4a: a WAV to AAC .m4a, when saving to Documents.
// - sampleRate: to warn about phone-call quality audio.
// - duration: length of an audio, for the "Not transcribed" list.
// - takeShared: the audio another app (WhatsApp) shared with Scrita.
// - openSettings: the app's page in Android settings, to grant the mic.
// - sdkInt: Android API level; 33+ shows its own "copied" notice.
// - freeBytes, network: checked before downloading the voice model.
class MainActivity : FlutterActivity() {
    @Volatile private var shared: Uri? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // Off the main thread: decoding a long audio takes seconds.
        channel = MethodChannel(
            messenger, "scrita/audio", StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        ).apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "decode" -> result.success(
                            decodeToWav(call.argument<String>("from")!!, call.argument<String>("to")!!)
                        )
                        "encodeM4a" -> {
                            encodeM4a(call.argument<String>("from")!!, call.argument<String>("to")!!)
                            result.success(null)
                        }
                        "sampleRate" -> result.success(sampleRate(call.arguments as String))
                        "duration" -> result.success(durationMs(call.arguments as String))
                        "takeShared" -> result.success(takeShared())
                        "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                        "freeBytes" -> result.success(StatFs(call.arguments as String).availableBytes)
                        "network" -> result.success(network())
                        "openSettings" -> {
                            startActivity(Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null),
                            ))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("audio", e.message, null)
                }
            }
        }
        keepShared(intent)
    }

    // launchMode singleTask: a share while the app is open lands here.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (keepShared(intent)) channel?.invokeMethod("shared", null)
    }

    // Keeps the shared audio until Dart takes it. Reopening from "recents"
    // replays the old intent, which must not import the audio again.
    private fun keepShared(intent: Intent?): Boolean {
        if (intent == null || intent.action != Intent.ACTION_SEND ||
            (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        ) return false
        @Suppress("DEPRECATION")
        shared = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: return false
        return true
    }

    // Copies the shared audio to the cache (the read grant ends with the
    // activity) and returns its path, or null if nothing was shared.
    private fun takeShared(): String? {
        val uri = shared ?: return null
        shared = null
        var name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
            ?.let { File(it).name } // a name, never a path
            ?: "audio"
        if (!name.contains('.')) {
            MimeTypeMap.getSingleton().getExtensionFromMimeType(contentResolver.getType(uri))
                ?.let { name += ".$it" }
        }
        val out = File(File(cacheDir, "shared").apply { mkdirs() }, name)
        contentResolver.openInputStream(uri)!!.use { input ->
            out.outputStream().use { input.copyTo(it) }
        }
        return out.path
    }

    // "none", "metered" (mobile data, a phone hotspot) or "unmetered"
    // (Wi-Fi). Metered, not "is it Wi-Fi": a hotspot is Wi-Fi but costs data.
    private fun network(): String {
        val cm = getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "none"
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return "none"
        return if (cm.isActiveNetworkMetered) "metered" else "unmetered"
    }

    private fun durationMs(path: String): Long {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(path)
            return r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
        } finally {
            r.release()
        }
    }

    // ponytail: fixed at 3 and only for audio of 60 s or more. More parts
    // only help if the codec process runs them on more cores: measure first.
    private val parallelParts = 3
    private val minParallelUs = 60_000_000L

    // Decodes the first audio track of [from] to a 16-bit mono WAV at [to],
    // at the source's own rate (the Dart side resamples to 16 kHz).
    // Async MediaCodec: the codec hands over each free buffer through a
    // callback. The polling loop (dequeueInputBuffer/dequeueOutputBuffer)
    // paid a round trip to the codec process per poll: 56 s of 101 s for a
    // 12 min AAC with ~30,000 frames. That round trip is still 1.2 ms per
    // frame, so a long audio is split in [parallelParts] decoders that run at
    // once. If the parallel run fails, it decodes again with one decoder.
    // Returns where the time went, for the app's timing summary.
    private fun decodeToWav(from: String, to: String): String {
        val start = System.nanoTime()
        val durationUs = MediaExtractor().run {
            try {
                setDataSource(from)
                val f = getTrackFormat(audioTrack(this))
                if (f.containsKey(MediaFormat.KEY_DURATION)) f.getLong(MediaFormat.KEY_DURATION) else 0L
            } finally {
                release()
            }
        }
        if (durationUs < minParallelUs) return decodeParts(from, to, 1, durationUs, start)
        return try {
            decodeParts(from, to, parallelParts, durationUs, start)
        } catch (e: Exception) {
            decodeParts(from, to, 1, durationUs, start) +
                " | parallel decode failed, redone with 1 part: ${e.message}"
        }
    }

    private fun audioTrack(extractor: MediaExtractor): Int =
        (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: throw IllegalArgumentException("No audio track")

    // One decoder for the samples [lo, hi) of the audio. Its callbacks run on
    // [thread], one at a time, so its own fields need no locks; the latch
    // publishes them.
    private class Part(val startUs: Long, val endUs: Long) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        val thread = HandlerThread("decode").apply { start() }
        val done = CountDownLatch(1)
        var error: Exception? = null
        var rate = 0
        var channels = 0
        var lo = 0L
        var hi = Long.MAX_VALUE / 2
        var first = -1L // first sample written, for the seam check
        var end = 0L // one past the last sample written
        var inputDone = false

        fun fail(e: Exception) {
            if (error == null) error = e
            done.countDown()
        }

        fun release() {
            runCatching { codec?.stop() }
            codec?.release()
            extractor.release()
            thread.quitSafely()
        }
    }

    // With one part, blocks go to the file in order, as they come. With more,
    // each block goes where its presentationTimeUs says, and each part keeps
    // only its own [lo, hi): it starts 0.5 s early so the decoder is warm at
    // its first sample, and reads 0.5 s past its end.
    private fun decodeParts(from: String, to: String, count: Int, durationUs: Long, start: Long): String {
        val sequential = count == 1
        val marginUs = 500_000L
        val parts = (0 until count).map { i ->
            Part(durationUs * i / count, if (i == count - 1) Long.MAX_VALUE / 2 else durationUs * (i + 1) / count)
        }
        try {
            RandomAccessFile(to, "rw").use { out ->
                out.setLength(0)
                out.write(ByteArray(44)) // header, filled in at the end
                for (p in parts) {
                    p.extractor.setDataSource(from)
                    val track = audioTrack(p.extractor)
                    p.extractor.selectTrack(track)
                    if (p.startUs > 0) {
                        p.extractor.seekTo(p.startUs - marginUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                    }
                    val format = p.extractor.getTrackFormat(track)
                    p.rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    p.channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
                    p.codec = codec
                    codec.setCallback(object : MediaCodec.Callback() {
                        override fun onInputBufferAvailable(c: MediaCodec, i: Int) {
                            if (p.inputDone) return
                            try {
                                val n = p.extractor.readSampleData(c.getInputBuffer(i)!!, 0)
                                val time = p.extractor.sampleTime
                                if (n >= 0) p.extractor.advance()
                                if (n < 0 || time - marginUs >= p.endUs) {
                                    c.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                    p.inputDone = true
                                } else {
                                    c.queueInputBuffer(i, 0, n, time, 0)
                                }
                            } catch (e: Exception) {
                                p.fail(e)
                            }
                        }

                        override fun onOutputBufferAvailable(c: MediaCodec, o: Int, info: MediaCodec.BufferInfo) {
                            try {
                                val buf = c.getOutputBuffer(o)!!.order(ByteOrder.LITTLE_ENDIAN)
                                buf.position(info.offset).limit(info.offset + info.size)
                                val frames = info.size / (2 * p.channels)
                                val mono = ByteArray(frames * 2)
                                if (p.channels == 1) {
                                    buf.get(mono)
                                } else {
                                    // One bulk copy to a ShortArray, then plain array
                                    // math: a ByteBuffer.getShort per sample was slow.
                                    val pcm = ShortArray(frames * p.channels)
                                    buf.asShortBuffer().get(pcm)
                                    val mixed = ShortArray(frames)
                                    var k = 0
                                    for (f in 0 until frames) {
                                        var sum = 0
                                        for (ch in 0 until p.channels) sum += pcm[k++]
                                        mixed[f] = (sum / p.channels).toShort()
                                    }
                                    ByteBuffer.wrap(mono).order(ByteOrder.LITTLE_ENDIAN)
                                        .asShortBuffer().put(mixed)
                                }
                                // Sample index of the block's first frame, and the part
                                // of the block inside [lo, hi).
                                val base = if (sequential) p.end else Math.round(info.presentationTimeUs * p.rate / 1e6)
                                val keepFrom = (p.lo - base).coerceIn(0L, frames.toLong())
                                val keepTo = (p.hi - base).coerceIn(keepFrom, frames.toLong())
                                if (keepTo > keepFrom) {
                                    synchronized(out) {
                                        out.seek(44 + (base + keepFrom) * 2)
                                        out.write(mono, (keepFrom * 2).toInt(), ((keepTo - keepFrom) * 2).toInt())
                                    }
                                    if (p.first < 0) p.first = base + keepFrom
                                    p.end = base + keepTo
                                }
                                c.releaseOutputBuffer(o, false)
                                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) p.done.countDown()
                            } catch (e: Exception) {
                                p.fail(e)
                            }
                        }

                        override fun onOutputFormatChanged(c: MediaCodec, f: MediaFormat) {
                            p.rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            p.channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            if (f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                                f.getInteger(MediaFormat.KEY_PCM_ENCODING) != AudioFormat.ENCODING_PCM_16BIT
                            ) p.fail(IllegalStateException("Decoder output is not 16-bit PCM"))
                            setBounds(p)
                        }

                        override fun onError(c: MediaCodec, e: MediaCodec.CodecException) = p.fail(e)
                    }, Handler(p.thread.looper))
                    setBounds(p)
                    codec.configure(format, null, null, 0)
                    codec.start()
                }
                // A codec that never signals end of stream would hang the
                // transcript screen, which cannot be left while busy.
                val timeoutS = maxOf(300L, durationUs / 1_000_000)
                for (p in parts) {
                    if (!p.done.await(timeoutS, TimeUnit.SECONDS)) throw IllegalStateException("Decoder timed out")
                }
                // Stop before touching the file: no callback may write after this.
                for (p in parts) p.codec!!.stop()
                parts.firstNotNullOfOrNull { it.error }?.let { throw it }
                val rate = parts[0].rate
                if (parts.any { it.rate != rate }) throw IllegalStateException("Parts decoded at different rates")
                out.seek(0)
                out.write(wavHeader(rate, parts.maxOf { it.end } * 2))
            }
            // Samples no part wrote at the seams between parts: should be 0.
            var missing = 0L
            for (i in 1 until parts.size) {
                missing += maxOf(0L, parts[i - 1].hi - parts[i - 1].end) + maxOf(0L, parts[i].first - parts[i].lo)
            }
            return "codec ${parts[0].codec!!.name}, source ${parts[0].rate} Hz ${parts[0].channels} ch, " +
                "${parts.size} parallel part(s), " +
                "time %.1f s".format((System.nanoTime() - start) / 1e9) +
                if (sequential) "" else ", samples missing at part seams: $missing (expected 0)"
        } finally {
            parts.forEach { it.release() }
        }
    }

    // [lo, hi) of a part in samples at its output rate. One part keeps
    // everything; the first of several starts at 0, dropping any priming
    // samples with a negative timestamp.
    private fun setBounds(p: Part) {
        if (p.startUs > 0) p.lo = Math.round(p.startUs * p.rate / 1e6)
        if (p.endUs < Long.MAX_VALUE / 2) p.hi = Math.round(p.endUs * p.rate / 1e6)
    }

    private fun sampleRate(path: String): Int {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            return extractor.getTrackFormat(audioTrack(extractor)).getInteger(MediaFormat.KEY_SAMPLE_RATE)
        } finally {
            extractor.release()
        }
    }

    // AAC-LC at 64 kbps: for speech, close to the original at about 1/12 of
    // the WAV size (~29 MB per hour of mono).
    private val m4aBitRate = 64_000

    // Encodes a 16-bit PCM WAV to .m4a. Reads up to the end of the file when
    // the data size is 0 or too big (the app died while recording), like
    // readWavMono. Deletes [to] if anything fails.
    private fun encodeM4a(from: String, to: String) {
        var codec: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var muxing = false
        try {
            RandomAccessFile(from, "r").use { wav ->
                var rate = 0
                var channels = 0
                var bits = 0
                val h = ByteArray(8)
                wav.seek(12)
                var size = 0L
                while (true) {
                    wav.readFully(h)
                    size = ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN).getInt(4).toLong() and 0xffffffffL
                    val id = String(h, 0, 4, Charsets.US_ASCII)
                    if (id == "data") break
                    val skip = size + (size and 1)
                    if (id == "fmt " && size in 16..64) {
                        val fmt = ByteArray(size.toInt()).also { wav.readFully(it) }
                        val b = ByteBuffer.wrap(fmt).order(ByteOrder.LITTLE_ENDIAN)
                        val tag = b.getShort(0).toInt() and 0xffff
                        if (tag != 1 && tag != 0xfffe) throw IllegalArgumentException("Not PCM")
                        channels = b.getShort(2).toInt()
                        rate = b.getInt(4)
                        bits = b.getShort(14).toInt()
                        wav.seek(wav.filePointer + (size and 1))
                    } else {
                        wav.seek(wav.filePointer + skip)
                    }
                }
                if (bits != 16 || channels !in 1..2 || rate <= 0) {
                    throw IllegalArgumentException("Only 16-bit PCM WAV")
                }
                val available = wav.length() - wav.filePointer
                var remaining = if (size == 0L || size > available) available else size

                val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, channels).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, m4aBitRate)
                }
                val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                codec = enc
                enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                enc.start()
                val mux = MediaMuxer(to, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                muxer = mux

                val frame = 2 * channels
                val chunk = ByteArray(16384)
                var framesIn = 0L
                var inputDone = false
                var track = -1
                val info = MediaCodec.BufferInfo()
                while (true) {
                    if (!inputDone) {
                        val i = enc.dequeueInputBuffer(10_000)
                        if (i >= 0) {
                            val buf = enc.getInputBuffer(i)!!
                            buf.clear()
                            val want = minOf(buf.capacity(), chunk.size, remaining.coerceIn(0, Int.MAX_VALUE.toLong()).toInt()) / frame * frame
                            val n = if (want > 0) wav.read(chunk, 0, want) else -1
                            if (n <= 0) {
                                enc.queueInputBuffer(i, 0, 0, framesIn * 1_000_000 / rate, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                buf.put(chunk, 0, n)
                                enc.queueInputBuffer(i, 0, n, framesIn * 1_000_000 / rate, 0)
                                framesIn += n / frame
                                remaining -= n
                            }
                        }
                    }
                    val o = enc.dequeueOutputBuffer(info, 10_000)
                    if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        track = mux.addTrack(enc.outputFormat)
                        mux.start()
                        muxing = true
                    } else if (o >= 0) {
                        // The codec config goes in the track format, not as a sample.
                        if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 && info.size > 0) {
                            mux.writeSampleData(track, enc.getOutputBuffer(o)!!, info)
                        }
                        enc.releaseOutputBuffer(o, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
                    }
                }
            }
            muxer?.stop()
            muxing = false
        } catch (e: Exception) {
            File(to).delete()
            throw e
        } finally {
            runCatching { codec?.stop() }
            codec?.release()
            if (muxing) runCatching { muxer?.stop() }
            muxer?.release()
        }
    }

    // Sizes are unsigned 32-bit: toInt() keeps the right bits up to 4 GB.
    // Past that they would wrap to a small size and cut the audio, so they
    // go as 0, which readWavMono and encodeM4a read as "up to end of file".
    private fun wavHeader(rate: Int, dataBytes: Long): ByteArray {
        val data = if (36 + dataBytes > 0xffffffffL) 0L else dataBytes
        val riff = if (data == 0L) 0L else 36 + data
        return ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt(riff.toInt()); put("WAVE".toByteArray())
            put("fmt ".toByteArray()); putInt(16)
            putShort(1); putShort(1) // PCM, mono
            putInt(rate); putInt(rate * 2); putShort(2); putShort(16)
            put("data".toByteArray()); putInt(data.toInt())
        }.array()
    }
}
