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
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/nodes/geopackage_node.dart';
import '../models/nodes/layer_node.dart';
import '../services/coordinate/epsg_registry.dart';
import '../services/import_export/import_export_models.dart';
import '../services/import_export/import_export_service.dart';

/// レイヤー全体のImport/Export機能を提供するダイアログ
class LayerImportExportDialog extends StatefulWidget {
  /// 対象のGeoPackageNode（新規レイヤー作成先）
  final GeoPackageNode? targetGeoPackage;

  /// エクスポート対象のレイヤー（エクスポート時のみ）
  final LayerNode? exportLayer;

  /// コンストラクタ
  const LayerImportExportDialog({
    super.key,
    this.targetGeoPackage,
    this.exportLayer,
  });

  /// インポート用ダイアログを表示
  static Future<void> showImportDialog(
    BuildContext context, {
    required GeoPackageNode targetGeoPackage,
  }) {
    return showDialog<void>(
      context: context,
      builder:
          (context) =>
              LayerImportExportDialog(targetGeoPackage: targetGeoPackage),
    );
  }

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

  // ファイル情報（インポート時）
  String? _selectedFilePath;
  String? _selectedFileName;
  int? _selectedFileSize;
  bool _isDragging = false;

  // インポート設定
  int _maxFeaturesToImport = 50;

  // エクスポート設定
  FileFormat _exportFormat = FileFormat.shapefile;
  bool _exportAsPointCloud = false; // 初期値はオフ
  bool _includeRowNumber = false; // 初期値はオフ
  EpsgDefinition? _selectedCrs = _lastUsedCrs; // 最後に使用したCRSを初期値に
  String _crsSearchQuery = ''; // CRS検索クエリ

  /// ダイアログのモード判定
  bool get isImportMode => widget.targetGeoPackage != null;
  bool get isExportMode => widget.exportLayer != null;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(isImportMode ? 'Import Layer' : 'Export Layer'),
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

              // モード別UI
              if (isImportMode) ..._buildImportUI(),
              if (isExportMode) ..._buildExportUI(),

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
        // エクスポートボタン（エクスポートモード時、左寄せ）
        if (isExportMode)
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _handleExport,
            icon: _isProcessing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download),
            label: Text(_isProcessing ? 'Exporting...' : 'Export Layer'),
          )
        else
          const SizedBox.shrink(), // インポートモード時はプレースホルダー
        // Closeボタン（右寄せ）
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
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
              isImportMode ? 'Import Target' : 'Export Source',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              isImportMode
                  ? 'GeoPackage: ${widget.targetGeoPackage!.name}'
                  : 'Layer: ${widget.exportLayer!.name} (${widget.exportLayer!.runtimeType})',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// インポートUI構築
  List<Widget> _buildImportUI() {
    return [
      // サポート形式表示
      Text(
        'Supported Import Formats:',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        children:
            _importExportService
                .getSupportedImportExtensions()
                .map(
                  (ext) => Chip(
                    label: Text(ext),
                    backgroundColor: Colors.green[100],
                  ),
                )
                .toList(),
      ),
      const SizedBox(height: 16),

      // ドラッグ&ドロップエリア
      _buildDropArea(),
      const SizedBox(height: 8),

      // ファイル選択ボタン
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _isProcessing ? null : _handleFileSelection,
          icon: const Icon(Icons.folder_open),
          label: const Text('Select Layer File'),
        ),
      ),

      // 選択ファイル情報
      if (_selectedFilePath != null) ...[
        const SizedBox(height: 8),
        _buildSelectedFileCard(),
        const SizedBox(height: 8),
        _buildImportOptions(),
      ],

      // インポートボタン
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed:
              (_isProcessing || _selectedFilePath == null)
                  ? null
                  : _handleImport,
          icon:
              _isProcessing
                  ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Icon(Icons.file_upload),
          label: Text(_isProcessing ? 'Importing...' : 'Import Layer'),
        ),
      ),
    ];
  }

  /// エクスポートUI構築
  List<Widget> _buildExportUI() {
    return [
      // エクスポート形式選択
      Text('Export Format:', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      DropdownButtonFormField<FileFormat>(
        initialValue: _exportFormat,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          labelText: 'Select Export Format',
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
                  'Shapefile Export Options',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                // Point Cloudオプション（Line/Polygonレイヤーのみ）
                if (widget.exportLayer is! PointLayerNode)
                  CheckboxListTile(
                    title: const Text('Export as Point Cloud'),
                    subtitle: const Text(
                      'Convert line/polygon vertices to individual points',
                    ),
                    value: _exportAsPointCloud,
                    onChanged: (value) {
                      setState(() => _exportAsPointCloud = value ?? false);
                    },
                  ),
                CheckboxListTile(
                  title: const Text('Include Row Number'),
                  subtitle: const Text(
                    'Add ROW_NUM column (like # in attribute table)',
                  ),
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

  /// ドラッグ&ドロップエリア
  Widget _buildDropArea() {
    return DropTarget(
      onDragDone: _handleDrop,
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      child: Container(
        width: double.infinity,
        height: 100,
        decoration: BoxDecoration(
          border: Border.all(
            color: _isDragging ? Colors.blue : Colors.grey[400]!,
            width: _isDragging ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
          color: _isDragging ? Colors.blue[50] : Colors.grey[50],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_upload,
              size: 32,
              color: _isDragging ? Colors.blue : Colors.grey[600],
            ),
            const SizedBox(height: 4),
            Text(
              _isDragging
                  ? 'Drop layer file here'
                  : 'Drag & Drop layer file here',
              style: TextStyle(
                color: _isDragging ? Colors.blue : Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 選択ファイル情報カード
  Widget _buildSelectedFileCard() {
    return Card(
      color: Colors.green[50],
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Selected File:',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text('Name: $_selectedFileName'),
            if (_selectedFileSize != null)
              Text(
                'Size: ${(_selectedFileSize! / 1024).toStringAsFixed(1)} KB',
              ),
          ],
        ),
      ),
    );
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
              'Coordinate Reference System (CRS)',
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
                      _selectedCrs?.displayString ?? 'WGS 84 (EPSG:4326) - Default',
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
                      tooltip: 'Reset to WGS84',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            
            // CRS検索
            TextField(
              decoration: const InputDecoration(
                hintText: 'Search CRS (e.g., 6677, Tokyo, IX)',
                prefixIcon: Icon(Icons.search, size: 20),
                isDense: true,
                border: OutlineInputBorder(),
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
                      'Coordinates will be transformed from WGS84 to ${_selectedCrs!.code}',
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

  /// インポートオプション
  Widget _buildImportOptions() {
    return Card(
      color: Colors.grey[50],
      child: ExpansionTile(
        leading: const Icon(Icons.settings),
        title: const Text('Import Options'),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('Max Features: '),
                    Expanded(
                      child: Slider(
                        value: _maxFeaturesToImport.toDouble(),
                        min: 10,
                        max: 100,
                        divisions: 9,
                        label: _maxFeaturesToImport.toString(),
                        onChanged:
                            (value) => setState(
                              () => _maxFeaturesToImport = value.toInt(),
                            ),
                      ),
                    ),
                    Text('$_maxFeaturesToImport'),
                  ],
                ),
              ],
            ),
          ),
        ],
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
              isImportMode ? 'Import Progress' : 'Export Progress',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progressValue),
            const SizedBox(height: 8),
            Text(_progressMessage),
            Text('${(_progressValue * 100).toInt()}% completed'),
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
                Text(_lastResult?.success == true ? 'Success' : 'Error'),
              ],
            ),
            const SizedBox(height: 4),
            Text(_statusMessage!),
            if (_lastResult?.metadata != null) ...[
              const SizedBox(height: 8),
              Text('Details:', style: Theme.of(context).textTheme.labelSmall),
              ...(_lastResult!.metadata!.entries.map(
                (e) => Text('• ${e.key}: ${e.value}'),
              )),
            ],
          ],
        ),
      ),
    );
  }

  // 以下、処理メソッド（既存のコードから移植・調整）
  Future<void> _handleFileSelection() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions:
            _importExportService
                .getSupportedImportExtensions()
                .map((ext) => ext.substring(1))
                .toList(),
        allowMultiple: false,
      );

      if (result.isEmpty) return;

      final file = result.first;
      // file_picker 12 の path は file:// のときだけ。Android の content:// は一時ファイルに写して同じ経路に載せる
      var path = file.path;
      if (path == null) {
        final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}${file.name}');
        await tmp.writeAsBytes(await file.readAsBytes());
        path = tmp.path;
      }
      // PlatformFile はサイズを持たないので実ファイルから
      final size = await File(path).length();

      setState(() {
        _selectedFilePath = path;
        _selectedFileName = file.name;
        _selectedFileSize = size;
        _statusMessage = null;
        _lastResult = null;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'File selection failed: $e';
      });
    }
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _isDragging = false);

    if (details.files.isEmpty) return;

    final droppedFile = details.files.first;
    final filePath = droppedFile.path;

    try {
      final fileStat = await File(filePath).stat();
      setState(() {
        _selectedFilePath = filePath;
        _selectedFileName = filePath.split('/').last.split('\\').last;
        _selectedFileSize = fileStat.size;
        _statusMessage = null;
        _lastResult = null;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Failed to process dropped file: $e';
      });
    }
  }

  Future<void> _handleImport() async {
    if (_selectedFilePath == null || widget.targetGeoPackage == null) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = null;
      _progressValue = 0.0;
      _progressMessage = 'Starting import...';
    });

    try {
      _updateProgress(0.2, 'Reading file...');

      final importResult = await _importExportService
          .importFileFromCurrentLayer(
            _selectedFilePath!,
            widget.targetGeoPackage,
          );

      _updateProgress(1.0, 'Import completed!');

      setState(() {
        _isProcessing = false;
        _lastResult = importResult;
        _statusMessage =
            importResult.success
                ? 'Import completed successfully!'
                : importResult.errorMessage ?? 'Import failed';
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Import failed: $e';
        _lastResult = ImportExportResult.error(e.toString());
      });
    }
  }

  Future<void> _handleExport() async {
    if (widget.exportLayer == null) return;

    // file_picker 12 の saveFile は中身（bytes）を先に渡す作り（Android の SAF は「保存先を選んでから書く」ができない）。
    // 一時フォルダに書き出してから保存ダイアログへ。Shapefile は .shp/.shx/.dbf/.prj の組なので zip にまとめる
    Directory? tmpDir;
    try {
      setState(() {
        _isProcessing = true;
        _statusMessage = null;
        _progressValue = 0.0;
        _progressMessage = 'Starting export...';
      });

      _updateProgress(0.3, 'Analyzing layer...');

      // エクスポートオプションを作成
      final exportOptions = ExportOptions(
        targetCrs: _selectedCrs,
        convertToPointCloud: _exportAsPointCloud,
        includeRowNumber: _includeRowNumber,
      );

      final ext = _exportFormat.extension.replaceFirst('.', '');
      final baseName = widget.exportLayer!.name;
      tmpDir = await Directory.systemTemp.createTemp('kokage_export_');
      final tmpPath = '${tmpDir.path}${Platform.pathSeparator}$baseName.$ext';

      final exportResult = await _importExportService.exportLayer(
        widget.exportLayer!,
        tmpPath,
        format: _exportFormat,
        options: exportOptions,
      );
      if (!exportResult.success) {
        setState(() {
          _isProcessing = false;
          _lastResult = exportResult;
          _statusMessage = exportResult.errorMessage ?? 'Export failed';
        });
        return;
      }

      _updateProgress(0.8, 'Saving...');
      final isShapefile = _exportFormat == FileFormat.shapefile;
      final bytes = isShapefile ? _zipDirectory(tmpDir) : await File(tmpPath).readAsBytes();
      final saveExt = isShapefile ? 'zip' : ext;
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Export Layer',
        fileName: '$baseName.$saveExt',
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: [saveExt],
      );
      if (saved == null) {
        setState(() {
          _isProcessing = false;
          _statusMessage = 'Export cancelled';
        });
        return;
      }

      _updateProgress(1.0, 'Export completed!');

      // 成功時は選択したCRSを保持
      if (exportResult.success) {
        _lastUsedCrs = _selectedCrs;
      }

      setState(() {
        _isProcessing = false;
        _lastResult = exportResult;
        _statusMessage =
            exportResult.success
                ? 'Export completed successfully!'
                : exportResult.errorMessage ?? 'Export failed';
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Export failed: $e';
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
