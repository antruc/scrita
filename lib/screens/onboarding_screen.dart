// First launch: permissions, the voice model download and a short tutorial.
// The download runs while the tutorial plays, so its minutes go by reading.
// Settings opens the tutorial pages alone.
//
// The illustrations are drawn with the app's own widgets, not screenshots:
// they follow the theme and language and add nothing to the APK.

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../audio.dart' show freeBytes, network;
import '../background.dart';
import '../l10n.dart';
import '../main.dart' show appFooter;
import '../models.dart' as models;
import '../recorder.dart';

enum _Kind { permissions, download, record, speakers, review, assign, save }

class OnboardingScreen extends StatefulWidget {
  /// [modelDir] set: the model is missing there and gets downloaded.
  /// [permissions]: start with the permissions page (first launch only).
  /// [tutorial]: show the tutorial pages.
  const OnboardingScreen({
    super.key,
    this.modelDir,
    this.permissions = false,
    this.tutorial = true,
  });

  final String? modelDir;
  final bool permissions;
  final bool tutorial;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;

  late final _kinds = [
    if (widget.permissions) _Kind.permissions,
    if (widget.modelDir != null) _Kind.download,
    if (widget.tutorial) ...[
      _Kind.record,
      _Kind.speakers,
      _Kind.review,
      _Kind.assign,
      _Kind.save,
    ],
  ];

  bool _started = false;
  late bool _ready = widget.modelDir == null;
  int _percent = 0;
  String? _error;

  bool get _last => _page == _kinds.length - 1;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() => _pages.nextPage(
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOutCubic,
  );

  /// Asks for both at once. "Not now" is fine: recording asks again.
  Future<void> _askPermissions() async {
    final recorder = InterviewRecorder();
    try {
      await recorder.hasPermission();
    } finally {
      await recorder.dispose();
    }
    await BackgroundService.requestNotificationPermission();
    _next();
  }

  String get _progressText =>
      '${tr('Descargando el modelo de voz', 'Downloading the voice model')}'
      ' - $_percent %';

  /// Starts the download and, if the checks pass, moves on to the tutorial
  /// without waiting for it.
  Future<void> _startDownload() async {
    if (await _download() && !_last) _next();
  }

  /// The user already accepted mobile data on this screen.
  bool _meteredOk = false;

  /// Checks space and network, then downloads in the background. False if a
  /// check stopped it; the banner then says why, with "Retry".
  Future<bool> _download() async {
    setState(() {
      _started = true;
      _error = null;
    });
    final error = await _check();
    if (!mounted) return false;
    if (error != null) {
      setState(() => _error = error);
      return false;
    }
    _run();
    return true;
  }

  /// Room left on the phone after the download.
  // ponytail: fixed margin, calibration knob.
  static const _spareBytes = 100 * 1000 * 1000;

  /// Why the download cannot start now, null if it can. Asks before using
  /// mobile data. ponytail: checked at start only; a switch from Wi-Fi to
  /// mobile data mid-download goes unnoticed.
  Future<String?> _check() async {
    final dir = widget.modelDir!;
    final left = models.bytesLeft(dir);
    final free = await freeBytes(dir);
    if (free != null && free < left + _spareBytes) {
      return tr(
        'Falta espacio: se necesitan '
            '${models.formatMb(left + _spareBytes)} libres y hay '
            '${models.formatMb(free)}. Libera espacio y toca Reintentar',
        'Not enough space: '
            '${models.formatMb(left + _spareBytes)} free needed, '
            '${models.formatMb(free)} available. Free up space and tap Retry',
      );
    }
    switch (await network()) {
      case 'none':
        return tr(
          'Sin conexión. Conéctate a internet y toca Reintentar',
          'No connection. Connect to the internet and tap Retry',
        );
      case 'metered' when !_meteredOk:
        _meteredOk = await _confirmMetered(left);
        if (!_meteredOk) {
          return tr(
            'Descarga en espera. Conéctate a una red Wi-Fi y toca Reintentar',
            'Download on hold. Connect to Wi-Fi and tap Retry',
          );
        }
    }
    return null;
  }

  Future<bool> _confirmMetered(int bytes) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.signal_cellular_alt),
        title: Text(tr('¿Usar datos móviles?', 'Use mobile data?')),
        content: Text(
          tr(
            'No estás en una red Wi-Fi. La descarga usará '
                '${models.formatMb(bytes)} de tu plan de datos',
            "You're not on Wi-Fi. The download will use "
                '${models.formatMb(bytes)} of your data plan',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Esperar Wi-Fi', 'Wait for Wi-Fi')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Descargar igual', 'Download anyway')),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _run() async {
    // The service keeps the download going with the screen off. Without it
    // the download still works while the app stays open.
    try {
      await BackgroundService.start(BackgroundWork.processing, _progressText);
    } catch (_) {}
    try {
      await models.downloadModels(widget.modelDir!, (done) {
        final percent = done * 100 ~/ models.downloadBytes;
        // Once per percent, not once per 64 KB chunk.
        if (percent == _percent || !mounted) return;
        setState(() => _percent = percent);
        BackgroundService.update(_progressText);
      });
      if (!mounted) return;
      setState(() => _ready = true);
      // Tapping it reopens the app if the user left during the download.
      await BackgroundService.finish(
        tr('Scrita está lista', 'Scrita is ready'),
      );
    } on models.ModelDownloadError catch (e) {
      await BackgroundService.stop();
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _finish() async {
    await BackgroundService.stop();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // WithForegroundTask: "back" during the download minimizes the app.
    return WithForegroundTask(
      child: PopScope(
        // The app cannot work until the model is in.
        canPop: _ready,
        child: Scaffold(
          bottomNavigationBar: appFooter(theme, _footer(theme)),
          body: SafeArea(
            child: Column(
              children: [
                if (_started) _banner(theme),
                Expanded(
                  child: PageView(
                    controller: _pages,
                    // Permissions and download move on with their buttons.
                    physics: _kinds[_page].index > _Kind.download.index
                        ? null
                        : const NeverScrollableScrollPhysics(),
                    onPageChanged: (i) => setState(() => _page = i),
                    children: [for (final k in _kinds) _pageFor(k, theme)],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Download progress ─────────────────────────────────────────────────

  Widget _banner(ThemeData theme) {
    final c = theme.colorScheme;
    final error = _error != null;
    final text =
        _error ??
        (_ready
            ? tr('Modelo de voz listo', 'Voice model ready')
            : _percent >= 100
            ? tr('Verificando el modelo...', 'Verifying the model...')
            : _progressText);
    final fg = error ? c.onErrorContainer : c.onSecondaryContainer;
    return Material(
      color: error ? c.errorContainer : c.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  error
                      ? Icons.error_outline
                      : _ready
                      ? Icons.check_circle_outline
                      : Icons.downloading,
                  color: fg,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(text, style: TextStyle(color: fg)),
                ),
                if (error)
                  TextButton(
                    onPressed: _download,
                    child: Text(tr('Reintentar', 'Retry')),
                  ),
              ],
            ),
            if (!error && !_ready) ...[
              const SizedBox(height: 8),
              // Indeterminate while verifying: the hash has no progress.
              LinearProgressIndicator(
                value: _percent >= 100 ? null : _percent / 100,
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Footer ────────────────────────────────────────────────────────────

  Widget _footer(ThemeData theme) {
    final kind = _kinds[_page];
    final Widget secondary = switch (kind) {
      _Kind.permissions => TextButton(
        onPressed: _next,
        child: Text(tr('Ahora no', 'Not now')),
      ),
      _ when kind.index > _Kind.download.index && !_last => TextButton(
        onPressed: () => _pages.animateToPage(
          _kinds.length - 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
        child: Text(tr('Saltar', 'Skip')),
      ),
      _ => const SizedBox.shrink(),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_kinds.length > 1) ...[_dots(theme), const SizedBox(height: 16)],
        Row(children: [secondary, const Spacer(), _primary(kind)]),
      ],
    );
  }

  Widget _primary(_Kind kind) {
    if (kind == _Kind.permissions) {
      return FilledButton(
        onPressed: _askPermissions,
        child: Text(tr('Permitir', 'Allow')),
      );
    }
    if (kind == _Kind.download && !_started) {
      return FilledButton(
        onPressed: _startDownload,
        child: Text(
          '${tr('Descargar', 'Download')} '
          '(${models.formatMb(models.downloadBytes)})',
        ),
      );
    }
    if (!_last) {
      return FilledButton(
        onPressed: _next,
        child: Text(tr('Siguiente', 'Next')),
      );
    }
    if (_ready) {
      return FilledButton(
        onPressed: _finish,
        child: Text(
          widget.modelDir == null && !widget.permissions
              ? tr('Listo', 'Done')
              : tr('Empezar', 'Get started'),
        ),
      );
    }
    if (_error != null) {
      return FilledButton(
        onPressed: _download,
        child: Text(tr('Reintentar', 'Retry')),
      );
    }
    return FilledButton(
      onPressed: null,
      child: Text(
        _percent >= 100
            ? tr('Verificando...', 'Verifying...')
            : '${tr('Descargando', 'Downloading')} $_percent %',
      ),
    );
  }

  Widget _dots(ThemeData theme) => ExcludeSemantics(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _kinds.length; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == _page ? 20 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == _page
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    ),
  );

  // ── Pages ─────────────────────────────────────────────────────────────

  Widget _pageFor(_Kind kind, ThemeData theme) => switch (kind) {
    _Kind.permissions => _slide(
      theme,
      const _PermissionsArt(),
      tr('Antes de empezar', 'Before you start'),
      tr(
        'Scrita necesita estos permisos. Tus grabaciones nunca salen de tu '
            'teléfono',
        'Scrita needs these permissions. Your recordings never leave your '
            'phone',
      ),
    ),
    _Kind.download => _slide(
      theme,
      _circle(theme, Icons.download_for_offline_outlined),
      tr('Descarga el modelo de voz', 'Download the voice model'),
      tr(
        'Scrita transcribe sin internet con un modelo de '
            '${models.formatMb(models.downloadBytes)} que se descarga una sola '
            'vez. Mejor con Wi-Fi. Mientras se descarga, te mostramos cómo '
            'funciona la app',
        'Scrita transcribes offline with a '
            '${models.formatMb(models.downloadBytes)} model, downloaded only '
            'once. Wi-Fi recommended. While it downloads, we show you how the '
            'app works',
      ),
    ),
    _Kind.record => _slide(
      theme,
      const _HomeArt(),
      tr('Graba o importa', 'Record or import'),
      tr(
        'Toca el micrófono para grabar una entrevista, o importa un audio. '
            'También puedes compartir notas de voz de WhatsApp con Scrita',
        'Tap the mic to record an interview, or import an audio file. You '
            'can also share WhatsApp voice notes with Scrita',
      ),
    ),
    _Kind.speakers => _slide(
      theme,
      const _SpeakersArt(),
      tr('¿Cuántas personas hablan?', 'How many people speak?'),
      tr(
        'Al transcribir, elige el número exacto de personas. Así Scrita '
            'sabe a quién pertenece cada frase',
        'When you transcribe, pick the exact number of people. That way '
            'Scrita knows who said each sentence',
      ),
    ),
    _Kind.review => _slide(
      theme,
      const _TranscriptArt(),
      tr('Revisa y corrige', 'Review and fix'),
      tr(
        'Pon nombre a cada persona, edita un párrafo o escucha el audio '
            'original mientras lees',
        'Name each person, edit a paragraph or play the original audio '
            'while you read',
      ),
    ),
    _Kind.assign => _slide(
      theme,
      const _AssignArt(),
      tr('Corrige quién habla', "Fix who's speaking"),
      tr(
        'Si un párrafo mezcla dos voces, mantén presionado el texto, '
            'selecciona la parte de la otra persona y toca Asignar a',
        'If a paragraph mixes two voices, press and hold the text, select '
            "the other person's part and tap Assign to",
      ),
    ),
    _Kind.save => _slide(
      theme,
      const _SaveArt(),
      tr('Guarda y comparte', 'Save and share'),
      tr(
        'Comparte el texto, cópialo o guárdalo en Documentos. Haz una copia '
            'de seguridad desde Configuración',
        'Share the text, copy it or save it to Documents. Back up from '
            'Settings',
      ),
    ),
  };

  Widget _slide(ThemeData theme, Widget art, String title, String body) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
        child: Column(
          children: [
            const Spacer(),
            // Decorative: a screen reader reads only the title and body.
            ExcludeSemantics(child: IgnorePointer(child: art)),
            // The text sits centered between the art and the footer.
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      body,
                      style: theme.textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

// ── Illustrations ─────────────────────────────────────────────────────────

Widget _circle(ThemeData theme, IconData icon, {double size = 120}) =>
    CircleAvatar(
      radius: size / 2,
      backgroundColor: theme.colorScheme.primaryContainer,
      foregroundColor: theme.colorScheme.onPrimaryContainer,
      child: Icon(icon, size: size / 2),
    );

/// A card the width of a small phone screen, so every mock has one size.
Widget _mock(Widget child) => ConstrainedBox(
  constraints: const BoxConstraints(maxWidth: 320),
  child: Card(
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  ),
);

class _PermissionsArt extends StatelessWidget {
  const _PermissionsArt();

  @override
  Widget build(BuildContext context) => _mock(
    Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.mic_none),
          title: Text(tr('Micrófono', 'Microphone')),
          subtitle: Text(tr('Solo mientras grabas', 'Only while you record')),
        ),
        ListTile(
          leading: const Icon(Icons.notifications_none),
          title: Text(tr('Notificaciones', 'Notifications')),
          subtitle: Text(
            tr(
              'El progreso, con la pantalla apagada',
              'Progress, with the screen off',
            ),
          ),
        ),
      ],
    ),
  );
}

/// A small Home: one pending audio, one transcript and the mic button.
class _HomeArt extends StatelessWidget {
  const _HomeArt();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    Widget row(IconData icon, String title, String sub, bool done) => ListTile(
      leading: CircleAvatar(
        backgroundColor: done ? c.primaryContainer : c.tertiaryContainer,
        foregroundColor: done ? c.onPrimaryContainer : c.onTertiaryContainer,
        child: Icon(icon),
      ),
      title: Text(title),
      subtitle: Text(sub),
    );
    return _mock(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row(
            Icons.graphic_eq,
            tr('Nota de voz', 'Voice note'),
            '02:14',
            false,
          ),
          row(
            Icons.description_outlined,
            tr('Entrevista', 'Interview'),
            '18:40 - 2 ${tr('personas', 'speakers')}',
            true,
          ),
          const SizedBox(height: 16),
          CircleAvatar(
            radius: 36,
            backgroundColor: c.primary,
            foregroundColor: c.onPrimary,
            child: const Icon(Icons.mic, size: 36),
          ),
        ],
      ),
    );
  }
}

class _SpeakersArt extends StatelessWidget {
  const _SpeakersArt();

  @override
  Widget build(BuildContext context) => _mock(
    Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('Personas que hablan', 'People speaking'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (var n = 1; n <= 4; n++)
              ChoiceChip(
                label: Text('$n'),
                selected: n == 2,
                onSelected: (_) {},
              ),
          ],
        ),
      ],
    ),
  );
}

/// One transcript paragraph: speaker dot, name, time and [text].
Widget _paragraph(ThemeData theme, String name, Color color, Widget text) =>
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 8),
              Text(
                name,
                style: theme.textTheme.labelLarge?.copyWith(color: color),
              ),
              const Spacer(),
              Text('00:12', style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 4),
          text,
        ],
      ),
    );

String get _question =>
    tr('¿Cómo empezó el proyecto?', 'How did the project start?');
String get _answer => tr(
  'Con una grabadora y muchas preguntas.',
  'With a recorder and a lot of questions.',
);

/// Two paragraphs of a transcript, each with its speaker's color.
class _TranscriptArt extends StatelessWidget {
  const _TranscriptArt();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    return _mock(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _paragraph(theme, tr('Lucía', 'Lucy'), c.primary, Text(_question)),
          _paragraph(theme, tr('Tomás', 'Tom'), c.tertiary, Text(_answer)),
        ],
      ),
    );
  }
}

/// One paragraph that mixes two voices: Tom's part is selected and the
/// selection menu offers "Assign to Tom".
class _AssignArt extends StatelessWidget {
  const _AssignArt();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    return _mock(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            elevation: 3,
            color: c.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () {},
                  child: Text(tr('Asignar a Tomás', 'Assign to Tom')),
                ),
                TextButton(onPressed: () {}, child: Text(tr('Editar', 'Edit'))),
              ],
            ),
          ),
          const SizedBox(height: 4),
          _paragraph(
            theme,
            tr('Lucía', 'Lucy'),
            c.primary,
            Text.rich(
              TextSpan(
                text: '$_question ',
                children: [
                  TextSpan(
                    text: _answer,
                    style: TextStyle(
                      backgroundColor: c.primary.withValues(alpha: 0.25),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SaveArt extends StatelessWidget {
  const _SaveArt();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget action(IconData icon, String label) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _circle(theme, icon, size: 64),
        const SizedBox(height: 8),
        Text(label, style: theme.textTheme.labelLarge),
      ],
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        action(Icons.share, tr('Compartir', 'Share')),
        action(Icons.copy, tr('Copiar', 'Copy')),
        action(Icons.folder_outlined, tr('Documentos', 'Documents')),
      ],
    );
  }
}
