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
 * Keeps the process alive while the pendant is connected.
 *
 * Without this Android freezes the app about eleven seconds after it leaves the
 * foreground, with a live BLE connection open and audio mid-stream. Measured,
 * not assumed: "ActivityManager: freezing com.danielalt.omi_capture" arrives
 * while packets are still flowing.
 *
 * The type is connectedDevice, not microphone. The audio arrives over the radio
 * from a separate device; the phone's own microphone is never opened. Declaring
 * microphone here would be both untrue and would drag in restrictions we do not
 * want. Since Android 14 the runtime enforces that the declared type matches the
 * permission held, so this pairing is not cosmetic.
 *
 * No wake lock is taken. The connection itself does not need the CPU held awake,
 * and Play flags apps that average more than two hours of wake lock with the
 * screen off. If processing later needs one, it should be held around that work
 * only, never for the life of the connection.
 */
class CaptureService : android.app.Service() {

    companion object {
        private const val CHANNEL_ID = "capture"
        private const val NOTIFICATION_ID = 1

        const val ACTION_START = "com.danielalt.omi_capture.START"
        const val ACTION_STOP = "com.danielalt.omi_capture.STOP"

        fun start(context: Context) {
            val intent = Intent(context, CaptureService::class.java).apply {
                action = ACTION_START
            }
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, CaptureService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                createChannel()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(
                        NOTIFICATION_ID,
                        buildNotification(),
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, buildNotification())
                }
            }
        }
        // START_STICKY: if Android kills us under memory pressure we want to come
        // back. The Dart side re-scans on restart rather than assuming the old
        // connection survived.
        return START_STICKY
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Capture",
            // LOW: no sound, no heads-up. This notification sits there for hours.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while the pendant is connected"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val tap = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Capturing")
            .setContentText("Connected to the pendant")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(tap)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
