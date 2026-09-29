package dev.zcode.remote

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * 一个待查额度的 LLM 账号（coding-plan API key 优先，JWT 兜底）。
 * 凭据与实例链接同一安全模型：只存应用私有目录，不进日志。
 */
data class LlmAccount(
    val id: String,
    var name: String,
    var apiKey: String? = null,
    var jwt: String? = null,
    var teamKey: String? = null,
    var teamOrg: String? = null,
    var teamProj: String? = null,
    var overviewJson: String? = null,
    var lastRefreshAt: Long = 0L,
    var lastError: String? = null,
)

object QuotaAccountStore {
    private const val PREFS = "quota_accounts"
    private const val KEY = "list"

    fun load(context: Context): MutableList<LlmAccount> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
            ?: return mutableListOf()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                LlmAccount(
                    id = o.getString("id"),
                    name = o.getString("name"),
                    apiKey = o.optString("apiKey").takeIf { it.isNotEmpty() },
                    jwt = o.optString("jwt").takeIf { it.isNotEmpty() },
                    teamKey = o.optString("teamKey").takeIf { it.isNotEmpty() },
                    teamOrg = o.optString("teamOrg").takeIf { it.isNotEmpty() },
                    teamProj = o.optString("teamProj").takeIf { it.isNotEmpty() },
                    overviewJson = o.optString("overviewJson").takeIf { it.isNotEmpty() },
                    lastRefreshAt = o.optLong("lastRefreshAt", 0L),
                    lastError = o.optString("lastError").takeIf { it.isNotEmpty() },
                )
            }
        }.getOrDefault(emptyList()).toMutableList()
    }

    fun save(context: Context, list: List<LlmAccount>) {
        val arr = JSONArray()
        list.forEach { a ->
            arr.put(
                JSONObject()
                    .put("id", a.id)
                    .put("name", a.name)
                    .also { o ->
                        if (!a.apiKey.isNullOrEmpty()) o.put("apiKey", a.apiKey)
                        if (!a.jwt.isNullOrEmpty()) o.put("jwt", a.jwt)
                        if (!a.teamKey.isNullOrEmpty()) o.put("teamKey", a.teamKey)
                        if (!a.teamOrg.isNullOrEmpty()) o.put("teamOrg", a.teamOrg)
                        if (!a.teamProj.isNullOrEmpty()) o.put("teamProj", a.teamProj)
                        if (!a.overviewJson.isNullOrEmpty()) o.put("overviewJson", a.overviewJson)
                        o.put("lastRefreshAt", a.lastRefreshAt)
                        if (!a.lastError.isNullOrEmpty()) o.put("lastError", a.lastError)
                    }
            )
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, arr.toString()).apply()
    }

    fun upsert(context: Context, account: LlmAccount) {
        val list = load(context)
        val idx = list.indexOfFirst { it.id == account.id }
        if (idx >= 0) list[idx] = account else list.add(account)
        save(context, list)
    }

    fun remove(context: Context, id: String) {
        save(context, load(context).filterNot { it.id == id })
    }
}

/**
 * 「额度账号」导入载荷解析。桌面端导出脚本生成的二维码内容：
 * `{"v":1,"type":"zcode-remote-accounts","accounts":[{"n":"名","k":"apikey","jwt":"…","team":{"key":"…","org":"…","proj":"…"}}]}`
 * 兼容裸数组与单对象；扫码与手动粘贴共用。同名账号视为同一账号，凭据覆盖（对应实例扫码去重的语义）。
 */
object QuotaImport {

    fun parse(text: String): List<LlmAccount>? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        return runCatching {
            val root = JSONObject(trimmed)
            val arr = root.optJSONArray("accounts")
                ?: root.optJSONObject("accounts")?.let { JSONArray().put(it) }
                ?: if (root.has("k") || root.has("key") || root.has("jwt")) JSONArray().put(root) else null
                ?: return null
            parseArray(arr).takeIf { it.isNotEmpty() }
        }.getOrElse {
            runCatching {
                parseArray(JSONArray(trimmed)).takeIf { it.isNotEmpty() }
            }.getOrNull()
        }
    }

    private fun parseArray(arr: JSONArray): List<LlmAccount> {
        val out = mutableListOf<LlmAccount>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val team = o.optJSONObject("team")
            val key = o.optString("k").ifEmpty { o.optString("key") }.ifEmpty { o.optString("apiKey") }
                .ifEmpty { team?.optString("key").orEmpty() }
            val jwt = o.optString("jwt").ifEmpty { o.optString("token") }
            if (key.isEmpty() && jwt.isEmpty()) continue
            val name = o.optString("n").ifEmpty { o.optString("name") }.trim()
            out.add(
                LlmAccount(
                    id = UUID.randomUUID().toString(),
                    name = name.ifEmpty { "账号 ${out.size + 1}" },
                    apiKey = key.takeIf { it.isNotEmpty() },
                    jwt = jwt.takeIf { it.isNotEmpty() },
                    teamKey = null,
                    teamOrg = team?.optString("org")?.takeIf { it.isNotEmpty() },
                    teamProj = team?.optString("proj")?.takeIf { it.isNotEmpty() },
                )
            )
        }
        return out
    }

    /** 导入去重：同名账号覆盖凭据（保留 id 与上次额度），其余新增。返回 (新增数, 更新数)。 */
    fun merge(existing: MutableList<LlmAccount>, incoming: List<LlmAccount>): Pair<Int, Int> {
        var added = 0
        var updated = 0
        for (a in incoming) {
            val idx = existing.indexOfFirst { it.name == a.name }
            if (idx >= 0) {
                val old = existing[idx]
                old.apiKey = a.apiKey ?: old.apiKey
                old.jwt = a.jwt ?: old.jwt
                old.teamOrg = a.teamOrg ?: old.teamOrg
                old.teamProj = a.teamProj ?: old.teamProj
                updated++
            } else {
                existing.add(a)
                added++
            }
        }
        return added to updated
    }
}
