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
/// 毎木調査の入力シート（gpkg の見出しのメニュー「毎木調査」から）
///
/// 樹種（前の木と同じものを選んだまま）→ 胸高直径（数字の鍵盤）→ 記録、を最短の手数にする。
/// 樹高は TruPulse の高さルーチン（HT）が届けば入る。位置は GNSS か、TruPulse で標準地の中心から測る。
/// docs/features/tree-tally.md
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../devices/trupulse/trupulse_measurement.dart';
import '../../devices/trupulse/trupulse_providers.dart';
import '../../devices/trupulse/trupulse_service.dart';
import '../../devices/trupulse/trupulse_tool.dart';
import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../providers/notification_providers.dart';
import '../../providers/service_providers.dart';
import '../../providers/tool_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/tree_tally/stem_volume.dart';
import '../../services/tree_tally/tree_tally_stats.dart';
import '../../services/tree_tally/tree_tally_store.dart';
import '../../utils/app_navigator.dart';

/// 毎木調査のシートを開く。レイヤが無ければ [gpkg] に作る。
/// レイヤ一覧の行から開く。シートを閉じるまで待つので、行が組み直されても困らないよう容れ物を握る
Future<void> showTreeTallySheet(BuildContext context, GeoPackageNode gpkg) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final layers = await TreeTallyLayers.ensure(gpkg);
  if (layers == null || !context.mounted) return;
  final host = appDialogContext ?? context;
  container.read(featureRefreshTriggerProvider.notifier).trigger();
  final service = container.read(trupulseServiceProvider);
  container.read(mapFlashProvider.notifier).show(t.treeTally.title);
  service.claimedByTally = true;
  try {
    await showModalBottomSheet<void>(
      context: host,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TreeTallySheet(layers: layers),
    );
  } finally {
    service.claimedByTally = false;
    container.read(mapFlashProvider.notifier).show(t.treeTally.closed);
    container.read(featureRefreshTriggerProvider.notifier).trigger();
  }
}

enum _PosSource { gnss, trupulse }

class TreeTallySheet extends ConsumerStatefulWidget {
  final TreeTallyLayers layers;
  const TreeTallySheet({super.key, required this.layers});

  @override
  ConsumerState<TreeTallySheet> createState() => _TreeTallySheetState();
}

class _TreeTallySheetState extends ConsumerState<TreeTallySheet> {
  // 調査のあいだ覚えておく（シートを閉じて開き直しても）
  static String? _lastSpecies;
  static String? _lastPlotId;
  static _PosSource _lastPos = _PosSource.gnss;

  List<TallyPlot> _plots = const [];
  TallyPlot? _plot;
  List<String> _species = List.of(TreeTallySchema.defaultSpecies);
  String? _selectedSpecies;
  int _treeNo = 1;
  String _dbh = '';
  final _height = TextEditingController();
  final _note = TextEditingController();
  double? _truPulseHeight;
  TruPulseMeasurement? _offset;
  _PosSource _pos = _lastPos;
  bool _busy = false;
  StreamSubscription<double>? _heightSub;
  StreamSubscription<TruPulseMeasurement>? _measureSub;

  TreeTallyLayers get _layers => widget.layers;
  TruPulseService get _service => ref.read(trupulseServiceProvider);

  // GPS を待つ間にシートが閉じられても通知・地図の描き直しができるよう、先に握っておく（閉じた画面の ref は使えない）
  late final NotificationCenter _notifications;
  late final FeatureRefreshTrigger _featureRefresh;

  @override
  void initState() {
    super.initState();
    _notifications = ref.read(notificationCenterProvider.notifier);
    _featureRefresh = ref.read(featureRefreshTriggerProvider.notifier);
    _heightSub = _service.heightStream.listen((h) {
      if (!mounted) return;
      setState(() {
        _truPulseHeight = h;
        _height.text = h.toStringAsFixed(1);
      });
    });
    _measureSub = _service.measurementStream.listen((m) {
      if (mounted) setState(() => _offset = m);
    });
    _load();
  }

  Future<void> _load() async {
    final plots = await _layers.loadPlots();
    final used = await _layers.usedSpecies();
    if (!mounted) return;
    setState(() {
      _plots = plots;
      _plot = plots.where((p) => p.plotId == _lastPlotId).firstOrNull ?? plots.lastOrNull;
      _species = [...used, ...TreeTallySchema.defaultSpecies.where((s) => !used.contains(s))];
      if (_lastSpecies != null && !_species.contains(_lastSpecies)) _species.add(_lastSpecies!);
      _selectedSpecies = _lastSpecies ?? (used.isNotEmpty ? used.first : null);
    });
    await _refreshTreeNo();
  }

  /// 次の番号を読み直した回数。待つ間に標準地を切り替えたり記録したりしたら、古い読みで番号を上書きしない
  int _treeNoGen = 0;

  Future<void> _refreshTreeNo() async {
    final plot = _plot;
    if (plot == null) return;
    final gen = ++_treeNoGen;
    final n = await _layers.nextTreeNo(plot.plotId);
    if (mounted && gen == _treeNoGen) setState(() => _treeNo = n);
  }

  @override
  void dispose() {
    _heightSub?.cancel();
    _measureSub?.cancel();
    _height.dispose();
    _note.dispose();
    super.dispose();
  }

  void _notify(String title, NotificationLevel level, {String? detail}) =>
      _notifications.add(title: title, detail: detail, level: level);

  // ── 標準地 ─────────────────────────────

  Future<void> _createCirclePlot() async {
    final areaHa = await showDialog<double>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.treeTally.newCirclePlot),
        children: [
          for (final ha in const [0.01, 0.02, 0.04, 0.05, 0.1])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, ha),
              child: Text(t.treeTally.plotArea(ha: '$ha', r: circlePlotRadiusM(ha).toStringAsFixed(2))),
            ),
        ],
      ),
    );
    if (areaHa == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final gps = ref.read(gpsManagerServiceProvider);
      final info = await gps.startGpsSurveyWithWait();
      await gps.stopGpsSurvey();
      if (info == null || !info.isActive) {
        _notify(t.gps.gpsUnavailable, NotificationLevel.error);
        return;
      }
      final id = TreeTallyLayers.nextPlotId(_plots.map((p) => p.plotId));
      final plot = await _layers.createCirclePlot(id, LatLng(info.latitude!, info.longitude!), circlePlotRadiusM(areaHa));
      if (plot == null) return;
      _lastPlotId = plot.plotId;
      _notify(t.treeTally.plotCreated(id: id), NotificationLevel.success);
      _featureRefresh.trigger();
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 記録 ───────────────────────────────

  Future<void> _addSpecies() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.treeTally.addSpecies),
        content: TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: Text(t.common.ok)),
        ],
      ),
    );
    controller.dispose();
    final s = name?.trim() ?? '';
    if (s.isEmpty || !mounted) return;
    setState(() {
      if (!_species.contains(s)) _species.add(s);
      _selectedSpecies = _lastSpecies = s;
    });
  }

  void _key(String k) {
    setState(() {
      if (k == '⌫') {
        if (_dbh.isNotEmpty) _dbh = _dbh.substring(0, _dbh.length - 1);
      } else if (k == '.') {
        if (!_dbh.contains('.')) _dbh = _dbh.isEmpty ? '0.' : '$_dbh.';
      } else if (_dbh.length < 6) {
        _dbh += k;
      }
    });
  }

  Future<void> _record() async {
    final plot = _plot;
    final dbh = double.tryParse(_dbh);
    if (plot == null) return;
    if (dbh == null || dbh <= 0) {
      _notify(t.treeTally.needDbh, NotificationLevel.warning);
      return;
    }
    final species = _selectedSpecies ?? '';
    final height = double.tryParse(_height.text.trim());
    final fromTruPulse = height != null && _truPulseHeight != null && (height - _truPulseHeight!).abs() < 0.05;
    final attrs = <String, dynamic>{
      'plot_id': plot.plotId,
      'tree_no': _treeNo,
      'species': species,
      'dbh_cm': dbh,
      'height_m': height,
      'height_src': height == null ? null : (fromTruPulse ? 'trupulse' : 'manual'),
      'pos_src': _pos == _PosSource.gnss ? 'gnss' : 'trupulse',
      'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      'measured_at': DateTime.now().toIso8601String(),
    };
    setState(() => _busy = true);
    try {
      bool ok;
      if (_pos == _PosSource.trupulse) {
        final m = _offset;
        if (m == null) {
          _notify(t.treeTally.truPulseWaiting, NotificationLevel.warning);
          return;
        }
        final at = const Distance().offset(plot.center, m.hd, TruPulseTool.trueAzimuth(m.az, plot.center));
        ok = await _layers.addTreeAt(at, {
              ...attrs,
              // TruPulse ツールの点と同じ列（docs/devices/trupulse-360r.md「自動記録される属性」）
              'survey_az': m.az,
              'survey_inc': m.inc,
              'survey_hd': m.hd,
              'survey_sd': m.sd,
              'survey_vd': m.vd,
              'survey_stn': jsonEncode({
                'type': 'Point',
                'coordinates': [plot.center.longitude, plot.center.latitude],
              }),
              'survey_timestamp': m.timestamp.toIso8601String(),
            }) !=
            null;
      } else {
        _notify(t.gps.acquiringGps, NotificationLevel.info);
        final result = await ref.read(gpsToolProvider).recordCurrentGpsPosition(into: _layers.trees, extra: attrs);
        ok = result.recorded;
        if (result.isRejected) {
          _notify(t.gnssQuality.rejectedTitle, NotificationLevel.warning, detail: result.rejectReasons.join('\n'));
        } else if (result.warnings.isNotEmpty) {
          _notify(t.gnssQuality.warnTitle, NotificationLevel.warning, detail: result.warnings.join('\n'));
        } else if (!ok) {
          _notify(t.gps.gpsUnavailable, NotificationLevel.error);
        }
      }
      if (!ok) return;
      _lastSpecies = species;
      _lastPlotId = plot.plotId;
      _notify(t.treeTally.recorded(n: '$_treeNo', species: species, dbh: _dbh), NotificationLevel.success);
      _featureRefresh.trigger();
      if (!mounted) return;
      setState(() {
        _dbh = '';
        _height.clear();
        _note.clear();
        _truPulseHeight = null;
        _offset = null;
        // GPS を待つ間に別の標準地へ切り替えていたら、その標準地の番号（切り替えで読み直した）はそのまま
        if (_plot?.plotId == plot.plotId) {
          _treeNo++;
          _treeNoGen++; // 記録の前に頼んだ読み直しは古い
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 画面 ───────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 1,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            Row(children: [
              Text(t.treeTally.title, style: theme.textTheme.titleLarge),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.table_chart),
                label: Text(t.treeTally.summary),
                onPressed: () => showTreeTallySummary(context, ref, _layers),
              ),
            ]),
            _plotRow(),
            if (_plot != null) ...[
              const SizedBox(height: 8),
              Text(t.treeTally.treeNo(n: '$_treeNo'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(t.treeTally.species, style: theme.textTheme.labelLarge),
              Wrap(spacing: 6, runSpacing: 0, children: [
                for (final s in _species)
                  ChoiceChip(
                    label: Text(s),
                    selected: s == _selectedSpecies,
                    onSelected: (_) => setState(() => _selectedSpecies = _lastSpecies = s),
                  ),
                ActionChip(avatar: const Icon(Icons.add, size: 18), label: Text(t.treeTally.addSpecies), onPressed: _addSpecies),
              ]),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _dbhPad(theme)),
                const SizedBox(width: 12),
                // 接続・切断で表示を替える（サービスは ChangeNotifier）
                Expanded(child: ListenableBuilder(listenable: _service, builder: (_, _) => _sideFields(theme))),
              ]),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.check),
                label: Text(t.treeTally.record),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _busy ? null : _record,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _plotRow() {
    return Row(children: [
      Text('${t.treeTally.plot}: '),
      Expanded(
        child: _plots.isEmpty
            ? Text(t.treeTally.noPlot, style: const TextStyle(fontSize: 13, color: Colors.black54))
            : DropdownButton<TallyPlot>(
                isExpanded: true,
                value: _plot,
                items: [
                  for (final p in _plots)
                    DropdownMenuItem(
                      value: p,
                      child: Text('${p.plotId}  ${(p.areaM2 / 10000).toStringAsFixed(3)} ha'),
                    ),
                ],
                onChanged: (p) {
                  setState(() => _plot = p);
                  _lastPlotId = p?.plotId;
                  _refreshTreeNo();
                },
              ),
      ),
      IconButton(
        tooltip: t.treeTally.newCirclePlot,
        icon: const Icon(Icons.add_location),
        onPressed: _busy ? null : _createCirclePlot,
      ),
    ]);
  }

  Widget _dbhPad(ThemeData theme) {
    Widget key(String k) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), padding: EdgeInsets.zero),
              onPressed: () => _key(k),
              child: Text(k, style: const TextStyle(fontSize: 20)),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.treeTally.dbh, style: theme.textTheme.labelLarge),
      Container(
        height: 48,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(border: Border.all(color: theme.colorScheme.outline), borderRadius: BorderRadius.circular(4)),
        child: Text(_dbh, style: const TextStyle(fontSize: 24)),
      ),
      for (final row in const [
        ['7', '8', '9'],
        ['4', '5', '6'],
        ['1', '2', '3'],
        ['.', '0', '⌫'],
      ])
        Row(children: [for (final k in row) key(k)]),
    ]);
  }

  Widget _sideFields(ThemeData theme) {
    final m = _offset;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _height,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: t.treeTally.height,
          helperText: _truPulseHeight != null ? t.treeTally.heightFromTruPulse : null,
        ),
      ),
      TextField(controller: _note, decoration: InputDecoration(labelText: t.treeTally.note)),
      const SizedBox(height: 8),
      Text(t.treeTally.position, style: theme.textTheme.labelLarge),
      SegmentedButton<_PosSource>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: _PosSource.gnss, label: Text(t.treeTally.posGnss)),
          ButtonSegment(value: _PosSource.trupulse, label: Text(t.treeTally.posTruPulse)),
        ],
        selected: {_pos},
        onSelectionChanged: (s) => setState(() => _pos = _lastPos = s.first),
      ),
      if (_pos == _PosSource.trupulse)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            !_service.isConnected
                ? t.treeTally.truPulseNotConnected
                : m == null
                    ? t.treeTally.truPulseWaiting
                    : t.treeTally.truPulseOffset(hd: m.hd.toStringAsFixed(1), az: m.az.toStringAsFixed(0)),
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ),
    ]);
  }
}

/// 標準地ごとの集計を出す（CSV に保存できる）
Future<void> showTreeTallySummary(BuildContext context, WidgetRef ref, TreeTallyLayers layers) async {
  final region = await _loadVolumeRegion();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => _TallySummaryDialog(layers: layers, region: region, onSave: (tallies) => _saveCsv(ref, tallies)),
  );
}

// 材積式の地域（全体の設定。gpkg ごとではない）
const _volumeRegionKey = 'tree_tally_volume_region';

Future<VolumeRegion?> _loadVolumeRegion() async {
  try {
    final name = (await SharedPreferences.getInstance()).getString(_volumeRegionKey);
    return VolumeRegion.values.where((r) => r.name == name).firstOrNull;
  } catch (_) {
    return null;
  }
}

Future<void> _saveVolumeRegion(VolumeRegion? r) async {
  final prefs = await SharedPreferences.getInstance();
  if (r == null) {
    await prefs.remove(_volumeRegionKey);
  } else {
    await prefs.setString(_volumeRegionKey, r.name);
  }
}

String _volumeRegionLabel(VolumeRegion r) => switch (r) {
      VolumeRegion.kinkiChugoku => t.treeTally.volumeRegions.kinkiChugoku,
    };

class _TallySummaryDialog extends StatefulWidget {
  final TreeTallyLayers layers;
  final VolumeRegion? region;
  final void Function(List<PlotTally>) onSave;
  const _TallySummaryDialog({required this.layers, required this.region, required this.onSave});

  @override
  State<_TallySummaryDialog> createState() => _TallySummaryDialogState();
}

class _TallySummaryDialogState extends State<_TallySummaryDialog> {
  late VolumeRegion? _region = widget.region;
  List<PlotTally>? _tallies;

  /// 集計を頼んだ回数。地域を続けて切り替えると、先に頼んだ遅い集計が新しい集計を上書きしないよう、最後の回の結果だけ使う
  int _requested = 0;

  /// [_tallies] が何回目の集計か。[_requested] と違えば、今の地域の集計を待っている（CSV に保存させない）
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    _summarize();
  }

  Future<void> _summarize() async {
    final region = _region;
    final gen = ++_requested;
    final tallies = await widget.layers.summarize(
      volume: region == null ? null : (tr) => stemVolumeM3(region, tr.species, tr.dbhCm, tr.heightM),
    );
    if (!mounted || gen != _requested) return;
    setState(() {
      _tallies = tallies;
      _shown = gen;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tallies = _tallies;
    String f(double? v, int d) => v == null ? '–' : v.toStringAsFixed(d);
    // 一部の木だけの材積には * を付ける
    String vol(PlotSummary s) =>
        s.volumeSumM3 == null ? '–' : '${f(s.volumePerHa, 1)}${s.volumeCount < s.count ? '*' : ''}';
    const note = TextStyle(fontSize: 12, color: Colors.black54);
    return AlertDialog(
      title: Text(t.treeTally.summary),
      content: SizedBox(
        width: double.maxFinite,
        child: tallies == null
            ? const Center(child: CircularProgressIndicator())
            : tallies.every((p) => p.all.count == 0)
                ? Text(t.treeTally.noTrees)
                : SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text('${t.treeTally.volumeRegion}: '),
                        Expanded(
                          child: DropdownButton<VolumeRegion?>(
                            isExpanded: true,
                            value: _region,
                            items: [
                              DropdownMenuItem(value: null, child: Text(t.treeTally.volumeRegionNone)),
                              for (final r in VolumeRegion.values)
                                DropdownMenuItem(value: r, child: Text(_volumeRegionLabel(r))),
                            ],
                            onChanged: (r) {
                              setState(() => _region = r);
                              _saveVolumeRegion(r);
                              _summarize();
                            },
                          ),
                        ),
                      ]),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columnSpacing: 12,
                          headingRowHeight: 36,
                          dataRowMinHeight: 28,
                          dataRowMaxHeight: 32,
                          columns: [
                            DataColumn(label: Text(t.treeTally.plot)),
                            DataColumn(label: Text(t.treeTally.species)),
                            DataColumn(label: Text(t.treeTally.stat.count), numeric: true),
                            DataColumn(label: Text(t.treeTally.stat.perHa), numeric: true),
                            DataColumn(label: Text(t.treeTally.stat.basalArea), numeric: true),
                            DataColumn(label: Text(t.treeTally.stat.meanDbh), numeric: true),
                            DataColumn(label: Text(t.treeTally.stat.meanHeight), numeric: true),
                            DataColumn(label: Text(t.treeTally.stat.topHeight), numeric: true),
                            if (_region != null) DataColumn(label: Text(t.treeTally.stat.volume), numeric: true),
                          ],
                          rows: [
                            for (final p in tallies)
                              for (final (sp, s) in [(t.treeTally.all, p.all), for (final e in p.bySpecies.entries) (e.key, e.value)])
                                DataRow(cells: [
                                  DataCell(Text(sp == t.treeTally.all ? p.plotId : '')),
                                  DataCell(Text(sp, style: TextStyle(fontWeight: sp == t.treeTally.all ? FontWeight.bold : null))),
                                  DataCell(Text('${s.count}')),
                                  DataCell(Text(s.areaM2 > 0 ? f(s.stemsPerHa, 0) : t.treeTally.unknownArea)),
                                  DataCell(Text(f(s.basalAreaPerHa, 1))),
                                  DataCell(Text(f(s.meanDbhCm, 1))),
                                  DataCell(Text(f(s.meanHeightM, 1))),
                                  DataCell(Text(f(s.topHeightM, 1))),
                                  if (_region != null) DataCell(Text(vol(s))),
                                ]),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(t.treeTally.topHeightNote, style: note),
                      if (_region != null) Text(t.treeTally.volumeNote, style: note),
                    ]),
                  ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.save_alt),
          label: Text(t.treeTally.saveCsv),
          onPressed: tallies == null || _shown != _requested ? null : () => widget.onSave(tallies),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.close)),
      ],
    );
  }
}

Future<void> _saveCsv(WidgetRef ref, List<PlotTally> tallies) async {
  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
  final name = 'tree_tally_$stamp.csv';
  final notifications = ref.read(notificationCenterProvider.notifier); // 保存先を選ぶ間に画面が閉じても通知できるよう先に
  final saved = await FilePicker.saveFile(
    fileName: name,
    bytes: Uint8List.fromList(utf8.encode(plotTallyCsv(tallies, allLabel: t.treeTally.all))),
    type: FileType.custom,
    allowedExtensions: ['csv'],
  );
  if (saved == null) return;
  notifications.add(title: t.treeTally.csvSaved(name: name), level: NotificationLevel.success);
}
