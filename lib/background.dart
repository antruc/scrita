// Android foreground service.
//
// Keeps the process and the CPU alive (partial wake lock) while recording and
// processing, even if the screen turns off or the user switches apps. Shows
// a persistent notification with the progress.
//
// Recording and processing still run on the main isolate and its worker
// isolate; the service TaskHandler does nothing, it only exists because the
// plugin requires it.

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'l10n.dart';

const _serviceId = 4711;

// Must be public and top-level: Android invokes it by name.
@pragma('vm:entry-point')
void startForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_IdleTaskHandler());
}

class _IdleTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() {
    // Tapping the notification reopens the app.
    FlutterForegroundTask.launchApp();
  }
}

/// Kind of work, because Android 14+ requires declaring what the service is
/// for.
enum BackgroundWork {
  /// Microphone recording (and its later processing).
  recording,

  /// Processing an imported WAV, without the microphone.
  processing,
}

class BackgroundService {
  /// Called once from main(), before starting the service.
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'scrita_work',
        channelName: tr(
          'Grabación y transcripción',
          'Recording and transcription',
        ),
        channelDescription: tr(
          'Se muestra mientras se graba o se transcribe',
          'Shown while recording or transcribing',
        ),
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true, // the CPU keeps working with the screen off
      ),
    );
  }

  /// Android 13+: without this permission the service still works, but the
  /// notification is not shown.
  static Future<void> requestNotificationPermission() async {
    final status = await FlutterForegroundTask.checkNotificationPermission();
    if (status != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  /// Starts the service. For [BackgroundWork.recording] it must be called with
  /// the app visible and the microphone permission already granted (Android 14
  /// rule).
  static Future<void> start(BackgroundWork work, String text) async {
    final types = switch (work) {
      BackgroundWork.recording => [ForegroundServiceTypes.microphone],
      BackgroundWork.processing => [ForegroundServiceTypes.dataSync],
    };
    // A running service may have the other type (e.g. dataSync left by
    // finish()), and the type is only set on start: restart it.
    await stop();
    final result = await FlutterForegroundTask.startService(
      serviceTypes: types,
      serviceId: _serviceId,
      notificationTitle: 'Scrita',
      notificationText: text,
      callback: startForegroundCallback,
    );
    if (result is ServiceRequestFailure) {
      throw Exception(
        tr(
          'No se pudo iniciar el servicio: ${result.error}',
          'Could not start the service: ${result.error}',
        ),
      );
    }
  }

  static Future<void> update(String text) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Scrita',
      notificationText: text,
    );
  }

  /// Leaves only the notification with [text]: the service stays so tapping
  /// it reopens the app, but the wake lock is released. The plugin only
  /// applies lock options on (re)start, hence the restart. The next start()
  /// uses the init() options again, wake lock included.
  static Future<void> finish(String text) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: false,
      ),
      notificationTitle: 'Scrita',
      notificationText: text,
    );
    await FlutterForegroundTask.restartService();
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
