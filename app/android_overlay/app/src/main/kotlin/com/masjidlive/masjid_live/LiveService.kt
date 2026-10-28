package com.masjidlive.masjid_live

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

const val CH_SERVICE = "live_service"
const val CH_ALERTS = "live"

/** Notification channels: one quiet channel for "playing/broadcasting", one loud channel for LIVE alerts. */
fun createChannels(ctx: Context) {
    if (Build.VERSION.SDK_INT < 26) return
    val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
    nm.createNotificationChannel(
        NotificationChannel(CH_SERVICE, "Live audio running", NotificationManager.IMPORTANCE_LOW)
    )
    nm.createNotificationChannel(
        NotificationChannel(CH_ALERTS, "Tafseer is LIVE alerts", NotificationManager.IMPORTANCE_HIGH)
    )
}

/**
 * Keeps the app alive while the screen is locked:
 *  - lecturer: type "microphone" (mic keeps recording)
 *  - listener: type "mediaPlayback" (audio keeps playing)
 */
class LiveService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannels(this)
        val mic = intent?.getBooleanExtra("mic", false) ?: false
        val title = intent?.getStringExtra("title") ?: "Masjid Live"
        val text = intent?.getStringExtra("text") ?: ""

        val open = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pi = PendingIntent.getActivity(
            this, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CH_SERVICE)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(if (mic) android.R.drawable.ic_btn_speak_now else android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setContentIntent(pi)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= 30) {
                val type = if (mic) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                else ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                startForeground(1001, notification, type)
            } else {
                startForeground(1001, notification)
            }
        } catch (e: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }

        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MasjidLive::live").apply {
                setReferenceCounted(false)
                acquire(4 * 60 * 60 * 1000L) // max 4 hours
            }
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // App swiped away from recent apps -> stop cleanly
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }
}
