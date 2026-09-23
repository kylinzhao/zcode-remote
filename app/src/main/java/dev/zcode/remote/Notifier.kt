package dev.zcode.remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/**
 * 任务结束提醒：一条通知 = 桌面图标红点（系统按通知渲染角标）+ 通知中心条目。
 * 每个实例一条，用实例 id 的 hash 作通知 id，用户打开该实例时撤下。
 */
object Notifier {
    private const val CHANNEL_ID = "task_done"

    fun post(context: Context, instanceId: String, instanceName: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled()) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.notif_channel),
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply { description = context.getString(R.string.notif_channel_desc) }
        )
        // 点击通知回到该实例的远程页面
        val pi = PendingIntent.getActivity(
            context,
            instanceId.hashCode(),
            WebActivity.intent(context, instanceId).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setContentTitle(context.getString(R.string.notif_title))
            .setContentText(context.getString(R.string.notif_text, instanceName))
            .setSmallIcon(R.drawable.ic_computer)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setNumber(InstanceStore.unreadDoneCount(context))
            .build()
        manager.notify(instanceId.hashCode(), notification)
    }

    fun cancel(context: Context, instanceId: String) {
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(instanceId.hashCode())
    }
}
