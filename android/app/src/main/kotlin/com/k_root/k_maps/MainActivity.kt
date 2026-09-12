package com.k_root.k_maps

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.k_root.k_maps/media_copy"
        private const val LAUNCH_CHANNEL = "com.k_root.k_maps/launch"
    }

    private var launchChannel: MethodChannel? = null

    // 起動中に `am start --es route "/map?..."` が来たとき（singleTop）。Dart 側の LaunchRequest に流す
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val route = intent.getStringExtra("route") ?: return
        Log.d("MainActivity", "onNewIntent route=$route")
        launchChannel?.invokeMethod("route", route)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Android 8.0以降で通知チャンネルを作成
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = "k_maps_foreground_channel"
            val channelName = "こかげマップ フォアグラウンドサービス"
            val channelDescription = "こかげマップのフォアグラウンドサービス通知"
            val importance = NotificationManager.IMPORTANCE_LOW
            
            val channel = NotificationChannel(channelId, channelName, importance).apply {
                description = channelDescription
                setShowBadge(false) // バッジ表示を無効化
            }
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager?.createNotificationChannel(channel)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        launchChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LAUNCH_CHANNEL)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "copyOriginal" -> {
                        val uriStr = call.argument<String>("uri")
                        val destPath = call.argument<String>("destPath")
                        if (uriStr == null || destPath == null) {
                            result.error("INVALID_ARGS", "uri and destPath are required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            // 戻り値は "original" / "maybe_redacted" / null（失敗）
                            result.success(copyOriginalFile(uriStr, destPath))
                        } catch (e: Exception) {
                            result.error("COPY_ERROR", e.message, null)
                        }
                    }
                    // Photo Picker は表示名としてメディアID（例: "20.jpg"）を返すので、
                    // MediaStore から元のファイル名を引き直す口を用意する
                    "resolveDisplayName" -> {
                        val uriStr = call.argument<String>("uri")
                        if (uriStr == null) {
                            result.error("INVALID_ARGS", "uri is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(resolveDisplayName(Uri.parse(uriStr)))
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * content URI から元ファイルをバイトコピーする。
     *
     * 戻り値はコピーしたバイトの素性:
     * - "original"       位置情報を含む原本（実パス直読み、または setRequireOriginal の原本ストリーム）
     * - "maybe_redacted" 権限が足りず、GPS をゼロ埋めした複製を掴んだ可能性がある
     * - null             コピー失敗
     *
     * 1. 全ファイルアクセス（MANAGE_EXTERNAL_STORAGE）あり → 実パス直読み。FUSE のリダクション対象外
     * 2. ACCESS_MEDIA_LOCATION あり → MediaStore.setRequireOriginal() で原本ストリームを開く
     *    （READ_MEDIA_IMAGES / READ_EXTERNAL_STORAGE も要る。無ければ SecurityException → 次へ）
     * 3. どちらも無い → 実パスが読めればそれ、無ければ ContentResolver のストリーム。
     *    ⚠ 全ファイルアクセス無しの実パス読みは「読める」が FUSE でリダクションされる。
     *    以前はここを成功扱いしていたため、権限を許可し忘れた端末で
     *    位置情報が黙って消えていた。
     */
    private fun copyOriginalFile(uriStr: String, destPath: String): String? {
        val uri = Uri.parse(uriStr)
        val dest = File(destPath)
        val realPath = resolveRealPath(uri)
        val hasAllFiles = hasAllFilesAccess()
        val hasMediaLocation = hasAccessMediaLocation()
        Log.d(
            "MediaCopy",
            "copyOriginal uri=$uri realPath=$realPath allFiles=$hasAllFiles mediaLocation=$hasMediaLocation",
        )

        // 1. 全ファイルアクセス + 実パス → 原本
        if (hasAllFiles && realPath != null) {
            if (copyFromPath(realPath, dest)) return "original"
        }

        // 2. ACCESS_MEDIA_LOCATION + MediaStore の実体 URI → 原本ストリーム
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && hasMediaLocation) {
            val mediaUri = mediaUriOf(uri)
            if (mediaUri != null) {
                try {
                    val original = MediaStore.setRequireOriginal(mediaUri)
                    contentResolver.openInputStream(original)?.use { input ->
                        dest.outputStream().use { output -> input.copyTo(output) }
                        Log.d("MediaCopy", "copied via setRequireOriginal")
                        return "original"
                    }
                } catch (e: Exception) {
                    Log.d("MediaCopy", "setRequireOriginal failed: $e")
                }
            }
        }

        // 3. リダクションされうる経路
        if (realPath != null && copyFromPath(realPath, dest)) return "maybe_redacted"
        contentResolver.openInputStream(uri)?.use { input ->
            dest.outputStream().use { output -> input.copyTo(output) }
            return "maybe_redacted"
        }

        return null
    }

    /** 実パスからコピーする。読めなければ false */
    private fun copyFromPath(path: String, dest: File): Boolean {
        val src = File(path)
        if (src.exists() && src.canRead()) {
            src.copyTo(dest, overwrite = true)
            return true
        }
        Log.d("MediaCopy", "realPath not readable: exists=${src.exists()}")
        return false
    }

    /** 全ファイルアクセス（Android 11+ の MANAGE_EXTERNAL_STORAGE）を持っているか */
    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()

    /** ACCESS_MEDIA_LOCATION（Android 10+）を持っているか */
    private fun hasAccessMediaLocation(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** ピッカー系 URI を MediaStore.Images の実体 URI に。もとから MediaStore の URI ならそのまま */
    private fun mediaUriOf(uri: Uri): Uri? {
        extractMediaId(uri)?.let { id ->
            return ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        }
        return if (uri.authority == MediaStore.AUTHORITY) uri else null
    }

    /**
     * content:// URI から実ファイルシステムのパスを解決する。
     * MANAGE_EXTERNAL_STORAGE 権限があるため _data カラムの実パスに直接アクセスできる。
     *
     * ⚠ システム Photo Picker（GET_CONTENT が photopicker にルーティングされる。
     * Pixel の新しい Android で実測）の URI は、そのまま query しても _data が
     * 取れない上、openInputStream は **GPS EXIF をゼロ埋めした複製**を返す
     * （ACCESS_MEDIA_LOCATION も無視される仕様）。
     * そこで URI からメディアIDを取り出し、MediaStore.Images の実体で _data を
     * 引き直す。実パスの直接読みは FUSE のリダクション対象外なので EXIF が丸ごと残る
     * （2026-08-28 に Pixel 9 実機で検証済み）。
     */
    private fun resolveRealPath(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path

        // 1) ピッカー系URIはメディアIDで MediaStore の実体を引き直す。
        //    ⚠ ピッカーURIをそのまま query すると _data が「成功」するが、
        //    返るのは `/sdcard/.transforms/synthetic/...` という合成パスで、
        //    読めるのは**リダクション済み（GPSゼロ埋め）バイト**（Pixel 9 実測）。
        extractMediaId(uri)?.let { id ->
            val mediaUri =
                ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
            queryDataColumn(mediaUri)?.let { if (isRealPath(it)) return it }
        }

        // 2) 従来の MediaStore URI はそのまま _data を引く（synthetic は弾く）
        return queryDataColumn(uri)?.takeIf { isRealPath(it) }
    }

    /** FUSE の合成パス（リダクション済み複製）でないか */
    private fun isRealPath(path: String) = !path.contains("/.transforms/")

    /** MediaStore の実体から元の表示名（DISPLAY_NAME）を引く。取れなければ null。 */
    private fun resolveDisplayName(uri: Uri): String? {
        val id = extractMediaId(uri) ?: return null
        val mediaUri =
            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        return try {
            val projection = arrayOf(MediaStore.Images.Media.DISPLAY_NAME)
            contentResolver.query(mediaUri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getString(0)?.takeIf { it.isNotEmpty() }
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }

    /** URI の _data カラム（実パス）を query する。取れなければ null。 */
    private fun queryDataColumn(uri: Uri): String? {
        return try {
            val projection = arrayOf(MediaStore.Images.Media.DATA)
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(MediaStore.Images.Media.DATA)
                    if (idx >= 0) cursor.getString(idx).takeIf { it.isNotEmpty() } else null
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * ピッカー系 URI から MediaStore のメディアIDを取り出す。
     *
     * - Photo Picker: `content://media/picker/0/<authority>/media/<id>`
     *   （クラウド専用アイテムは id が数値でない → null＝フォールバックへ）
     * - DocumentsUI:  `content://com.android.providers.media.documents/document/image:<id>`
     */
    private fun extractMediaId(uri: Uri): Long? {
        val segments = uri.pathSegments
        if (segments.size >= 2 && segments[segments.size - 2] == "media") {
            return segments.last().toLongOrNull()
        }
        if (uri.authority == "com.android.providers.media.documents") {
            return try {
                DocumentsContract.getDocumentId(uri).substringAfter(':').toLongOrNull()
            } catch (_: Exception) {
                null
            }
        }
        return null
    }
}
