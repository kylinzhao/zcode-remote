package dev.zcode.remote

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.PopupMenu
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import android.widget.LinearLayout
import dev.zcode.remote.databinding.ActivityQuotaBinding
import dev.zcode.remote.databinding.ItemAccountBinding
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 账号额度页：多账号列表 + 额度进度条 + 手动/扫码导入 + 刷新。 */
class QuotaActivity : Activity() {

    private lateinit var binding: ActivityQuotaBinding
    private val accounts = mutableListOf<LlmAccount>()
    private lateinit var adapter: AccountAdapter
    private val refreshingMarks = mutableSetOf<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityQuotaBinding.inflate(layoutInflater)
        setContentView(binding.root)

        adapter = AccountAdapter()
        binding.list.adapter = adapter
        binding.btnBack.setOnClickListener { finish() }
        binding.btnAdd.setOnClickListener {
            startActivity(ScanActivity.accountIntent(this))
        }
        binding.btnRefreshAll.setOnClickListener { refreshAll() }

        // 长按卡片弹出菜单（与实例列表的 ⋮ 一致），照顾不知道点 ⋮ 的场景
        binding.list.setOnItemLongClickListener { _, _, position, _ ->
            showItemMenu(binding.list, accounts[position])
            true
        }
    }

    override fun onResume() {
        super.onResume()
        reload()
        refreshStale()
    }

    private fun reload() {
        accounts.clear()
        accounts.addAll(QuotaAccountStore.load(this))
        adapter.notifyDataSetChanged()
        binding.empty.visibility = if (accounts.isEmpty()) View.VISIBLE else View.GONE
    }

    private fun refreshStale() {
        val targets = synchronized(refreshingMarks) {
            accounts.filter { it.lastRefreshAt == 0L && !refreshingMarks.contains(it.id) }
        }
        targets.forEach { refreshOne(it) }
    }

    private fun refreshAll() {
        synchronized(refreshingMarks) {
            if (refreshingMarks.isNotEmpty()) {
                Toast.makeText(this, R.string.quota_refreshing, Toast.LENGTH_SHORT).show()
                return
            }
        }
        val targets = accounts.toList()
        if (targets.isEmpty()) return
        targets.forEach { refreshOne(it) }
    }

    private fun refreshOne(account: LlmAccount) {
        synchronized(refreshingMarks) {
            if (!refreshingMarks.add(account.id)) return
        }
        Thread {
            val result = runCatching { QuotaClient.refresh(account) }
            runOnUiThread {
                synchronized(refreshingMarks) { refreshingMarks.remove(account.id) }
                val stored = QuotaAccountStore.load(this).firstOrNull { it.id == account.id }
                if (stored != null) {
                    result.onSuccess { ov ->
                        stored.overviewJson = ov.toJson()
                        stored.lastRefreshAt = System.currentTimeMillis()
                        stored.lastError = null
                    }.onFailure { e ->
                        stored.lastError = e.message ?: "查询失败"
                    }
                    QuotaAccountStore.upsert(this, stored)
                }
                reload()
            }
        }.start()
    }

    private fun confirmDelete(account: LlmAccount) {
        AlertDialog.Builder(this)
            .setTitle(R.string.quota_delete_title)
            .setMessage(getString(R.string.quota_delete_msg, account.name))
            .setPositiveButton(R.string.menu_delete) { _, _ ->
                QuotaAccountStore.remove(this, account.id)
                reload()
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun showItemMenu(anchor: View, account: LlmAccount) {
        val popup = PopupMenu(this, anchor)
        popup.menuInflater.inflate(R.menu.menu_account_item, popup.menu)
        popup.setOnMenuItemClickListener { menuItem ->
            when (menuItem.itemId) {
                R.id.action_edit -> startActivity(
                    AccountEditActivity.createIntent(this, account.id)
                )
                R.id.action_refresh -> refreshOne(account)
                R.id.action_delete -> confirmDelete(account)
            }
            true
        }
        popup.show()
    }

    private inner class AccountAdapter : BaseAdapter() {
        override fun getCount(): Int = accounts.size
        override fun getItem(position: Int): LlmAccount = accounts[position]
        override fun getItemId(position: Int): Long = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val item = convertView as? ItemAccountBinding
                ?: ItemAccountBinding.inflate(LayoutInflater.from(parent.context), parent, false)
            val account = getItem(position)
            val overview = QuotaOverview.fromJson(account.overviewJson)
            val primary = QuotaOverview.primaryPlan(overview)

            item.name.text = account.name
            if (primary?.tier != null) {
                item.tier.text = primary.tier
                item.tier.visibility = View.VISIBLE
            } else {
                item.tier.visibility = View.GONE
            }

            item.bars.removeAllViews()
            val items = primary?.items.orEmpty()
            for (q in items) {
                item.bars.addView(barView(parent, q))
            }
            if (items.isEmpty() && account.lastError == null) {
                val loading = TextView(this@QuotaActivity).apply {
                    text = getString(
                        if (refreshingMarks.contains(account.id)) R.string.quota_loading
                        else R.string.quota_no_data
                    )
                    setTextAppearance(this@QuotaActivity, android.R.style.TextAppearance_Small)
                    setTextColor(getColor(R.color.on_surface_variant_c))
                }
                item.bars.addView(loading)
            }

            val meta = buildList {
                primary?.expire?.let { add(getString(R.string.quota_expire, it)) }
                overview?.resetCards?.let { add(it) }
                if (account.lastRefreshAt > 0L) {
                    add(
                        getString(
                            R.string.quota_refreshed_at,
                            SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(account.lastRefreshAt))
                        )
                    )
                }
            }
            if (meta.isNotEmpty()) {
                item.expire.text = meta.joinToString(" · ")
                item.expire.visibility = View.VISIBLE
            } else {
                item.expire.visibility = View.GONE
            }

            if (account.lastError != null) {
                item.error.text = account.lastError
                item.error.visibility = View.VISIBLE
            } else {
                item.error.visibility = View.GONE
            }

            item.more.setOnClickListener { showItemMenu(it, account) }
            return item.root
        }

        private fun barView(parent: ViewGroup, q: QuotaItemView): View {
            val ctx = this@QuotaActivity
            val wrap = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(6), 0, 0)
            }
            val row = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
            val label = TextView(ctx).apply {
                text = q.window ?: q.name
                textSize = 12f
                setTextColor(getColor(R.color.on_surface_variant_c))
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            }
            val detail = TextView(ctx).apply {
                text = buildString {
                    append(fmtUsed(q))
                    q.resetAt?.let { append(" · ").append(getString(R.string.quota_reset_at, it)) }
                }
                textSize = 12f
                setTextColor(getColor(R.color.on_surface_variant_c))
            }
            row.addView(label)
            row.addView(detail)
            wrap.addView(row)

            val percent = q.percentUsed
            if (percent != null) {
                val bar = ProgressBar(ctx, null, android.R.attr.progressBarStyleHorizontal).apply {
                    max = 100
                    progress = percent.toInt()
                    layoutParams = LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, dp(6)
                    ).also { it.topMargin = dp(3) }
                    progressTintList = android.content.res.ColorStateList.valueOf(barColor(percent))
                    progressBackgroundTintList =
                        android.content.res.ColorStateList.valueOf(getColor(R.color.card_stroke))
                }
                wrap.addView(bar)
            }
            return wrap
        }

        private fun barColor(percent: Double): Int {
            val res = when {
                percent >= 90.0 -> R.color.danger_c
                percent >= 75.0 -> R.color.warn_c
                else -> R.color.brand_primary
            }
            return getColor(res)
        }

        private fun fmtUsed(q: QuotaItemView): String {
            val u = q.used
            val t = q.total
            return when {
                u != null && t != null -> "${fmtNum(u)} / ${fmtNum(t)}"
                u != null -> getString(R.string.quota_used_only, fmtNum(u))
                t != null -> getString(R.string.quota_total_only, fmtNum(t))
                else -> "—"
            }
        }

        private fun fmtNum(v: Double): String = when {
            v >= 100_000_000 -> trimZero(v / 100_000_000) + "亿"
            v >= 10_000 -> trimZero(v / 10_000) + "万"
            v == v.toLong().toDouble() -> String.format(Locale.getDefault(), "%,d", v.toLong())
            else -> String.format(Locale.getDefault(), "%.1f", v)
        }

        private fun trimZero(v: Double): String =
            if (v == v.toLong().toDouble()) v.toLong().toString() else String.format(Locale.getDefault(), "%.1f", v)

        private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
    }

    companion object {
        fun intent(context: Context): Intent = Intent(context, QuotaActivity::class.java)
    }
}
