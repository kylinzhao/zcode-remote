package dev.zcode.remote

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/** 一个额度条目（如「每 5 小时额度」「每周额度」或 billing 通道的按模型明细）。 */
data class QuotaItemView(
    val name: String,
    val window: String?,      // 5h / 日 / 周 / 月，null=未知
    val total: Double?,
    val used: Double?,
    val remaining: Double?,
    val percentUsed: Double?,
    val resetAt: String?,     // "09-30 19:00"
)

/** 一个套餐槽位（billing 通道一个账号可能同时有多个 active 套餐）。 */
data class QuotaPlanView(
    val tier: String?,        // Max / Pro / Lite / Start Plan / 体验
    val name: String?,
    val expire: String?,
    val items: List<QuotaItemView>,
) {
    val total: Double? get() = items.map { it.total }.sumOrNull()
    val used: Double? get() = items.map { it.used }.sumOrNull()
    val percentUsed: Double?
        get() = run {
            val t = total
            val u = used
            if (t != null && u != null && t > 0) (u / t * 100.0).coerceIn(0.0, 100.0) else null
        }
}

private fun List<Double?>.sumOrNull(): Double? {
    val vals = filterNotNull()
    return if (vals.isEmpty()) null else vals.sum()
}

/** 一次刷新得到的账号额度全貌。 */
data class QuotaOverview(
    val tier: String?,
    val expire: String?,
    val plans: List<QuotaPlanView>,
    val source: String,
    val refreshedAt: Long,
    var resetCards: String? = null,   // "5h卡 1/2 · 周卡 1/1"，monitor 通道才有
) {
    fun toJson(): String {
        val root = JSONObject()
            .put("tier", tier)
            .put("expire", expire)
            .put("source", source)
            .put("refreshedAt", refreshedAt)
        resetCards?.let { root.put("resetCards", it) }
        val arr = JSONArray()
        plans.forEach { p ->
            val items = JSONArray()
            p.items.forEach { it0 ->
                val o = JSONObject().put("name", it0.name)
                it0.window?.let { w -> o.put("window", w) }
                it0.total?.let { v -> o.put("total", v) }
                it0.used?.let { v -> o.put("used", v) }
                it0.remaining?.let { v -> o.put("remaining", v) }
                it0.percentUsed?.let { v -> o.put("percent", v) }
                it0.resetAt?.let { v -> o.put("resetAt", v) }
                items.put(o)
            }
            arr.put(
                JSONObject()
                    .put("tier", p.tier)
                    .put("name", p.name)
                    .put("expire", p.expire)
                    .put("items", items)
            )
        }
        root.put("plans", arr)
        return root.toString()
    }

    companion object {
        fun fromJson(raw: String?): QuotaOverview? {
            raw ?: return null
            return runCatching {
                val o = JSONObject(raw)
                val plans = mutableListOf<QuotaPlanView>()
                val arr = o.optJSONArray("plans") ?: JSONArray()
                for (i in 0 until arr.length()) {
                    val p = arr.getJSONObject(i)
                    val items = mutableListOf<QuotaItemView>()
                    val ia = p.optJSONArray("items") ?: JSONArray()
                    for (j in 0 until ia.length()) {
                        val it0 = ia.getJSONObject(j)
                        items.add(
                            QuotaItemView(
                                name = it0.getString("name"),
                                window = it0.optString("window").takeIf { it.isNotEmpty() },
                                total = it0.optDouble("total").takeIf { !it0.isNull("total") },
                                used = it0.optDouble("used").takeIf { !it0.isNull("used") },
                                remaining = it0.optDouble("remaining").takeIf { !it0.isNull("remaining") },
                                percentUsed = it0.optDouble("percent").takeIf { !it0.isNull("percent") },
                                resetAt = it0.optString("resetAt").takeIf { it.isNotEmpty() },
                            )
                        )
                    }
                    plans.add(
                        QuotaPlanView(
                            tier = p.optString("tier").takeIf { it.isNotEmpty() },
                            name = p.optString("name").takeIf { it.isNotEmpty() },
                            expire = p.optString("expire").takeIf { it.isNotEmpty() },
                            items = items,
                        )
                    )
                }
                QuotaOverview(
                    tier = o.optString("tier").takeIf { it.isNotEmpty() },
                    expire = o.optString("expire").takeIf { it.isNotEmpty() },
                    plans = plans,
                    source = o.optString("source"),
                    refreshedAt = o.optLong("refreshedAt", 0L),
                    resetCards = o.optString("resetCards").takeIf { it.isNotEmpty() },
                )
            }.getOrNull()
        }

        /** 卡片头部展示用的主槽位：套餐等级最高者优先。 */
        fun primaryPlan(overview: QuotaOverview?): QuotaPlanView? =
            overview?.plans?.maxByOrNull { tierRank(it.tier) ?: -1 }
    }
}

internal fun tierRank(tier: String?): Int? {
    val t = (tier ?: return null).lowercase(Locale.ROOT)
    return when {
        "max" in t -> 5
        "pro" in t -> 4
        "lite" in t -> 3
        "start" in t -> 2
        "trial" in t || tier == "体验" -> 1
        else -> 0
    }
}

/**
 * 额度查询：移植自 zcode-switch 的三通道策略 —
 * 1. coding-plan key → open.bigmodel.cn /api/monitor/usage/quota/limit（团队走 ?type=2 + 组织/项目头），
 *    业务拒绝或网络失败自动换 api.z.ai 同路径；
 * 2. 同上通道的 /api/biz/subscription/list（套餐名/到期）与 /api/biz/customer-package-reset/list（重置卡，尽力而为）；
 * 3. JWT → zcode.z.ai /api/v1/zcode-plan/billing/balance 兜底。
 */
object QuotaClient {

    private const val APP_VERSION = "3.14.0"
    private val NO_PLAN_WORDS = listOf("不存在coding plan", "没有资格")

    /** 刷新一个账号；失败抛 Exception（消息已面向用户）。 */
    fun refresh(account: LlmAccount): QuotaOverview {
        val errors = mutableListOf<String>()
        val keys = listOf(account.teamKey, account.apiKey).filterNotNull().distinct()
        for (key in keys) {
            try {
                return monitor(account, key)
            } catch (e: QuotaException) {
                errors.add(e.message ?: "查询失败")
            } catch (e: IOException) {
                errors.add("网络错误：${e.message ?: "连接失败"}")
            }
        }
        account.jwt?.takeIf { it.isNotEmpty() }?.let { jwt ->
            try {
                return billing(jwt)
            } catch (e: QuotaException) {
                errors.add(e.message ?: "查询失败")
            } catch (e: IOException) {
                errors.add("网络错误：${e.message ?: "连接失败"}")
            }
        }
        throw Exception(errors.distinct().joinToString("；").ifEmpty { "没有可用的账号凭据" })
    }

    // ---------- 通道一：monitor（coding-plan key） ----------

    private fun monitor(account: LlmAccount, key: String): QuotaOverview {
        val team = account.teamOrg?.takeIf { it.isNotEmpty() }?.let { org ->
            TeamHeaders(org, account.teamProj.orEmpty(), account.teamKey)
        }
        var lastErr: String? = null
        var noPlan = false
        for (base in listOf("https://open.bigmodel.cn", "https://api.z.ai")) {
            try {
                val headers = teamHeaders(team)
                val resp = httpGet("$base/api/monitor/usage/quota/limit${if (team != null) "?type=2" else ""}", key, headers)
                if (businessOk(resp)) {
                    val sub = runCatching {
                        httpGet("$base/api/biz/subscription/list", key, headers)
                    }.getOrNull()
                    val ov = parseMonitor(resp, sub)
                    runCatching {
                        val resetUrl = "$base/api/biz/customer-package-reset/list?targetType=${if (team != null) "TEAM" else "PERSONAL"}"
                        parseResetCards(httpGet(resetUrl, key, headers))
                    }.getOrNull()?.let { ov.resetCards = it }
                    return ov
                }
                val msg = resp.optString("msg").ifEmpty { resp.optString("message") }
                if (NO_PLAN_WORDS.any { msg.contains(it) }) {
                    noPlan = true
                } else {
                    lastErr = lastErr ?: "bigmodel 业务错误 ${resp.optInt("code")}: $msg"
                }
            } catch (e: IOException) {
                lastErr = lastErr ?: "网络错误：${e.message ?: "连接失败"}"
            }
        }
        throw QuotaException(
            when {
                noPlan -> "这把 key 下没有 coding plan"
                else -> lastErr ?: "查询失败"
            }
        )
    }

    private class TeamHeaders(val org: String, val proj: String, val seatKey: String?)

    private fun teamHeaders(team: TeamHeaders?): List<Pair<String, String>> {
        if (team == null) return emptyList()
        val h = mutableListOf("bigmodel-organization" to team.org)
        if (team.proj.isNotEmpty()) h.add("bigmodel-project" to team.proj)
        return h
    }

    private fun businessOk(o: JSONObject): Boolean {
        val hasCode = o.has("code")
        val code = if (hasCode) o.optInt("code") else -1
        val codeOk = !hasCode || code == 200 || code == 0
        return codeOk && o.optBoolean("success", true)
    }

    // ---------- 通道二：billing/balance（JWT 兜底） ----------

    private fun billing(jwt: String): QuotaOverview {
        val resp = httpGet(
            "https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=$APP_VERSION",
            jwt,
            listOf(
                "User-Agent" to "ZCode/$APP_VERSION",
                "HTTP-Referer" to "https://zcode.z.ai",
                "X-Title" to "Z Code@electron",
                "X-ZCode-App-Version" to APP_VERSION,
                "X-Release-Channel" to "stable",
                "X-Client-Language" to "zh-CN",
            ),
        )
        if (!businessOk(resp)) {
            throw QuotaException("billing 接口返回 code=${resp.optInt("code")}")
        }
        return parseBalance(resp)
    }

    // ---------- 解析：monitor/limit + subscription ----------

    private fun parseMonitor(limit: JSONObject, sub: JSONObject?): QuotaOverview {
        val data = limit.optJSONObject("data") ?: JSONObject()
        val limits = data.optJSONArray("limits") ?: JSONArray()
        val items = mutableListOf<QuotaItemView>()
        for (i in 0 until limits.length()) {
            val l = limits.optJSONObject(i) ?: continue
            val window = windowLabel(l.optInt("unit", -1), l.optInt("number", 0))
            val total = l.optDouble("usage").takeIf { !l.isNull("usage") }
            val used = l.optDouble("currentValue").takeIf { !l.isNull("currentValue") }
            val remaining = l.optDouble("remaining").takeIf { !l.isNull("remaining") }
            val percent = when {
                total != null && used != null && total > 0 -> (used / total * 100.0).coerceIn(0.0, 100.0)
                !l.isNull("percentage") -> l.optDouble("percentage").coerceIn(0.0, 100.0)
                else -> null
            }
            val resetAt = l.optLong("nextResetTime", 0L).takeIf { it > 0 }?.let { fmtTime(it, "MM-dd HH:mm") }
            val item = QuotaItemView("${window ?: "每周期"}额度", window, total, used, remaining, percent, resetAt)
            items.add(item)
        }

        var tier = data.optString("level").takeIf { it.isNotEmpty() }?.let { tierFromLevel(it) }
        var expire: String? = null
        if (sub != null && businessOk(sub)) {
            val arr = sub.optJSONArray("data") ?: JSONArray()
            val current = (0 until arr.length())
                .mapNotNull { arr.optJSONObject(it) }
                .firstOrNull {
                    it.optString("status") == "VALID" && it.optBoolean("inCurrentPeriod", true)
                }
            if (current != null) {
                current.optString("productName").takeIf { it.isNotEmpty() }?.let {
                    tier = tierFromLevel(it)
                }
                expire = extractExpire(current)
            }
        }
        return QuotaOverview(
            tier = tier,
            expire = expire,
            plans = if (tier != null || items.isNotEmpty()) {
                listOf(QuotaPlanView(tier, null, expire, items))
            } else emptyList(),
            source = "monitor",
            refreshedAt = System.currentTimeMillis(),
        )
    }

    // ---------- 解析：billing/balance（多套餐槽位） ----------

    private fun parseBalance(resp: JSONObject): QuotaOverview {
        val balance = unwrapData(resp)
        val slots = mutableListOf<PlanSlot>()
        val plans = balance.optJSONArray("plans") ?: JSONArray()
        for (i in 0 until plans.length()) {
            val p = plans.optJSONObject(i) ?: continue
            if (!p.optString("status").equals("active", ignoreCase = true)) continue
            val pid = p.optString("plan_id")
            val pname = p.optString("name").takeIf { it.isNotEmpty() }
            val (tier, _) = tierFromPlanId(pid, pname)
            slots.add(PlanSlot(pid, tier, pname ?: pid, extractExpire(p)))
        }
        val balancesArr = balance.optJSONArray("balances") ?: JSONArray()
        val anyPid = (0 until balancesArr.length()).any { j ->
            val it0 = balancesArr.optJSONObject(j) ?: return@any false
            listOf("plan_id", "planId", "entitlement_id").any { k -> it0.optString(k).isNotEmpty() }
        }
        val loose = mutableListOf<QuotaItemView>()
        for (i in 0 until balancesArr.length()) {
            val b = balancesArr.optJSONObject(i) ?: continue
            val total = b.optDouble("total_units").takeIf { !b.isNull("total_units") }
            val used = b.optDouble("used_units").takeIf { !b.isNull("used_units") }
            val remaining = b.optDouble("remaining_units").takeIf { !b.isNull("remaining_units") }
                ?: b.optDouble("available_units").takeIf { !b.isNull("available_units") }
            val percent = if (total != null && used != null && total > 0) (used / total * 100.0).coerceIn(0.0, 100.0) else null
            val item = QuotaItemView(
                name = listOf("show_name", "name", "entitlement_id", "plan_id").firstNotNullOfOrNull { b.optString(it).takeIf { s -> s.isNotEmpty() } } ?: "Unknown",
                window = null,
                total = total, used = used, remaining = remaining, percentUsed = percent,
                resetAt = listOf("period_end", "expires_at").firstNotNullOfOrNull { k ->
                    if (b.isNull(k)) null else extractExpireString(b.opt(k))
                },
            )
            val bpid = listOf("plan_id", "planId", "entitlement_id").firstNotNullOfOrNull { b.optString(it).takeIf { s -> s.isNotEmpty() } }.orEmpty()
            val target = when {
                bpid.isNotEmpty() -> slots.firstOrNull { it.pid == bpid }
                slots.size == 1 && !anyPid -> slots.first()
                else -> null
            }
            if (target != null) {
                if (target.expire == null) target.expire = item.resetAt
                target.items.add(item)
            } else {
                loose.add(item)
            }
        }
        if (loose.isNotEmpty()) slots.add(PlanSlot("", null, "其他额度", null, loose))
        slots.forEach { s -> if (s.items.isEmpty()) s.items.add(QuotaItemView(s.name, null, null, null, null, null, s.expire)) }
        val primary = slots.maxByOrNull { tierRank(it.tier) ?: -1 }
        return QuotaOverview(
            tier = primary?.tier,
            expire = primary?.expire,
            plans = slots.map { s ->
                QuotaPlanView(s.tier, s.name, s.expire, s.items.toList())
            },
            source = "billing",
            refreshedAt = System.currentTimeMillis(),
        )
    }

    private class PlanSlot(
        val pid: String,
        val tier: String?,
        val name: String,
        var expire: String?,
        val items: MutableList<QuotaItemView> = mutableListOf(),
    )

    private fun unwrapData(o: JSONObject): JSONObject {
        var cur = o
        repeat(4) {
            val d = cur.optJSONObject("data") ?: return@repeat
            cur = d
        }
        return cur
    }

    // ---------- 重置卡 ----------

    private fun parseResetCards(resp: JSONObject): String? {
        val data = resp.optJSONObject("data") ?: return null
        fun group(name: String): String? {
            val arr = data.optJSONArray(name) ?: return null
            var available = 0
            var nextExpire: String? = null
            for (i in 0 until arr.length()) {
                val r = arr.optJSONObject(i) ?: continue
                if (!r.optBoolean("available", false)) continue
                available++
                val e = r.optString("expireTime").takeIf { it.isNotEmpty() }
                if (e != null && (nextExpire == null || e < nextExpire)) nextExpire = e
            }
            return if (available > 0) "${available}/${arr.length()} 张" else null
        }
        val parts = listOfNotNull(
            group("fiveHourResets")?.let { "5h卡 $it" },
            group("weekResets")?.let { "周卡 $it" },
        )
        return parts.joinToString(" · ").ifEmpty { null }
    }

    // ---------- 通用工具 ----------

    private class QuotaException(message: String) : Exception(message)

    private fun httpGet(url: String, token: String, extraHeaders: List<Pair<String, String>>): JSONObject {
        var lastErr: Exception? = null
        repeat(2) { attempt ->
            try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 10_000
                conn.readTimeout = 20_000
                conn.requestMethod = "GET"
                conn.setRequestProperty("Authorization", "Bearer $token")
                conn.setRequestProperty("User-Agent", "ZCode/$APP_VERSION")
                conn.setRequestProperty("x-request-id", UUID.randomUUID().toString())
                extraHeaders.forEach { (k, v) -> conn.setRequestProperty(k, v) }
                val code = conn.responseCode
                val body = (conn.inputStream ?: conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
                if (code == 429 && attempt == 0) {
                    Thread.sleep(2000)
                    return@repeat
                }
                if (code == 401 || code == 403) throw QuotaException("凭证无效（HTTP $code）")
                if (code < 200 || code >= 300) {
                    throw QuotaException("HTTP $code ${errorMessage(body)}")
                }
                if (body.isBlank()) throw QuotaException("响应为空")
                val parsed = JSONTokener(body).nextValue()
                return when (parsed) {
                    is JSONObject -> parsed
                    is JSONArray -> JSONObject().put("data", parsed)
                    else -> throw QuotaException("响应格式异常")
                }
            } catch (e: QuotaException) {
                throw e
            } catch (e: IOException) {
                lastErr = e
                if (attempt == 1) throw IOException(e.message ?: "连接失败")
                return@repeat
            } catch (e: InterruptedException) {
                throw IOException("请求被中断")
            }
        }
        throw lastErr ?: IOException("请求失败")
    }

    private fun errorMessage(body: String): String =
        runCatching {
            val o = JSONObject(body)
            listOf("message", "msg", "error").firstNotNullOfOrNull { o.optString(it).takeIf { s -> s.isNotEmpty() } }
        }.getOrNull().orEmpty().take(80)

    private fun windowLabel(unit: Int, number: Int): String? = when (unit) {
        3 -> "每 ${if (number > 0) number else 5} 小时"
        4 -> "每天"
        5 -> "每月"
        6 -> "每周"
        else -> null
    }

    private fun tierFromLevel(level: String): String {
        val l = level.lowercase(Locale.ROOT)
        return when {
            "max" in l -> "Max"
            "pro" in l -> "Pro"
            "lite" in l -> "Lite"
            else -> level
        }
    }

    private fun tierFromPlanId(planId: String, name: String?): Pair<String?, String?> {
        val hay = (planId + " " + (name ?: "")).lowercase(Locale.ROOT)
        return when {
            "max" in hay -> "Max" to "max"
            "pro" in hay -> "Pro" to "pro"
            "lite" in hay -> "Lite" to "lite"
            "start" in hay -> "Start Plan" to "start"
            listOf("trial", "taste", "experience", "gift", "weekend", "promo", "体验").any { it in hay } -> "体验" to "trial"
            else -> name?.takeIf { it.isNotBlank() } to "other"
        }
    }

    /** 从对象的常见到期字段里抽取到期时间文本（键集合与 zcode-switch 一致）。 */
    private fun extractExpire(o: JSONObject): String? {
        val keys = listOf(
            "nextRenewTime", "expireTime", "expire_time", "endTime", "end_time", "expireAt",
            "expiredTime", "validEndTime", "expires_at", "expiresAt", "expired_at", "period_end",
        )
        for (k in keys) {
            if (o.isNull(k)) continue
            val s = extractExpireString(o.opt(k)) ?: continue
            return s
        }
        return null
    }

    private fun extractExpireString(v: Any?): String? {
        return when (v) {
            is Number -> {
                val n = v.toLong()
                when {
                    n > 1_000_000_000_000L -> fmtTime(n, "yyyy-MM-dd HH:mm")
                    n > 1_000_000_000L -> fmtTime(n * 1000L, "yyyy-MM-dd HH:mm")
                    else -> null
                }
            }
            is String -> {
                val t = v.trim()
                if (t.isEmpty()) return null
                t.toLongOrNull()?.let { return extractExpireString(it) }
                // RFC3339 / ISO：取前 16 位 "yyyy-MM-dd HH:mm"（T 换空格）
                if (t.length >= 16 && t[4] == '-' && t[7] == '-') {
                    return t.replace('T', ' ').take(16)
                }
                if (t.length >= 10 && t[4] == '-' && t[7] == '-') return t.take(10)
                t
            }
            else -> null
        }
    }

    private fun fmtTime(millis: Long, pattern: String): String =
        SimpleDateFormat(pattern, Locale.getDefault()).format(Date(millis))

    /** 重置时间短格式（列表展示）。 */
    fun fmtReset(ms: Long): String = SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(Date(ms))
}
