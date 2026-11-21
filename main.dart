import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_integration.dart';

// ───────────────────────── Tema ─────────────────────────
class C {
  static const bg = Color(0xFF1B0F18);
  static const panel = Color(0xFF3B2434);
  static const card = Color(0xFF52334A);
  static const accent = Color(0xFFF2A9D0);
  static const play = Color(0xFF4CAF6A);
  static const text = Color(0xFFF3E3EC);
  static const dim = Color(0xFFB99AAD);
}

ThemeData sonaTheme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: C.bg,
      colorScheme: const ColorScheme.dark(
          primary: C.accent, surface: C.panel, onSurface: C.text),
      navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: C.panel, indicatorColor: C.card),
      sliderTheme: const SliderThemeData(
          trackHeight: 3,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5)),
    );

// ───────────────────────── Modelo ─────────────────────────
class Track {
  final String path, title, artist, album;
  final Uint8List? cover;
  Track(this.path, this.title, this.artist, this.album, this.cover);
}

const _exts = ['.mp3', '.flac', '.m4a', '.ogg', '.opus', '.wav', '.aac'];

// ───────────────────── Controlador (estado + audio) ─────────────────────
class SonaController extends ChangeNotifier {
  final player = AudioPlayer();
  List<Track> tracks = [];
  List<Track> queue = [];
  int idx = -1;
  Set<String> favs = {};
  Map<String, List<String>> playlists = {};
  List<String> recents = [];
  bool shuffle = false, scanning = false;
  LoopMode loop = LoopMode.off; // 'one' se gestiona manualmente
  String? folder;
  String query = '';

  Track? get current => (idx >= 0 && idx < queue.length) ? queue[idx] : null;
  bool get playing => player.playing;
  Track? byPath(String p) {
    for (final t in tracks) {
      if (t.path == p) return t;
    }
    return null;
  }

  List<Track> get filtered => query.isEmpty
      ? tracks
      : tracks
          .where((t) => '${t.title} ${t.artist} ${t.album}'
              .toLowerCase()
              .contains(query.toLowerCase()))
          .toList();

  SonaController() {
    player.playingStream.listen((_) => notifyListeners());
    player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) next(auto: true);
    });
    _load();
  }

  // Persistencia sencilla (prototipo). Siguiente paso: SQLite/Drift.
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final m = jsonDecode(p.getString('sona') ?? '{}') as Map<String, dynamic>;
    favs = Set<String>.from(m['favs'] ?? []);
    recents = List<String>.from(m['recents'] ?? []);
    playlists = (m['playlists'] as Map<String, dynamic>? ?? {})
        .map((k, v) => MapEntry(k, List<String>.from(v)));
    folder = m['folder'];
    notifyListeners();
    if (folder != null) await scan(folder!);
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString( 'sona',
        jsonEncode({'favs': favs.toList(), 'recents': recents,
          'playlists': playlists, 'folder': folder}));
  }

  Future<void> pickFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null) await scan(dir);
  }

  Future<void> scan(String dir) async {
    scanning = true;
    folder = dir;
    notifyListeners();
    final found = <Track>[];
    try {
      await for (final e in Directory(dir).list(recursive: true, followLinks: false)) {
        if (e is! File || !_exts.any(e.path.toLowerCase().endsWith)) continue;
        try {
          final md = readMetadata(e, getImage: true);
          found.add(Track(
              e.path,
              (md.title?.trim().isNotEmpty ?? false)
                  ? md.title!
                  : e.uri.pathSegments.last,
              md.artist ?? 'Artista desconocido',
              md.album ?? 'Álbum desconocido',
              md.pictures.isNotEmpty ? md.pictures.first.bytes : null));
        } catch (_) {
          found.add(Track(e.path, e.uri.pathSegments.last,
              'Artista desconocido', 'Álbum desconocido', null));
        }
      }
    } catch (_) {}
    found.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    tracks = found;
    scanning = false;
    _save();
    notifyListeners();
  }

  // ── Reproducción ──
  Future<void> playTrack(Track t, [List<Track>? list]) async {
    queue = list ?? tracks;
    idx = queue.indexOf(t);
    await _playAt();
  }

  Future<void> _playAt() async {
    final t = current;
    if (t == null) return;
    await player.setAudioSource(AudioSource.file(t.path,
        tag: MediaItem(id: t.path, title: t.title, artist: t.artist, album: t.album)));
    player.play();
    recents..remove(t.path)..insert(0, t.path);
    if (recents.length > 20) recents.removeLast();
    _save();
    notifyListeners();
  }

  void toggle() => player.playing ? player.pause() : (current == null && tracks.isNotEmpty ? playTrack(tracks.first) : player.play());

  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty) return;
    if (auto && loop == LoopMode.one) {
      await player.seek(Duration.zero);
      player.play();
      return;
    }
    if (shuffle) {
      idx = Random().nextInt(queue.length);
    } else if (idx + 1 < queue.length) {
      idx++;
    } else if (loop == LoopMode.all) {
      idx = 0;
    } else {
      await player.stop();
      notifyListeners();
      return;
    }
    await _playAt();
  }

  Future<void> prev() async {
    if (queue.isEmpty) return;
    if (player.position > const Duration(seconds: 3)) return player.seek(Duration.zero);
    idx = (idx - 1) < 0 ? queue.length - 1 : idx - 1;
    await _playAt();
  }

  void toggleShuffle() { shuffle = !shuffle; notifyListeners(); }
  void cycleLoop() {
    loop = LoopMode.values[(loop.index + 1) % 3];
    notifyListeners();
  }

  // ── Favoritos y playlists ──
  void toggleFav(Track t) {
    favs.contains(t.path) ? favs.remove(t.path) : favs.add(t.path);
    _save(); notifyListeners();
  }
  void createPlaylist(String n) {
    if (n.trim().isEmpty) return;
    playlists.putIfAbsent(n.trim(), () => []);
    _save(); notifyListeners();
  }
  void addToPlaylist(String n, Track t) {
    final l = playlists[n]!;
    if (!l.contains(t.path)) l.add(t.path);
    _save(); notifyListeners();
  }
  void removeFromPlaylist(String n, Track t) {
    playlists[n]?.remove(t.path);
    _save(); notifyListeners();
  }
  void deletePlaylist(String n) { playlists.remove(n); _save(); notifyListeners(); }
  void setQuery(String q) { query = q; notifyListeners(); }

  List<Track> dailyMix(int n) {
    final r = Random(DateTime.now().year * 1000 + DateTime.now().dayOfYear + n);
    final l = [...tracks]..shuffle(r);
    return l.take(15).toList();
  }
}

extension on DateTime {
  int get dayOfYear => difference(DateTime(year, 1, 1)).inDays + 1;
}

// ───────────────────────── Arranque ─────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = SonaController();
  if (Platform.isAndroid) {
    await JustAudioBackground.init(
        androidNotificationChannelId: 'app.sona.audio',
        androidNotificationChannelName: 'SONA',
        androidNotificationOngoing: true);
  } else if (Platform.isWindows || Platform.isLinux) {
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
        const WindowOptions(size: Size(1280, 760), minimumSize: Size(900, 600), title: 'SONA'),
        () async { await windowManager.show(); });
    await DesktopIntegration.start(controller); // bandeja, teclas multimedia, cerrar a bandeja
  }
  runApp(ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
          title: 'SONA',
          debugShowCheckedModeBanner: false,
          theme: sonaTheme(),
          home: const Shell())));
}

// ───────────────────────── Widgets base ─────────────────────────
class Cover extends StatelessWidget {
  final Track? t;
  final double size;
  const Cover(this.t, {super.key, this.size = 48});
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * .14),
        child: SizedBox(
          width: size, height: size,
          child: t?.cover != null
              ? Image.memory(t!.cover!, fit: BoxFit.cover, gaplessPlayback: true)
              : Container(
                  decoration: const BoxDecoration(
                      gradient: LinearGradient(colors: [C.card, Color(0xFF2A1623)],
                          begin: Alignment.topLeft, end: Alignment.bottomRight)),
                  child: Center(child: Icon(Icons.album, size: size * .6, color: C.accent.withOpacity(.7)))),
        ),
      );
}

class Box extends StatelessWidget {
  final Widget child;
  final EdgeInsets pad;
  const Box({super.key, required this.child, this.pad = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext context) => Container(
      padding: pad,
      decoration: BoxDecoration(
          color: C.panel.withOpacity(.75), borderRadius: BorderRadius.circular(24)),
      child: child);
}

class TrackTile extends StatelessWidget {
  final Track t;
  final List<Track> list;
  final String? inPlaylist;
  const TrackTile(this.t, this.list, {super.key, this.inPlaylist});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<SonaController>();
    final active = c.current?.path == t.path;
    return ListTile(
      dense: true,
      leading: Cover(t, size: 44),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: active ? C.accent : C.text, fontWeight: FontWeight.w600)),
      subtitle: Text('${t.artist} • ${t.album}', maxLines: 1,
          overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.dim)),
      onTap: () => c.playTrack(t, list),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
            icon: Icon(c.favs.contains(t.path) ? Icons.favorite : Icons.favorite_border,
                color: C.accent, size: 20),
            onPressed: () => c.toggleFav(t)),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 20),
          onSelected: (v) => v == '__rm'
              ? c.removeFromPlaylist(inPlaylist!, t)
              : c.addToPlaylist(v, t),
          itemBuilder: (_) => [
            if (inPlaylist != null)
              const PopupMenuItem(value: '__rm', child: Text('Quitar de la playlist')),
            for (final n in c.playlists.keys)
              PopupMenuItem(value: n, child: Text('Añadir a "$n"')),
          ],
        ),
      ]),
    );
  }
}

// ───────────────────────── Shell responsivo ─────────────────────────
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  static const _dest = [
    (Icons.home_rounded, 'Inicio'),
    (Icons.library_music_rounded, 'Biblioteca'),
    (Icons.favorite_rounded, 'Favoritos'),
    (Icons.queue_music_rounded, 'Playlists'),
  ];

  Widget get page => switch (tab) {
        0 => const HomePage(),
        1 => const LibraryPage(),
        2 => const FavsPage(),
        _ => const PlaylistsPage(),
      };

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SonaController>();
    return LayoutBuilder(builder: (_, b) {
      if (b.maxWidth >= 900) return _desktop(c);
      return _mobile(c);
    });
  }

  Widget _desktop(SonaController c) => Scaffold(
        body: Column(children: [
          Expanded(
              child: Row(children: [
            Container(
              width: 84, color: Colors.black,
              child: Column(children: [
                const SizedBox(height: 20),
                const Text('SONA', style: TextStyle(fontFamily: 'serif', fontSize: 18, fontWeight: FontWeight.bold, color: C.accent)),
                const SizedBox(height: 20),
                for (var i = 0; i < _dest.length; i++)
                  IconButton(
                      iconSize: 30,
                      tooltip: _dest[i].$2,
                      color: tab == i ? C.accent : C.dim,
                      icon: Icon(_dest[i].$1),
                      onPressed: () => setState(() => tab = i)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.folder_open, color: C.dim), tooltip: 'Elegir carpeta de música', onPressed: c.pickFolder),
                const SizedBox(height: 12),
              ]),
            ),
            Expanded(
                child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                const SearchField(),
                const SizedBox(height: 12),
                Expanded(child: Box(child: page)),
              ]),
            )),
            if (c.current != null)
              Padding(padding: const EdgeInsets.fromLTRB(0, 12, 12, 12), child: SizedBox(width: 320, child: NowPlayingPanel(c))),
          ])),
          const PlayerBar(),
        ]),
      );

  Widget _mobile(SonaController c) => Scaffold(
        appBar: AppBar(
          backgroundColor: C.bg,
          title: const SearchField(),
          actions: [IconButton(icon: const Icon(Icons.folder_open), onPressed: c.pickFolder)],
        ),
        body: Padding(padding: const EdgeInsets.all(8), child: page),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
          if (c.current != null) const MiniPlayer(),
          NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: [for (final d in _dest) NavigationDestination(icon: Icon(d.$1), label: d.$2)],
          ),
        ]),
      );
}

class SearchField extends StatelessWidget {
  const SearchField({super.key});
  @override
  Widget build(BuildContext context) => TextField(
        onChanged: context.read<SonaController>().setQuery,
        decoration: InputDecoration(
            hintText: 'Buscar…',
            prefixIcon: const Icon(Icons.search),
            filled: true, fillColor: C.panel, isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none)),
      );
}

// ───────────────────────── Páginas ─────────────────────────
class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<SonaController>();
    if (c.scanning) return const Center(child: CircularProgressIndicator());
    if (c.tracks.isEmpty) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.album, size: 72, color: C.accent),
        const SizedBox(height: 12),
        const Text('Añade tu música para empezar'),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: c.pickFolder, icon: const Icon(Icons.folder_open), label: const Text('Elegir carpeta')),
      ]));
    }
    final recent = c.recents.map(c.byPath).whereType<Track>().toList();
    final mixes = [for (var i = 0; i < 4; i++) c.dailyMix(i)];
    final quick = [...c.favs.map(c.byPath).whereType<Track>()].take(4).toList();
    return ListView(children: [
      Text('Inicio', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontFamily: 'serif')),
      const SizedBox(height: 16),
      const Text('Recently Played', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      SizedBox(
        height: 170,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final t in (recent.isEmpty ? c.tracks.take(8) : recent))
            GestureDetector(
              onTap: () => c.playTrack(t, recent.isEmpty ? c.tracks : recent),
              child: Container(
                width: 130, margin: const EdgeInsets.only(right: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Cover(t, size: 130),
                  const SizedBox(height: 6),
                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.dim, fontSize: 12)),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 20),
      const Text('Daily Mix', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (var i = 0; i < mixes.length; i++)
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => c.playTrack(mixes[i].first, mixes[i]),
            child: Container(
              width: 170, padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: C.card.withOpacity(.6), borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Cover(mixes[i].first, size: 44),
                const SizedBox(width: 10),
                Expanded(child: Text('Mix ${i + 1}\n${mixes[i].length} canciones', style: const TextStyle(fontSize: 13))),
              ]),
            ),
          ),
      ]),
      if (quick.isNotEmpty) ...[
        const SizedBox(height: 20),
        const Text('Accesos rápidos', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        for (final t in quick) TrackTile(t, quick),
      ],
    ]);
  }
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<SonaController>();
    final l = c.filtered;
    if (l.isEmpty) return const Center(child: Text('Sin resultados'));
    return ListView.builder(itemCount: l.length, itemBuilder: (_, i) => TrackTile(l[i], l));
  }
}

class FavsPage extends StatelessWidget {
  const FavsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<SonaController>();
    final l = c.favs.map(c.byPath).whereType<Track>().toList();
    if (l.isEmpty) return const Center(child: Text('Aún no tienes favoritos'));
    return ListView.builder(itemCount: l.length, itemBuilder: (_, i) => TrackTile(l[i], l));
  }
}

class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<SonaController>();
    return ListView(children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Nueva playlist'),
          onPressed: () async {
            final ctl = TextEditingController();
            final n = await showDialog<String>(
                context: context,
                builder: (_) => AlertDialog(
                      title: const Text('Nueva playlist'),
                      content: TextField(controller: ctl, autofocus: true),
                      actions: [TextButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('Crear'))],
                    ));
            if (n != null) c.createPlaylist(n);
          },
        ),
      ),
      for (final e in c.playlists.entries)
        ExpansionTile(
          title: Text(e.key),
          subtitle: Text('${e.value.length} canciones', style: const TextStyle(color: C.dim)),
          trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => c.deletePlaylist(e.key)),
          children: [
            for (final t in e.value.map(c.byPath).whereType<Track>())
              TrackTile(t, e.value.map(c.byPath).whereType<Track>().toList(), inPlaylist: e.key),
          ],
        ),
    ]);
  }
}

// ───────────────────────── Reproductor ─────────────────────────
class NowPlayingPanel extends StatelessWidget {
  final SonaController c;
  const NowPlayingPanel(this.c, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = c.current!;
    return Box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Reproduciendo', style: TextStyle(fontFamily: 'serif', fontSize: 16)),
        const SizedBox(height: 12),
        AspectRatio(aspectRatio: 1, child: LayoutBuilder(builder: (_, b) => Cover(t, size: b.maxWidth))),
        const SizedBox(height: 14),
        Text(t.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold), maxLines: 2, overflow: TextOverflow.ellipsis),
        Text(t.artist, style: const TextStyle(color: C.dim)),
        const SizedBox(height: 8),
        Text(t.album, style: const TextStyle(color: C.dim, fontSize: 12)),
      ]),
    );
  }
}

String _fmt(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

class Controls extends StatelessWidget {
  const Controls({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<SonaController>();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(icon: Icon(Icons.shuffle, color: c.shuffle ? C.accent : C.dim), onPressed: c.toggleShuffle),
      IconButton(icon: const Icon(Icons.skip_previous_rounded), iconSize: 30, onPressed: c.prev),
      IconButton.filled(
          style: IconButton.styleFrom(backgroundColor: C.accent, foregroundColor: C.bg),
          iconSize: 32,
          icon: Icon(c.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
          onPressed: c.toggle),
      IconButton(icon: const Icon(Icons.skip_next_rounded), iconSize: 30, onPressed: () => c.next()),
      IconButton(
          icon: Icon(c.loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
              color: c.loop == LoopMode.off ? C.dim : C.accent),
          onPressed: c.cycleLoop),
    ]);
  }
}

class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key});
  @override
  Widget build(BuildContext context) {
    final p = context.read<SonaController>().player;
    return StreamBuilder<Duration>(
        stream: p.positionStream,
        builder: (_, s) {
          final pos = s.data ?? Duration.zero;
          final dur = p.duration ?? Duration.zero;
          final max = dur.inMilliseconds.toDouble();
          return Row(children: [
            Text(_fmt(pos), style: const TextStyle(fontSize: 11, color: C.dim)),
            Expanded(
                child: Slider(
                    value: max == 0 ? 0 : pos.inMilliseconds.clamp(0, max.toInt()).toDouble(),
                    max: max == 0 ? 1 : max,
                    onChanged: (v) => p.seek(Duration(milliseconds: v.toInt())))),
            Text(_fmt(dur), style: const TextStyle(fontSize: 11, color: C.dim)),
          ]);
        });
  }
}

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<SonaController>();
    final t = c.current;
    return Container(
      height: 84, color: const Color(0xFF241420),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        SizedBox(
            width: 260,
            child: t == null
                ? const SizedBox()
                : Row(children: [
                    Cover(t, size: 52),
                    const SizedBox(width: 10),
                    Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(t.artist, maxLines: 1, style: const TextStyle(color: C.dim, fontSize: 12)),
                    ])),
                  ])),
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: const [
          Controls(),
          SizedBox(height: 28, child: ProgressBar()),
        ])),
        SizedBox(
            width: 260,
            child: StreamBuilder<double>(
                stream: c.player.volumeStream,
                builder: (_, s) => Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      const Icon(Icons.volume_up, size: 20, color: C.dim),
                      SizedBox(width: 140, child: Slider(value: s.data ?? 1, onChanged: c.player.setVolume)),
                    ]))),
      ]),
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<SonaController>();
    final t = c.current!;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(18)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Cover(t, size: 44),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(t.artist, maxLines: 1, style: const TextStyle(color: C.dim, fontSize: 12)),
          ])),
          IconButton(icon: const Icon(Icons.skip_previous_rounded), onPressed: c.prev),
          IconButton(icon: Icon(c.playing ? Icons.pause_rounded : Icons.play_arrow_rounded), onPressed: c.toggle),
          IconButton(icon: const Icon(Icons.skip_next_rounded), onPressed: () => c.next()),
        ]),
        const SizedBox(height: 22, child: ProgressBar()),
      ]),
    );
  }
}
