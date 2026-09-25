package dev.zcode.remote

import org.json.JSONObject
import java.util.UUID

/** ntfy /json 流事件解析与 topic 工具（纯函数，便于单测）。 */
object Ntfy {
    data class Event(val event: String, val topic: String, val title: String = "", val message: String = "")

    /** 单行 /json 流事件 → Event；格式异常返回 null（keepalive 等同样走这里）。 */
    fun parse(line: String): Event? = runCatching {
        val o = JSONObject(line)
        val event = o.optString("event")
        val topic = o.optString("topic")
        if (event.isEmpty() || topic.isEmpty()) null
        else Event(event, topic, o.optString("title"), o.optString("message"))
    }.getOrNull()

    fun isValidTopic(s: String): Boolean = Regex("^[A-Za-z0-9_-]{1,64}$").matches(s)

    /** 随机私有 topic：ntfy 的安全模型是「不知道 topic 名就收不到」。 */
    fun randomTopic(): String =
        "zcode-" + UUID.randomUUID().toString().replace("-", "").take(12)
}
