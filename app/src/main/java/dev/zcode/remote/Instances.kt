package dev.zcode.remote

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class Instance(
    val id: String,
    var name: String,
    var url: String,
    var keepScreenOn: Boolean,
    var createdAt: Long,
    var lastOpenedAt: Long,
    var unreadDone: Boolean = false,
    var ntfyTopic: String? = null,
)

object InstanceStore {
    private const val PREFS = "instances"
    private const val KEY = "list"

    fun load(context: Context): MutableList<Instance> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
            ?: return mutableListOf()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                Instance(
                    id = o.getString("id"),
                    name = o.getString("name"),
                    url = o.getString("url"),
                    keepScreenOn = o.optBoolean("keepScreenOn", false),
                    createdAt = o.optLong("createdAt", 0L),
                    lastOpenedAt = o.optLong("lastOpenedAt", 0L),
                    unreadDone = o.optBoolean("unreadDone", false),
                    ntfyTopic = o.optString("ntfyTopic").takeIf { it.isNotEmpty() },
                )
            }
        }.getOrDefault(emptyList()).toMutableList()
    }

    fun save(context: Context, list: List<Instance>) {
        val arr = JSONArray()
        list.forEach { i ->
            arr.put(
                JSONObject()
                    .put("id", i.id)
                    .put("name", i.name)
                    .put("url", i.url)
                    .put("keepScreenOn", i.keepScreenOn)
                    .put("createdAt", i.createdAt)
                    .put("lastOpenedAt", i.lastOpenedAt)
                    .put("unreadDone", i.unreadDone)
                    .also { if (i.ntfyTopic != null) it.put("ntfyTopic", i.ntfyTopic) }
            )
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, arr.toString()).apply()
    }

    fun upsert(context: Context, instance: Instance) {
        val list = load(context)
        val idx = list.indexOfFirst { it.id == instance.id }
        if (idx >= 0) list[idx] = instance else list.add(instance)
        save(context, list)
    }

    fun remove(context: Context, id: String) {
        save(context, load(context).filterNot { it.id == id })
    }

    /** 页面侧检测到任务结束（用户不在场）→ 点亮该实例红点。 */
    fun markDone(context: Context, id: String) {
        val list = load(context)
        val idx = list.indexOfFirst { it.id == id }
        if (idx >= 0 && !list[idx].unreadDone) {
            list[idx].unreadDone = true
            save(context, list)
        }
    }

    /** 用户打开该实例 → 清除红点。 */
    fun clearDone(context: Context, id: String) {
        val list = load(context)
        val idx = list.indexOfFirst { it.id == id }
        if (idx >= 0 && list[idx].unreadDone) {
            list[idx].unreadDone = false
            save(context, list)
        }
    }

    fun unreadDoneCount(context: Context): Int =
        load(context).count { it.unreadDone }
}

object Urls {
    private val trailingJunk = Regex("[\\s\"'<>),.;。」』）】]+")

    /** 清洗粘贴内容：去空白/控制字符/首尾杂字符，仅接受 https，返回规范化的完整 URL 或 null。 */
    fun sanitize(raw: String): String? {
        val s = raw.replace(Regex("[\\s\\u0000-\\u001F\\u007F]+"), "")
            .trim(' ', '"', '\'', '<', '>', ')', ',', '.', ';', '。', '』', '）', '】', ']')
        if (!s.startsWith("https://", ignoreCase = true)) return null
        val host = Uri.parse(s).host ?: return null
        if (host.isBlank()) return null
        return s
    }

    /** 从远程链接的 name 参数建议实例名（去掉 .local 后缀）。 */
    fun suggestName(url: String): String? {
        val name = runCatching { Uri.parse(url).getQueryParameter("name") }.getOrNull() ?: return null
        return name.removeSuffix(".local").trim().takeIf { it.isNotBlank() }?.take(40)
    }
}

fun relativeTime(context: Context, ts: Long): String {
    if (ts <= 0L) return context.getString(R.string.not_opened_yet)
    val minutes = (System.currentTimeMillis() - ts) / 60000L
    return when {
        minutes < 1L -> context.getString(R.string.just_now)
        minutes < 60L -> context.getString(R.string.minutes_ago, minutes)
        minutes < 1440L -> context.getString(R.string.hours_ago, minutes / 60)
        minutes < 43200L -> context.getString(R.string.days_ago, minutes / 1440)
        else -> SimpleDateFormat("yyyy-M-d", Locale.getDefault()).format(Date(ts))
    }
}

/**
 * 记录退后台时停在哪个页面（"list" 或 "page:<instanceId>"）。
 * 部分 ROM 启动器以启动 Intent 再次唤起 singleTask 根 Activity 时会清掉上方页面，
 * onNewIntent 据此恢复到退出前所在页面，而不是落回列表。
 */
object LastPage {
    private const val PREFS = "settings"
    private const val KEY = "last_page"

    fun markList(context: Context) = mark(context, "list")

    fun markPage(context: Context, instanceId: String) = mark(context, "page:$instanceId")

    private fun mark(context: Context, value: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, value).apply()
    }

    /** 上次停在的实例页面 id；停在列表或无记录返回 null。 */
    fun pageInstance(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null)?.takeIf { it.startsWith("page:") }?.removePrefix("page:")
}
