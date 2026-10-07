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
// Root Maps: Layer Import/Export Dialog Widget
// レイヤー全体のインポート・エクスポート機能を提供するダイアログ
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../models/nodes/layer_node.dart';
import '../services/coordinate/epsg_registry.dart';
import '../services/import_export/import_export_service.dart';

/// レイヤーの書き出しダイアログ（取り込みはドロワーの GeoPackage 行から直接）
class LayerImportExportDialog extends StatefulWidget {
  /// エクスポート対象のレイヤー
  final LayerNode exportLayer;

  const LayerImportExportDialog({super.key, required this.exportLayer});

  /// エクスポート用ダイアログを表示
  static Future<void> showExportDialog(
    BuildContext context, {
    required LayerNode exportLayer,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => LayerImportExportDialog(exportLayer: exportLayer),
    );
  }

  @override
  State<LayerImportExportDialog> createState() =>
      _LayerImportExportDialogState();
}

class _LayerImportExportDialogState extends State<LayerImportExportDialog> {
  // 最後に使用したCRSを保持（セッション中）
  static EpsgDefinition? _lastUsedCrs;
  
  final ImportExportService _importExportService = ImportExportService();
  final EpsgRegistry _epsgRegistry = EpsgRegistry();
  bool _isProcessing = false;
  String? _statusMessage;
  ImportExportResult? _lastResult;
  double _progressValue = 0.0;
  String _progressMessage = '';

  // エクスポート設定
  FileFormat _exportFormat = FileFormat.shapefile;
  bool _exportAsPointCloud = false; // 初期値はオフ
  bool _includeRowNumber = false; // 初期値はオフ
  EpsgDefinition? _selectedCrs = _lastUsedCrs; // 最後に使用したCRSを初期値に
  String _crsSearchQuery = ''; // CRS検索クエリ

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.importExport.exportTitle),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // コンテキスト情報
              _buildContextCard(),
              const SizedBox(height: 16),

              ..._buildExportUI(),

              // 進行状況表示
              if (_isProcessing) _buildProgressCard(),

              // ステータス表示
              if (_statusMessage != null) _buildStatusCard(),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        // エクスポートボタン（左寄せ）
        ElevatedButton.icon(
            onPressed: _isProcessing ? null : _handleExport,
            icon: _isProcessing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download),
            label: Text(_isProcessing ? t.importExport.exporting : t.importExport.exportTitle),
          ),
        // Closeボタン（右寄せ）
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.common.close),
        ),
      ],
    );
  }

  /// コンテキスト情報カード
  Widget _buildContextCard() {
    return Card(
      color: Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.importExport.exportSource,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              t.importExport.layerLabel(
                name: widget.exportLayer.name,
                type: '${widget.exportLayer.runtimeType}',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// エクスポートUI構築
  List<Widget> _buildExportUI() {
    return [
      // エクスポート形式選択
      Text(t.importExport.exportFormat, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      DropdownButtonFormField<FileFormat>(
        initialValue: _exportFormat,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: t.importExport.selectExportFormat,
        ),
        items:
            _importExportService
                .getSupportedExportFormats()
                .map(
                  (format) => DropdownMenuItem(
                    value: format,
                    child: Text(format.value),
                  ),
                )
                .toList(),
        onChanged: (format) {
          if (format != null) {
            setState(() => _exportFormat = format);
          }
        },
      ),
      const SizedBox(height: 16),

      // Shapefile用オプション
      if (_exportFormat == FileFormat.shapefile) ...[
        Card(
          color: Colors.orange[50],
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.importExport.shapefileOptions,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                // Point Cloudオプション（Line/Polygonレイヤーのみ）
                if (widget.exportLayer is! PointLayerNode)
                  CheckboxListTile(
                    title: Text(t.importExport.exportAsPointCloud),
                    subtitle: Text(t.importExport.exportAsPointCloudDesc),
                    value: _exportAsPointCloud,
                    onChanged: (value) {
                      setState(() => _exportAsPointCloud = value ?? false);
                    },
                  ),
                CheckboxListTile(
                  title: Text(t.importExport.includeRowNumber),
                  subtitle: Text(t.importExport.includeRowNumberDesc),
                  value: _includeRowNumber,
                  onChanged: (value) {
                    setState(() => _includeRowNumber = value ?? false);
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        
        // CRS選択セクション
        _buildCrsSelector(),
        const SizedBox(height: 16),
      ],
    ];
  }

  /// CRS選択ウィジェット
  Widget _buildCrsSelector() {
    // 検索クエリに基づいてCRSをフィルタリング
    final availableCrs = _crsSearchQuery.isEmpty
        ? _epsgRegistry.allDefinitions
        : _epsgRegistry.search(_crsSearchQuery);

    return Card(
      color: Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.importExport.crsTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            
            // 現在の選択表示
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Row(
                children: [
                  const Icon(Icons.public, size: 20, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _selectedCrs?.displayString ?? t.importExport.crsDefault,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: _selectedCrs == null ? Colors.grey[600] : Colors.black,
                      ),
                    ),
                  ),
                  if (_selectedCrs != null)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() => _selectedCrs = null),
                      tooltip: t.importExport.resetToWgs84,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            
            // CRS検索
            TextField(
              decoration: InputDecoration(
                hintText: t.importExport.crsSearchHint,
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: const OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white,
              ),
              onChanged: (value) => setState(() => _crsSearchQuery = value),
            ),
            const SizedBox(height: 8),
            
            // CRSリスト
            Container(
              height: 150,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: ListView.builder(
                itemCount: availableCrs.length,
                itemBuilder: (context, index) {
                  final crs = availableCrs[index];
                  final isSelected = _selectedCrs?.code == crs.code;
                  final isWgs84 = crs.code == 'EPSG:4326';
                  
                  return ListTile(
                    dense: true,
                    selected: isSelected,
                    selectedTileColor: Colors.blue[100],
                    leading: Icon(
                      isWgs84 ? Icons.language : Icons.grid_on,
                      size: 18,
                      color: isSelected ? Colors.blue : Colors.grey,
                    ),
                    title: Text(
                      crs.displayString,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    subtitle: crs.prefectures != null
                        ? Text(
                            crs.prefectures!.take(3).join(', '),
                            style: const TextStyle(fontSize: 11),
                          )
                        : null,
                    onTap: () {
                      setState(() {
                        _selectedCrs = isWgs84 ? null : crs;
                      });
                    },
                  );
                },
              ),
            ),
            
            // 注意書き
            if (_selectedCrs != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: Colors.blue[700]),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      t.importExport.crsTransformNote(code: _selectedCrs!.code),
                      style: TextStyle(fontSize: 11, color: Colors.blue[700]),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 進行状況カード
  Widget _buildProgressCard() {
    return Card(
      color: Colors.orange[50],
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.importExport.exportProgress,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progressValue),
            const SizedBox(height: 8),
            Text(_progressMessage),
            Text(t.importExport.percentCompleted(percent: (_progressValue * 100).toInt())),
          ],
        ),
      ),
    );
  }

  /// ステータスカード
  Widget _buildStatusCard() {
    return Card(
      color: _lastResult?.success == true ? Colors.green[50] : Colors.red[50],
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _lastResult?.success == true
                      ? Icons.check_circle
                      : Icons.error,
                  color:
                      _lastResult?.success == true ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(_lastResult?.success == true ? t.importExport.success : t.common.error),
              ],
            ),
            const SizedBox(height: 4),
            Text(_statusMessage!),
            if (_lastResult?.metadata != null) ...[
              const SizedBox(height: 8),
              Text(t.importExport.details, style: Theme.of(context).textTheme.labelSmall),
              ...(_lastResult!.metadata!.entries.map(
                (e) => Text('• ${e.key}: ${e.value}'),
              )),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _handleExport() async {
    // file_picker 12 の saveFile は中身（bytes）を先に渡す作り（Android の SAF は「保存先を選んでから書く」ができない）。
    // 一時フォルダに書き出してから保存ダイアログへ。Shapefile は .shp/.shx/.dbf/.prj の組なので zip にまとめる
    Directory? tmpDir;
    try {
      setState(() {
        _isProcessing = true;
        _statusMessage = null;
        _progressValue = 0.0;
        _progressMessage = t.importExport.startingExport;
      });

      _updateProgress(0.3, t.importExport.analyzingLayer);

      // エクスポートオプションを作成
      final exportOptions = ExportOptions(
        targetCrs: _selectedCrs,
        convertToPointCloud: _exportAsPointCloud,
        includeRowNumber: _includeRowNumber,
      );

      final ext = _exportFormat.extension.replaceFirst('.', '');
      final baseName = widget.exportLayer.name;
      tmpDir = await Directory.systemTemp.createTemp('kokage_export_');
      final tmpPath = '${tmpDir.path}${Platform.pathSeparator}$baseName.$ext';

      final exportResult = await _importExportService.exportLayer(
        widget.exportLayer,
        tmpPath,
        format: _exportFormat,
        options: exportOptions,
      );
      if (!exportResult.success) {
        setState(() {
          _isProcessing = false;
          _lastResult = exportResult;
          _statusMessage = exportResult.errorMessage ?? t.importExport.exportFailedShort;
        });
        return;
      }

      _updateProgress(0.8, t.importExport.saving);
      final isShapefile = _exportFormat == FileFormat.shapefile;
      final bytes = isShapefile ? _zipDirectory(tmpDir) : await File(tmpPath).readAsBytes();
      final saveExt = isShapefile ? 'zip' : ext;
      final saved = await FilePicker.saveFile(
        dialogTitle: t.importExport.exportTitle,
        fileName: '$baseName.$saveExt',
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: [saveExt],
      );
      if (saved == null) {
        setState(() {
          _isProcessing = false;
          _statusMessage = t.importExport.exportCancelled;
        });
        return;
      }

      _updateProgress(1.0, t.importExport.exportCompleted);

      // 成功時は選択したCRSを保持
      if (exportResult.success) {
        _lastUsedCrs = _selectedCrs;
      }

      setState(() {
        _isProcessing = false;
        _lastResult = exportResult;
        _statusMessage =
            exportResult.success
                ? t.importExport.exportCompletedSuccess
                : exportResult.errorMessage ?? t.importExport.exportFailedShort;
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = t.importExport.exportFailed(error: e.toString());
        _lastResult = ImportExportResult.error(e.toString());
      });
    } finally {
      try {
        tmpDir?.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// フォルダの中のファイルを 1 つの zip に（Shapefile の組を 1 ファイルで保存するため）
  static Uint8List _zipDirectory(Directory dir) {
    final archive = Archive();
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final data = entity.readAsBytesSync();
      archive.addFile(ArchiveFile.bytes(entity.uri.pathSegments.last, data));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  void _updateProgress(double value, String message) {
    if (mounted) {
      setState(() {
        _progressValue = value;
        _progressMessage = message;
      });
    }
  }
}
