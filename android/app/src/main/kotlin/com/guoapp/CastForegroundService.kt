package com.guoapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

class CastForegroundService : Service() {
    private var mediaSession: MediaSession? = null
    private var controlReceiver: BroadcastReceiver? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var currentDevice = ""
    private var currentTitle = ""
    private var currentPlaying = false
    private var currentPaused = false
    private var currentHasPrevious = false
    private var currentHasNext = false

    override fun onCreate() {
        super.onCreate()
        registerControlReceiver()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent != null) {
            currentDevice = intent.getStringExtra(EXTRA_DEVICE) ?: currentDevice
            currentTitle = intent.getStringExtra(EXTRA_TITLE) ?: currentTitle
            currentPlaying = intent.getBooleanExtra(EXTRA_PLAYING, currentPlaying)
            currentPaused = intent.getBooleanExtra(EXTRA_PAUSED, currentPaused)
            currentHasPrevious = intent.getBooleanExtra(EXTRA_HAS_PREVIOUS, currentHasPrevious)
            currentHasNext = intent.getBooleanExtra(EXTRA_HAS_NEXT, currentHasNext)
        }
        acquireLocks()
        registerControlReceiver()
        val session = ensureSession()
        updateSession(session)
        val notification = buildNotification(session)
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        cleanup()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        cleanup()
        super.onDestroy()
    }

    private fun acquireLocks() {
        if (wakeLock?.isHeld != true) {
            val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
            wakeLock = power?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "$packageName:cast_service_cpu"
            )?.apply {
                setReferenceCounted(false)
                runCatching { acquire(12 * 60 * 60 * 1000L) }
            }
        }
        if (wifiLock?.isHeld != true) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi?.createWifiLock(mode, "$packageName:cast_service_wifi")?.apply {
                setReferenceCounted(false)
                runCatching { acquire() }
            }
        }
    }

    private fun ensureSession(): MediaSession {
        mediaSession?.let { return it }
        return MediaSession(this, "DuanjuCastSession").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = dispatch("play")
                override fun onPause() = dispatch("pause")
                override fun onSkipToPrevious() = dispatch("previous")
                override fun onSkipToNext() = dispatch("next")
                override fun onStop() = dispatch("stop")
            })
            isActive = true
            mediaSession = this
        }
    }

    private fun updateSession(session: MediaSession) {
        val subtitle = if (currentDevice.isEmpty()) "局域网投屏中" else "投屏到 $currentDevice"
        val title = currentTitle.ifEmpty { "正在投屏" }
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, subtitle)
                .build()
        )
        var actions = PlaybackState.ACTION_PLAY or
            PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_STOP
        if (currentHasPrevious) actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        if (currentHasNext) actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        val state = when {
            currentPlaying -> PlaybackState.STATE_PLAYING
            currentPaused -> PlaybackState.STATE_PAUSED
            else -> PlaybackState.STATE_BUFFERING
        }
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(state, PlaybackState.PLAYBACK_POSITION_UNKNOWN, if (currentPlaying) 1f else 0f)
                .build()
        )
    }

    private fun buildNotification(session: MediaSession): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            val channel = NotificationChannel(
                CHANNEL_ID,
                "投屏播放",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持锁屏期间投屏流传输稳定"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            manager?.createNotificationChannel(channel)
        }
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPending = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val title = currentTitle.ifEmpty { "正在投屏" }
        val subtitle = if (currentDevice.isEmpty()) "保持后台视频流传输" else "正在投屏到 $currentDevice"
        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setContentIntent(contentPending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(controlAction(1, "previous", R.drawable.ic_pip_previous, "上一集"))
            .addAction(
                if (currentPlaying) {
                    controlAction(2, "toggle", R.drawable.ic_pip_pause, "暂停")
                } else {
                    controlAction(2, "toggle", R.drawable.ic_pip_play, "播放")
                }
            )
            .addAction(controlAction(3, "next", R.drawable.ic_pip_next, "下一集"))
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
        return builder.build()
    }

    private fun registerControlReceiver() {
        if (controlReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val action = intent.getStringExtra(EXTRA_CONTROL_ACTION) ?: return
                dispatch(action)
                if (action == "stop") stopSelf()
            }
        }
        val filter = IntentFilter(ACTION_CONTROL)
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(receiver, filter)
            }
            controlReceiver = receiver
        }
    }

    private fun controlAction(requestCode: Int, action: String, icon: Int, label: String): Notification.Action {
        val intent = Intent(ACTION_CONTROL).setPackage(packageName).putExtra(EXTRA_CONTROL_ACTION, action)
        val pending = PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Action.Builder(Icon.createWithResource(this, icon), label, pending).build()
    }

    private fun dispatch(action: String) {
        mainHandler.post { onAction?.invoke(action) }
    }

    private fun cleanup() {
        controlReceiver?.let { receiver ->
            runCatching { unregisterReceiver(receiver) }
        }
        controlReceiver = null
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        runCatching {
            mediaSession?.isActive = false
            mediaSession?.release()
        }
        mediaSession = null
        runCatching { if (wakeLock?.isHeld == true) wakeLock?.release() }
        wakeLock = null
        runCatching { if (wifiLock?.isHeld == true) wifiLock?.release() }
        wifiLock = null
    }

    companion object {
        private const val CHANNEL_ID = "zhenguojian_cast"
        private const val NOTIFICATION_ID = 2407
        private const val ACTION_UPDATE = "com.guoapp.cast.UPDATE"
        private const val ACTION_CONTROL = "com.guoapp.cast.CONTROL"
        private const val EXTRA_CONTROL_ACTION = "controlAction"
        private const val EXTRA_DEVICE = "device"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_PLAYING = "playing"
        private const val EXTRA_PAUSED = "paused"
        private const val EXTRA_HAS_PREVIOUS = "hasPrevious"
        private const val EXTRA_HAS_NEXT = "hasNext"
        private val mainHandler = Handler(Looper.getMainLooper())
        var onAction: ((String) -> Unit)? = null

        fun startOrUpdate(
            context: Context,
            deviceName: String,
            title: String,
            playing: Boolean,
            paused: Boolean,
            hasPrevious: Boolean,
            hasNext: Boolean
        ) {
            val intent = Intent(context, CastForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_DEVICE, deviceName)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_PLAYING, playing)
                putExtra(EXTRA_PAUSED, paused)
                putExtra(EXTRA_HAS_PREVIOUS, hasPrevious)
                putExtra(EXTRA_HAS_NEXT, hasNext)
            }
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }
        }

        fun stop(context: Context) {
            runCatching { context.stopService(Intent(context, CastForegroundService::class.java)) }
        }
    }
}
