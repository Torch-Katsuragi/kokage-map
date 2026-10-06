// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
/// ホームの「フォルダを選んで開く」: いつもの地図（Documents/KokageMap）の中だけを、レイヤドロワーと同じ見た目でたどる
///
/// OS のフォルダ選択はファイルが大きな四角で並び、端末のどこでも選べてしまう（2026-10-06）。ここは KokageMap より上へ
/// 行けない。外の場所は右上のメニュー「端末の別の場所…」からだけ（OS の選択を出す）。
/// gpkg の中身は読まない（ドロワーのノードを流用すると 1.5 万面の小班まで読み込んで重い）。ファイル名だけ並べる。
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../core/fs/project_folder_picker.dart';
import '../../core/hidden_dirs.dart';
import '../../core/node_types.dart';
import '../../i18n/strings.g.dart';
import '../../presentation/node_presenter.dart';
import '../../services/global_folder_locator.dart';
import '../../services/google_drive/sync_base_store.dart';
import '../../services/kmeta_service.dart';

/// 選んだフォルダの絶対パスを返す（やめたら null）
class FolderBrowserScreen extends StatefulWidget {
  const FolderBrowserScreen({super.key});

  static Future<String?> show(BuildContext context) =>
      Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const FolderBrowserScreen()));

  @override
  State<FolderBrowserScreen> createState() => _FolderBrowserScreenState();
}

class _Entry {
  _Entry(this.path, {required this.isDirectory, this.isDrive = false});
  final String path;
  final bool isDirectory;
  final bool isDrive;
  String get name => p.basename(path);
}

class _FolderBrowserScreenState extends State<FolderBrowserScreen> {
  String? _root;

  /// たどった道（先頭が root）。Drive 連携かどうかも持つ（タイトルの色）
  final List<_Entry> _trail = [];
  List<_Entry> _entries = const [];
  bool _loading = true;

  String get _current => _trail.last.path;
  bool get _underDrive => _trail.any((e) => e.isDrive);

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final root = await GlobalFolderLocator.kokageRoot();
    if (!await fs.exists(root)) await fs.createDirectory(root);
    _root = root;
    _trail.add(_Entry(root, isDirectory: true));
    await _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final dir = _current;
    final listed = await fs.list(dir);
    final dirs = <_Entry>[];
    final files = <_Entry>[];
    for (final e in listed) {
      if (e.name.startsWith('.')) continue;
      if (e.isDirectory) {
        if (e.name == SyncBaseStore.dirName || hiddenLegacyDirs.contains(p.normalize(e.path))) continue;
        final meta = await KMetaService.instance.getRawMeta(e.path);
        dirs.add(_Entry(e.path, isDirectory: true, isDrive: meta?.sync.isLinked ?? false));
      } else if (_shownFile(e)) {
        files.add(_Entry(e.path, isDirectory: false));
      }
    }
    dirs.sort((a, b) => a.name.compareTo(b.name));
    files.sort((a, b) => a.name.compareTo(b.name));
    if (!mounted || dir != _current) return;
    setState(() {
      _entries = [...dirs, ...files];
      _loading = false;
    });
  }

  /// 中身の目印として並べるファイル（地図のデータと写真）。`.qgs~` などの裏方は出さない
  static bool _shownFile(KFileEntry e) {
    const exts = {'.gpkg', '.geojson', '.tif', '.tiff', '.jpg', '.jpeg', '.png'};
    return exts.contains(p.extension(e.name).toLowerCase());
  }

  void _enter(_Entry e) {
    _trail.add(e);
    _load();
  }

  void _up() {
    if (_trail.length <= 1) return;
    _trail.removeLast();
    _load();
  }

  Future<void> _newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.folderBrowser.newFolder),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.folderBrowser.newFolderHint),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(t.common.ok)),
        ],
      ),
    );
    final n = name?.trim() ?? '';
    if (n.isEmpty || !mounted) return;
    if (n.startsWith('.') || n.contains(RegExp(r'[\\/:*?"<>|]'))) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.folderBrowser.badName)));
      return;
    }
    final path = p.join(_current, n);
    if (await fs.exists(path)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.folderBrowser.exists(name: n))));
      return;
    }
    await fs.createDirectory(path);
    await _load();
  }

  Future<void> _pickElsewhere() async {
    final dir = await pickProjectFolder();
    if (dir != null && mounted) Navigator.pop(context, dir);
  }

  @override
  Widget build(BuildContext context) {
    final atRoot = _trail.length <= 1;
    final title = _trail.isEmpty ? '' : (atRoot ? p.basename(_root!) : _trail.last.name);
    return PopScope(
      canPop: atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.folderBrowser.title),
          actions: [
            PopupMenuButton<String>(
              onSelected: (_) => _pickElsewhere(),
              itemBuilder: (_) => [PopupMenuItem(value: 'elsewhere', child: Text(t.folderBrowser.elsewhere))],
            ),
          ],
        ),
        body: _trail.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _TitleBar(
                    title: title,
                    drive: _underDrive,
                    onBack: atRoot ? null : _up,
                    onAdd: _newFolder,
                  ),
                  Expanded(child: _buildList()),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.map),
                          label: Text(t.folderBrowser.open(name: title)),
                          onPressed: () => Navigator.pop(context, _current),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_entries.isEmpty) {
      return Center(child: Text(t.folderBrowser.empty, style: const TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final e = _entries[i];
        if (!e.isDirectory) {
          final gpkg = p.extension(e.name).toLowerCase() == '.gpkg';
          return ListTile(
            dense: true,
            enabled: false,
            leading: Icon(
              gpkg ? NodePresenter.getIconForType(NodeType.geopackage) : Icons.insert_drive_file_outlined,
              color: Colors.grey.shade400,
            ),
            title: Text(e.name),
          );
        }
        return ListTile(
          leading: e.isDrive
              ? const Icon(Icons.cloud, color: cloudColor)
              : Icon(NodePresenter.getIconForType(NodeType.folder), color: NodePresenter.getColorForType(NodeType.folder)),
          title: Text(e.name),
          subtitle: e.isDrive ? Text(t.layerDrawer.folder.driveLinked, style: const TextStyle(fontSize: 12, color: Colors.grey)) : null,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _enter(e),
        );
      },
    );
  }
}

/// レイヤドロワーのタイトルバー（`LayerDrawerTitleBar`）と同じ見た目。ドロワーの方はノードを要るので形だけ写す
class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.title, required this.drive, required this.onAdd, this.onBack});
  final String title;
  final bool drive;
  final VoidCallback? onBack;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      color: drive ? cloudColor : const Color(0xFF424242),
      child: Row(
        children: [
          if (onBack != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
                tooltip: t.layerDrawer.titleBar.goUp,
                onPressed: onBack,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          DecoratedBox(
            decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.all(Radius.circular(8))),
            child: IconButton(
              icon: const Icon(Icons.create_new_folder_outlined, color: Colors.black87),
              tooltip: t.folderBrowser.newFolder,
              onPressed: onAdd,
            ),
          ),
        ],
      ),
    );
  }
}
