package ls.bloomee.musicplayer

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.widget.RemoteViews
import java.io.File
import java.net.URL
import java.util.concurrent.Executors

class RagamPlayerWidgetProvider : AppWidgetProvider() {

    companion object {
        const val PREFS_NAME = "RagamPlayerWidgetPrefs"
        const val KEY_TITLE = "title"
        const val KEY_ARTIST = "artist"
        const val KEY_ARTWORK_URI = "artwork_uri"
        const val KEY_IS_PLAYING = "is_playing"
        const val KEY_POSITION_MS = "position_ms"
        const val KEY_DURATION_MS = "duration_ms"

        const val ACTION_PLAY_PAUSE = "ls.bloomee.musicplayer.widget.PLAY_PAUSE"
        const val ACTION_NEXT = "ls.bloomee.musicplayer.widget.NEXT"
        const val ACTION_PREV = "ls.bloomee.musicplayer.widget.PREV"
        const val ACTION_REWIND = "ls.bloomee.musicplayer.widget.REWIND"
        const val ACTION_FORWARD = "ls.bloomee.musicplayer.widget.FORWARD"

        private const val REQUEST_CODE_CONTAINER = 100
        private const val REQUEST_CODE_PLAY_PAUSE = 101
        private const val REQUEST_CODE_PREV = 102
        private const val REQUEST_CODE_NEXT = 103
        private const val REQUEST_CODE_REWIND = 104
        private const val REQUEST_CODE_FORWARD = 105

        private val executor = Executors.newSingleThreadExecutor()
        private val mainHandler = Handler(Looper.getMainLooper())

        // Artwork memory cache to prevent redundant decoding and network calls
        private var cachedArtworkUri: String? = null
        private var cachedArtworkBitmap: Bitmap? = null

        fun updateWidgetData(
            context: Context,
            title: String,
            artist: String,
            artworkUri: String,
            isPlaying: Boolean,
            positionMs: Long,
            durationMs: Long
        ) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().apply {
                putString(KEY_TITLE, title)
                putString(KEY_ARTIST, artist)
                putString(KEY_ARTWORK_URI, artworkUri)
                putBoolean(KEY_IS_PLAYING, isPlaying)
                putLong(KEY_POSITION_MS, positionMs)
                putLong(KEY_DURATION_MS, durationMs)
                apply()
            }
            updateAllWidgets(context)
        }

        fun updateAllWidgets(context: Context) {
            val appWidgetManager = AppWidgetManager.getInstance(context)
            val componentName = ComponentName(context, RagamPlayerWidgetProvider::class.java)
            val appWidgetIds = appWidgetManager.getAppWidgetIds(componentName)
            if (appWidgetIds != null && appWidgetIds.isNotEmpty()) {
                val provider = RagamPlayerWidgetProvider()
                provider.onUpdate(context, appWidgetManager, appWidgetIds)
            }
        }

        private fun formatTime(millis: Long): String {
            if (millis <= 0) return "0:00"
            val totalSeconds = millis / 1000
            val seconds = totalSeconds % 60
            val minutes = (totalSeconds / 60) % 60
            val hours = totalSeconds / 3600
            return if (hours > 0) {
                String.format("%d:%02d:%02d", hours, minutes, seconds)
            } else {
                String.format("%d:%02d", minutes, seconds)
            }
        }

        private fun getRoundedCornerBitmap(bitmap: Bitmap, cornerRadius: Float): Bitmap {
            val output = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(output)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val rect = Rect(0, 0, bitmap.width, bitmap.height)
            val rectF = RectF(rect)

            canvas.drawRoundRect(rectF, cornerRadius, cornerRadius, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            canvas.drawBitmap(bitmap, rect, rect, paint)

            return output
        }

        private fun sendMediaKeyEvent(context: Context, keyCode: Int) {
            try {
                val downIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                    component = ComponentName(context, "com.ryanheise.audioservice.MediaButtonReceiver")
                    putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
                }
                val upIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                    component = ComponentName(context, "com.ryanheise.audioservice.MediaButtonReceiver")
                    putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_UP, keyCode))
                }
                context.sendBroadcast(downIntent)
                context.sendBroadcast(upIntent)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val title = prefs.getString(KEY_TITLE, "Ragam Music") ?: "Ragam Music"
        val artist = prefs.getString(KEY_ARTIST, "No track playing") ?: "No track playing"
        val artworkUri = prefs.getString(KEY_ARTWORK_URI, "") ?: ""
        val isPlaying = prefs.getBoolean(KEY_IS_PLAYING, false)
        val positionMs = prefs.getLong(KEY_POSITION_MS, 0L)
        val durationMs = prefs.getLong(KEY_DURATION_MS, 0L)

        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.ragam_player_widget)

            // Song text metadata
            views.setTextViewText(R.id.tv_title, if (title.isBlank()) "Ragam Music" else title)
            views.setTextViewText(R.id.tv_artist, if (artist.isBlank()) "No track playing" else artist)

            // Play/Pause button state icon
            if (isPlaying) {
                views.setImageViewResource(R.id.btn_play_pause, R.drawable.ic_widget_pause)
            } else {
                views.setImageViewResource(R.id.btn_play_pause, R.drawable.ic_widget_play)
            }

            // Timestamps and progress
            views.setTextViewText(R.id.tv_position, formatTime(positionMs))
            views.setTextViewText(R.id.tv_duration, formatTime(durationMs))

            val progressPercent = if (durationMs > 0) {
                ((positionMs * 1000) / durationMs).toInt().coerceIn(0, 1000)
            } else {
                0
            }
            views.setProgressBar(R.id.pb_progress, 1000, progressPercent, false)

            // Artwork loading
            if (cachedArtworkUri == artworkUri && cachedArtworkBitmap != null) {
                views.setImageViewBitmap(R.id.iv_artwork, cachedArtworkBitmap)
                views.setViewPadding(R.id.iv_artwork, 0, 0, 0, 0)
            } else if (artworkUri.isBlank()) {
                views.setImageViewResource(R.id.iv_artwork, R.drawable.ic_widget_music_note)
                val density = context.resources.displayMetrics.density
                val pad = (8 * density).toInt()
                views.setViewPadding(R.id.iv_artwork, pad, pad, pad, pad)
            }

            // Intent: Open app when clicking widget container
            val openAppIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            if (openAppIntent != null) {
                val pendingOpen = PendingIntent.getActivity(
                    context,
                    REQUEST_CODE_CONTAINER,
                    openAppIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_container, pendingOpen)
                views.setOnClickPendingIntent(R.id.top_layout, pendingOpen)
                views.setOnClickPendingIntent(R.id.iv_artwork, pendingOpen)
            }

            // Intent: Controls
            views.setOnClickPendingIntent(
                R.id.btn_play_pause,
                getPendingSelfIntent(context, ACTION_PLAY_PAUSE, REQUEST_CODE_PLAY_PAUSE)
            )
            views.setOnClickPendingIntent(
                R.id.btn_next,
                getPendingSelfIntent(context, ACTION_NEXT, REQUEST_CODE_NEXT)
            )
            views.setOnClickPendingIntent(
                R.id.btn_prev,
                getPendingSelfIntent(context, ACTION_PREV, REQUEST_CODE_PREV)
            )
            views.setOnClickPendingIntent(
                R.id.btn_rewind,
                getPendingSelfIntent(context, ACTION_REWIND, REQUEST_CODE_REWIND)
            )
            views.setOnClickPendingIntent(
                R.id.btn_forward,
                getPendingSelfIntent(context, ACTION_FORWARD, REQUEST_CODE_FORWARD)
            )

            // Update views immediately
            appWidgetManager.updateAppWidget(widgetId, views)
        }

        // Asynchronously load artwork if uri changed
        if (artworkUri.isNotBlank() && cachedArtworkUri != artworkUri) {
            loadArtworkAsync(context, artworkUri)
        }
    }

    private fun loadArtworkAsync(context: Context, uriString: String) {
        executor.execute {
            try {
                var bitmap: Bitmap? = null
                if (uriString.startsWith("http://") || uriString.startsWith("https://")) {
                    val url = URL(uriString)
                    val connection = url.openConnection()
                    connection.connectTimeout = 4000
                    connection.readTimeout = 4000
                    connection.getInputStream().use { stream ->
                        bitmap = BitmapFactory.decodeStream(stream)
                    }
                } else if (uriString.startsWith("content://")) {
                    context.contentResolver.openInputStream(Uri.parse(uriString))?.use { stream ->
                        bitmap = BitmapFactory.decodeStream(stream)
                    }
                } else {
                    val filePath = if (uriString.startsWith("file://")) {
                        uriString.substring(7)
                    } else {
                        uriString
                    }
                    val file = File(filePath)
                    if (file.exists()) {
                        bitmap = BitmapFactory.decodeFile(file.absolutePath)
                    }
                }

                if (bitmap != null) {
                    val targetSize = (160 * context.resources.displayMetrics.density).toInt()
                    val scaled = Bitmap.createScaledBitmap(bitmap!!, targetSize, targetSize, true)
                    val rounded = getRoundedCornerBitmap(scaled, 28f)

                    cachedArtworkUri = uriString
                    cachedArtworkBitmap = rounded

                    mainHandler.post {
                        val appWidgetManager = AppWidgetManager.getInstance(context)
                        val componentName = ComponentName(context, RagamPlayerWidgetProvider::class.java)
                        val widgetIds = appWidgetManager.getAppWidgetIds(componentName)
                        for (id in widgetIds) {
                            val v = RemoteViews(context.packageName, R.layout.ragam_player_widget)
                            v.setImageViewBitmap(R.id.iv_artwork, rounded)
                            v.setViewPadding(R.id.iv_artwork, 0, 0, 0, 0)
                            appWidgetManager.partiallyUpdateAppWidget(id, v)
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    private fun getPendingSelfIntent(context: Context, action: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, RagamPlayerWidgetProvider::class.java).apply {
            this.action = action
        }
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val action = intent.action ?: return

        when (action) {
            ACTION_PLAY_PAUSE -> {
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val currentPlaying = prefs.getBoolean(KEY_IS_PLAYING, false)
                prefs.edit().putBoolean(KEY_IS_PLAYING, !currentPlaying).apply()
                updateAllWidgets(context)

                if (MainActivity.methodChannel != null) {
                    MainActivity.sendActionToFlutter("playPause")
                } else {
                    sendMediaKeyEvent(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                }
            }
            ACTION_NEXT -> {
                if (MainActivity.methodChannel != null) {
                    MainActivity.sendActionToFlutter("next")
                } else {
                    sendMediaKeyEvent(context, KeyEvent.KEYCODE_MEDIA_NEXT)
                }
            }
            ACTION_PREV -> {
                if (MainActivity.methodChannel != null) {
                    MainActivity.sendActionToFlutter("prev")
                } else {
                    sendMediaKeyEvent(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
                }
            }
            ACTION_REWIND -> {
                if (MainActivity.methodChannel != null) {
                    MainActivity.sendActionToFlutter("rewind", mapOf("seconds" to 10))
                } else {
                    sendMediaKeyEvent(context, KeyEvent.KEYCODE_MEDIA_REWIND)
                }
            }
            ACTION_FORWARD -> {
                if (MainActivity.methodChannel != null) {
                    MainActivity.sendActionToFlutter("forward", mapOf("seconds" to 10))
                } else {
                    sendMediaKeyEvent(context, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD)
                }
            }
        }
    }
}
