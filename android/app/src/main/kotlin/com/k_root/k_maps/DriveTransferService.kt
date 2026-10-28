package com.k_root.k_maps

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Google Drive 共有フォルダのダウンロード・同期中にプロセス生存と進捗通知を担う
 * `dataSync` フォアグラウンドサービス。
 *
 * - 進行中は Ongoing 進捗バー付き通知を表示し、PARTIAL_WAKE_LOCK（最大30分タイムアウト）を保持。
 * - 完了時はフォアグラウンド状態を解除（STOP_FOREGROUND_DETACH / STOP_FOREGROUND_REMOVE）し、
 *   同じ通知IDを完了メッセージ（AutoCancel, 進捗バーなし）に差し替えてから停止する。
 */
class DriveTransferService : Service() {

    companion object {
        const val CHANNEL_ID = "k_maps_sync_channel"
        private const val CHANNEL_NAME = "こかげマップ データ同期"
        private const val CHANNEL_DESC = "Google Drive 共有フォルダのダウンロード・同期状況"

        private const val ACTION_PROGRESS = "com.k_root.k_maps.action.SYNC_PROGRESS"
        private const val ACTION_COMPLETE = "com.k_root.k_maps.action.SYNC_COMPLETE"
        private const val ACTION_STOP_IDLE = "com.k_root.k_maps.action.SYNC_STOP_IDLE"

        private const val EXTRA_ID = "id"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_BODY = "body"
        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_MAX = "max"
        private const val EXTRA_INDETERMINATE = "indeterminate"
        private const val EXTRA_IS_ERROR = "isError"
        private const val EXTRA_STOP_SERVICE = "stopService"

        private const val WAKE_LOCK_TIMEOUT_MS = 30L * 60L * 1000L

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = context.getSystemService(NotificationManager::class.java) ?: return
                if (nm.getNotificationChannel(CHANNEL_ID) != null) return
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = CHANNEL_DESC
                    setShowBadge(false)
                }
                nm.createNotificationChannel(channel)
            }
        }

        fun showProgress(
            context: Context,
            id: Int,
            title: String,
            body: String,
            progress: Int,
            max: Int,
            indeterminate: Boolean,
        ) {
            ensureChannel(context)
            val intent = Intent(context, DriveTransferService::class.java).apply {
                action = ACTION_PROGRESS
                putExtra(EXTRA_ID, id)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_BODY, body)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_MAX, max)
                putExtra(EXTRA_INDETERMINATE, indeterminate)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // バックグラウンド制約等でサービス起動が拒否された場合も NotificationManager へ直接出す
                Log.w("DriveTransferService", "startForegroundService fallback: $e")
                val nm = context.getSystemService(NotificationManager::class.java)
                nm?.notify(
                    id,
                    buildProgressNotification(context, title, body, progress, max, indeterminate),
                )
            }
        }

        fun showComplete(
            context: Context,
            id: Int,
            title: String,
            body: String,
            isError: Boolean,
            stopService: Boolean,
        ) {
            ensureChannel(context)
            val nm = context.getSystemService(NotificationManager::class.java)
            if (stopService) {
                try {
                    val stopIntent = Intent(context, DriveTransferService::class.java).apply {
                        action = ACTION_COMPLETE
                        putExtra(EXTRA_ID, id)
                        putExtra(EXTRA_TITLE, title)
                        putExtra(EXTRA_BODY, body)
                        putExtra(EXTRA_IS_ERROR, isError)
                        putExtra(EXTRA_STOP_SERVICE, true)
                    }
                    context.startService(stopIntent)
                } catch (_: Exception) {
                    context.stopService(Intent(context, DriveTransferService::class.java))
                }
            }
            // 完了通知を同じ ID で上書き（Ongoing解除・進捗バー消去・タップで消える）
            nm?.notify(id, buildCompleteNotification(context, title, body, isError))
        }

        fun stopIfIdle(context: Context) {
            try {
                context.stopService(Intent(context, DriveTransferService::class.java))
            } catch (_: Exception) {}
        }

        private fun contentPendingIntent(context: Context): PendingIntent {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            return PendingIntent.getActivity(context, 0, launchIntent, flags)
        }

        internal fun buildProgressNotification(
            context: Context,
            title: String,
            body: String,
            progress: Int,
            max: Int,
            indeterminate: Boolean,
        ): Notification {
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setContentText(body)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setProgress(max, progress, indeterminate)
                .setContentIntent(contentPendingIntent(context))
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()
        }

        internal fun buildCompleteNotification(
            context: Context,
            title: String,
            body: String,
            isError: Boolean,
        ): Notification {
            val icon = if (isError) {
                android.R.drawable.stat_notify_error
            } else {
                android.R.drawable.stat_sys_download_done
            }
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(icon)
                .setContentTitle(title)
                .setContentText(body)
                .setOngoing(false)
                .setAutoCancel(true)
                .setProgress(0, 0, false)
                .setContentIntent(contentPendingIntent(context))
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var currentForegroundId: Int = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PROGRESS -> {
                val id = intent.getIntExtra(EXTRA_ID, 2000)
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "ダウンロード中"
                val body = intent.getStringExtra(EXTRA_BODY) ?: ""
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                val max = intent.getIntExtra(EXTRA_MAX, 100)
                val indeterminate = intent.getBooleanExtra(EXTRA_INDETERMINATE, true)

                acquireWakeLock()
                val notification = buildProgressNotification(
                    this,
                    title,
                    body,
                    progress,
                    max,
                    indeterminate,
                )
                try {
                    if (currentForegroundId == 0) {
                        currentForegroundId = id
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            startForeground(
                                id,
                                notification,
                                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                            )
                        } else {
                            startForeground(id, notification)
                        }
                    } else {
                        val nm = getSystemService(NotificationManager::class.java)
                        nm?.notify(id, notification)
                    }
                } catch (e: Exception) {
                    Log.w("DriveTransferService", "startForeground failed: $e")
                }
            }
            ACTION_COMPLETE -> {
                val id = intent.getIntExtra(EXTRA_ID, 2000)
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "ダウンロード完了"
                val body = intent.getStringExtra(EXTRA_BODY) ?: ""
                val isError = intent.getBooleanExtra(EXTRA_IS_ERROR, false)
                val stopService = intent.getBooleanExtra(EXTRA_STOP_SERVICE, true)

                if (stopService) {
                    releaseWakeLock()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        stopForeground(STOP_FOREGROUND_DETACH)
                    } else {
                        @Suppress("DEPRECATION")
                        stopForeground(false)
                    }
                    currentForegroundId = 0
                }
                val nm = getSystemService(NotificationManager::class.java)
                nm?.notify(id, buildCompleteNotification(this, title, body, isError))
                if (stopService) {
                    stopSelf()
                }
            }
            ACTION_STOP_IDLE -> {
                releaseWakeLock()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                currentForegroundId = 0
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w("DriveTransferService", "ForegroundService timeout reached, stopping gracefully")
        releaseWakeLock()
        stopSelf()
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = getSystemService(PowerManager::class.java) ?: return
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "kokage_map:drive_transfer_wakelock",
            ).apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_TIMEOUT_MS)
            }
        } catch (e: Exception) {
            Log.w("DriveTransferService", "Failed to acquire WakeLock: $e")
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {}
        wakeLock = null
    }
}
