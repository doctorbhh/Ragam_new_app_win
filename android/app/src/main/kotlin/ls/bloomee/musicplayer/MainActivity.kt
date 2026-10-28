package ls.bloomee.musicplayer

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    companion object {
        const val CHANNEL = "ls.bloomee.musicplayer/widget"
        var methodChannel: MethodChannel? = null

        fun sendActionToFlutter(action: String, args: Map<String, Any>? = null) {
            methodChannel?.invokeMethod(action, args)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val artworkUri = call.argument<String>("artworkUri") ?: ""
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val positionMs = (call.argument<Number>("positionMs"))?.toLong() ?: 0L
                    val durationMs = (call.argument<Number>("durationMs"))?.toLong() ?: 0L

                    RagamPlayerWidgetProvider.updateWidgetData(
                        context = this,
                        title = title,
                        artist = artist,
                        artworkUri = artworkUri,
                        isPlaying = isPlaying,
                        positionMs = positionMs,
                        durationMs = durationMs
                    )
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        methodChannel = null
        super.onDestroy()
    }
}
