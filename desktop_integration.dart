import 'dart:io';

import 'package:audio_service/audio_service.dart' as svc;
import 'package:flutter/foundation.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'main.dart' show SonaController;

/// Bandeja del sistema + teclas multimedia (Windows: SMTC, Linux: MPRIS)
/// + cerrar a la bandeja. Solo para Windows y Linux.
class DesktopIntegration with TrayListener, WindowListener {
  final SonaController c;
  DesktopIntegration(this.c);

  SMTCWindows? _smtc;          // Windows
  svc.BaseAudioHandler? _mpris; // Linux
  String? _lastPath;
  bool? _lastPlaying;

  static Future<DesktopIntegration> start(SonaController c) async {
    final d = DesktopIntegration(c);
    await d._initTray();
    await d._initMediaControls();
    await windowManager.setPreventClose(true);
    windowManager.addListener(d);
    c.addListener(d._sync);
    return d;
  }

  // ── Bandeja ──
  Future<void> _initTray() async {
    try {
      await trayManager.setIcon(Platform.isWindows
          ? 'assets/tray/tray.ico'
          : 'assets/tray/tray.png');
      await trayManager.setToolTip('SONA');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Mostrar SONA'),
        MenuItem.separator(),
        MenuItem(key: 'toggle', label: 'Reproducir / Pausar'),
        MenuItem(key: 'next', label: 'Siguiente'),
        MenuItem(key: 'prev', label: 'Anterior'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Salir'),
      ]));
      trayManager.addListener(this);
    } catch (e) {
      debugPrint('Tray no disponible: $e');
    }
  }

  @override
  void onTrayIconMouseDown() => _show();
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'show': _show();
      case 'toggle': c.toggle();
      case 'next': c.next();
      case 'prev': c.prev();
      case 'quit': _quit();
    }
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  // La X de la ventana oculta a la bandeja en vez de cerrar.
  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) await windowManager.hide();
  }

  // ── Teclas multimedia / controles del sistema ──
  Future<void> _initMediaControls() async {
    try {
      if (Platform.isWindows) {
        await SMTCWindows.initialize();
        _smtc = SMTCWindows(
          metadata: const MusicMetadata(title: 'SONA', artist: '', album: ''),
          config: const SMTCConfig(
              playEnabled: true, pauseEnabled: true, nextEnabled: true,
              prevEnabled: true, stopEnabled: true,
              fastForwardEnabled: false, rewindEnabled: false),
        );
        _smtc!.buttonPressStream.listen((b) {
          switch (b) {
            case PressedButton.play:
            case PressedButton.pause:
              c.toggle();
            case PressedButton.next:
              c.next();
            case PressedButton.previous:
              c.prev();
            case PressedButton.stop:
              c.player.stop();
            default:
          }
        });
      } else if (Platform.isLinux) {
        // audio_service_mpris se registra solo como plugin de Dart en Linux.
        _mpris = await svc.AudioService.init(
          builder: () => _LinuxHandler(c),
          config: const svc.AudioServiceConfig(
              androidNotificationChannelId: 'app.sona.audio'),
        );
      }
    } catch (e) {
      debugPrint('Controles multimedia no disponibles: $e');
    }
  }

  void _sync() {
    final t = c.current;
    if (t == null) return;
    final trackChanged = t.path != _lastPath;
    final playChanged = c.playing != _lastPlaying;
    if (!trackChanged && !playChanged) return;
    _lastPath = t.path;
    _lastPlaying = c.playing;

    if (_smtc != null) {
      if (trackChanged) {
        _smtc!.updateMetadata(
            MusicMetadata(title: t.title, artist: t.artist, album: t.album));
      }
      _smtc!.setPlaybackStatus(
          c.playing ? PlaybackStatus.Playing : PlaybackStatus.Paused);
    }
    if (_mpris != null) {
      if (trackChanged) {
        _mpris!.mediaItem.add(svc.MediaItem(
            id: t.path, title: t.title, artist: t.artist, album: t.album,
            duration: c.player.duration));
      }
      _mpris!.playbackState.add(svc.PlaybackState(
        controls: [
          svc.MediaControl.skipToPrevious,
          c.playing ? svc.MediaControl.pause : svc.MediaControl.play,
          svc.MediaControl.skipToNext,
        ],
        systemActions: const {svc.MediaAction.seek},
        playing: c.playing,
        processingState: svc.AudioProcessingState.ready,
        updatePosition: c.player.position,
      ));
    }
    trayManager.setToolTip(
        c.playing ? '${t.title} — ${t.artist}' : 'SONA (en pausa)');
  }
}

class _LinuxHandler extends svc.BaseAudioHandler with svc.SeekHandler {
  final SonaController c;
  _LinuxHandler(this.c);
  @override
  Future<void> play() => c.player.play();
  @override
  Future<void> pause() => c.player.pause();
  @override
  Future<void> stop() => c.player.stop();
  @override
  Future<void> skipToNext() => c.next();
  @override
  Future<void> skipToPrevious() => c.prev();
  @override
  Future<void> seek(Duration position) => c.player.seek(position);
}
