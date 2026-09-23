package dev.zcode.remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.IBinder
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * 任务结束推送监听：为每个配置了 ntfyTopic 的实例维持一条 ntfy.sh /json 长连接
 * （前台服务保活），收到消息点亮对应实例红点并发通知。锁屏、进程后台也能收到，
 * 补上「注入脚本检测」只在 App 进程存活时有效的缺口。
 */
class TaskListenService : Service() {

    private val watchers = mutableMapOf<String, Thread>()

    @Volatile private var running = false

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.listen_channel),
                NotificationManager.IMPORTANCE_MIN
            ).apply { description = getString(R.string.listen_channel_desc) }
        )
        running = true
        isRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        syncWatchers()
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        isRunning = false
        synchronized(watchers) {
            watchers.values.forEach { it.interrupt() }
            watchers.clear()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundCompat() {
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.listen_notif_title))
            .setContentText(getString(R.string.listen_notif_text))
            .setSmallIcon(R.drawable.ic_computer)
            .setContentIntent(
                android.app.PendingIntent.getActivity(
                    this, 0,
                    Intent(this, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    android.app.PendingIntent.FLAG_IMMUTABLE
                )
            )
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIF_ID, notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    /** 按当前实例表对齐监听线程：新增 topic 起线程，删掉的不留。 */
    private fun syncWatchers() {
        val wanted = InstanceStore.load(this)
            .mapNotNull { inst -> inst.ntfyTopic?.let { it to inst.id } }
            .toMap()
        synchronized(watchers) {
            watchers.keys.filterNot { wanted.containsKey(it) }
                .toList()
                .forEach { topic ->
                    watchers.remove(topic)?.interrupt()
                }
            wanted.forEach { (topic, instanceId) ->
                if (!watchers.containsKey(topic)) {
                    val thread = Thread { watch(topic, instanceId) }
                    thread.name = "ntfy-$topic"
                    thread.start()
                    watchers[topic] = thread
                }
            }
        }
        if (watchers.isEmpty()) stopSelf()
    }

    private fun watch(topic: String, instanceId: String) {
        var backoffMs = 2_000L
        while (running) {
            try {
                val since = System.currentTimeMillis() / 1000
                val conn = URL("https://ntfy.sh/${Uri.encode(topic)}/json?since=$since")
                    .openConnection() as HttpURLConnection
                conn.connectTimeout = 10_000
                // ntfy 心跳约 45s 一次；2 分钟无数据视为连接已死，主动重连
                conn.readTimeout = 120_000
                try {
                    conn.inputStream.bufferedReader().useLines { lines ->
                        for (line in lines) {
                            if (!running) return
                            val event = Ntfy.parse(line) ?: continue
                            if (event.event == "message") onTaskDone(instanceId)
                            backoffMs = 2_000L
                        }
                    }
                } finally {
                    conn.disconnect()
                }
            } catch (e: IOException) {
                // 断线走重连退避
            } catch (e: Exception) {
                // 单次失败不影响监听
            }
            if (!running) return
            try {
                Thread.sleep(backoffMs)
            } catch (e: InterruptedException) {
                return
            }
            backoffMs = (backoffMs * 2).coerceAtMost(60_000L)
        }
    }

    private fun onTaskDone(instanceId: String) {
        InstanceStore.markDone(this, instanceId)
        val name = InstanceStore.load(this).firstOrNull { it.id == instanceId }?.name ?: return
        Notifier.post(this, instanceId, name)
    }

    companion object {
        private const val CHANNEL_ID = "task_listen"
        private const val NOTIF_ID = 1001

        @Volatile private var isRunning = false

        /** 实例表变化后调用：有 topic 就确保服务在跑，全删了就停掉。需在主线程调用。 */
        fun ensure(context: Context) {
            val hasTopic = InstanceStore.load(context).any { !it.ntfyTopic.isNullOrEmpty() }
            val intent = Intent(context, TaskListenService::class.java)
            if (hasTopic && !isRunning) {
                context.startForegroundService(intent)
            } else if (!hasTopic && isRunning) {
                context.stopService(intent)
            }
        }
    }
}
