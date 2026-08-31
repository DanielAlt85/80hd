package com.danielalt.omi_capture

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Keeps the process alive while the pendant is connected, and tells the truth
 * about what it is doing.
 *
 * Without this Android freezes the app about eleven seconds after it leaves the
 * foreground, with a live BLE connection open and audio mid-stream. Measured,
 * not assumed: "ActivityManager: freezing com.danielalt.omi_capture" arrives
 * while packets are still flowing.
 *
 * The type is connectedDevice, not microphone. The audio arrives over the radio
 * from a separate device; the phone's own microphone is never opened. Declaring
 * microphone here would be untrue and would drag in restrictions we do not want.
 * Since Android 14 the runtime enforces that the declared type matches the
 * permission held, so this pairing is not cosmetic.
 *
 * No wake lock is taken. The connection does not need the CPU held awake, and
 * Play flags apps averaging more than two hours of wake lock with the screen
 * off. If processing later needs one, hold it around that work only, never for
 * the life of the connection.
 */
class CaptureService : android.app.Service() {

    companion object {
        private const val CHANNEL_ID = "capture"
        private const val ALERT_CHANNEL_ID = "capture_alerts"
        private const val NOTIFICATION_ID = 1
        private const val ALERT_ID = 2

        const val ACTION_START = "com.danielalt.omi_capture.START"
        const val ACTION_STOP = "com.danielalt.omi_capture.STOP"
        const val ACTION_UPDATE = "com.danielalt.omi_capture.UPDATE"
        const val ACTION_ALERT = "com.danielalt.omi_capture.ALERT"

        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"

        fun start(context: Context) {
            context.startForegroundService(
                Intent(context, CaptureService::class.java).setAction(ACTION_START)
            )
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, CaptureService::class.java).setAction(ACTION_STOP)
            )
        }

        /** Rewrite the ongoing notification so it reflects the real state. */
        fun update(context: Context, title: String, body: String) {
            context.startService(
                Intent(context, CaptureService::class.java)
                    .setAction(ACTION_UPDATE)
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_BODY, body)
            )
        }

        /**
         * A separate, dismissible, higher-importance notification. The ongoing
         * one is deliberately silent because it sits there for hours; something
         * actually going wrong has to be able to interrupt.
         */
        fun alert(context: Context, title: String, body: String) {
            context.startService(
                Intent(context, CaptureService::class.java)
                    .setAction(ACTION_ALERT)
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_BODY, body)
            )
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannels()
        val manager = getSystemService(NotificationManager::class.java)

        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_UPDATE -> {
                manager.notify(
                    NOTIFICATION_ID,
                    ongoing(
                        intent.getStringExtra(EXTRA_TITLE) ?: "Capturing",
                        intent.getStringExtra(EXTRA_BODY) ?: "",
                    ),
                )
            }

            ACTION_ALERT -> {
                manager.notify(
                    ALERT_ID,
                    NotificationCompat.Builder(this, ALERT_CHANNEL_ID)
                        .setContentTitle(intent.getStringExtra(EXTRA_TITLE) ?: "Capture problem")
                        .setContentText(intent.getStringExtra(EXTRA_BODY) ?: "")
                        .setStyle(
                            NotificationCompat.BigTextStyle()
                                .bigText(intent.getStringExtra(EXTRA_BODY) ?: "")
                        )
                        .setSmallIcon(android.R.drawable.stat_notify_error)
                        .setContentIntent(tapIntent())
                        .setAutoCancel(true)
                        .setPriority(NotificationCompat.PRIORITY_HIGH)
                        .build(),
                )
            }

            else -> {
                val n = ongoing("Capturing", "Starting up")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(
                        NOTIFICATION_ID, n,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, n)
                }
            }
        }

        // START_STICKY: if Android kills us under memory pressure we want to
        // come back. The Dart side rescans on restart rather than assuming the
        // old connection survived.
        return START_STICKY
    }

    private fun createChannels() {
        val manager = getSystemService(NotificationManager::class.java)

        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Capture",
                // LOW: no sound, no heads-up. This one sits there for hours.
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while capture is running"
                setShowBadge(false)
            }
        )

        manager.createNotificationChannel(
            NotificationChannel(
                ALERT_CHANNEL_ID,
                "Capture problems",
                // DEFAULT so it can make a sound. Silently failing to record is
                // the worst outcome this app has, so it gets to interrupt.
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "The pendant stopped, or audio is not reaching the host"
            }
        )
    }

    private fun tapIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0,
        Intent(this, MainActivity::class.java),
        PendingIntent.FLAG_IMMUTABLE,
    )

    private fun ongoing(title: String, body: String): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(tapIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
}
