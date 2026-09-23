package dev.zcode.remote

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.PopupMenu
import android.widget.Toast
import dev.zcode.remote.databinding.ActivityMainBinding
import dev.zcode.remote.databinding.ItemInstanceBinding

class MainActivity : Activity() {

    private lateinit var binding: ActivityMainBinding
    private val instances = mutableListOf<Instance>()
    private lateinit var adapter: InstanceAdapter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        adapter = InstanceAdapter()
        binding.list.adapter = adapter

        binding.btnAdd.setOnClickListener { startActivity(Intent(this, ScanActivity::class.java)) }
        binding.btnAddEmpty.setOnClickListener { startActivity(Intent(this, ScanActivity::class.java)) }

        reload()
        if (savedInstanceState == null) {
            // 全新任务/冷启动：先消化外部入口（深链接/分享），没有则恢复上次打开的实例。
            // savedInstanceState != null 说明系统在重建返回栈（页面会自行恢复），
            // 此时也不重复消化深链接（否则进程被杀重建后会再弹一次编辑页）。
            val fromOutside = handleIncoming(intent)
            if (!fromOutside) restoreLastPage()
        }
        ensureNotificationPermission()
    }

    /** 任务结束提醒要发通知（桌面图标红点的来源），API 33+ 需运行时授权，问一次即可。 */
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) return
        val prefs = getSharedPreferences("settings", Context.MODE_PRIVATE)
        if (prefs.getBoolean("notif_asked", false)) return
        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED
        ) return
        prefs.edit().putBoolean("notif_asked", true).apply()
        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // 启动器再次唤起（HOME 后点图标）：部分 ROM 会以启动 Intent 直达 singleTask
        // 根并清掉上方页面——按退出前所在页面恢复，落回列表则是用户主动停在列表。
        // 无 action 的 Intent 只会来自 am start，语义等同于启动器唤起。
        if (intent.action == null || intent.action == Intent.ACTION_MAIN) {
            reload()
            val lastPageId = LastPage.pageInstance(this)
            if (lastPageId != null) {
                instances.firstOrNull { it.id == lastPageId }?.let { openInstance(it) }
            }
            return
        }
        handleIncoming(intent)
    }

    override fun onResume() {
        super.onResume()
        reload()
        // 实例/topic 可能在别处被改（编辑页、删除、通知点击），回来时对齐监听
        TaskListenService.ensure(this)
    }

    override fun onPause() {
        // 退后台/跳转页面时记录停留位置：onNewIntent 热恢复的依据
        LastPage.markList(this)
        super.onPause()
    }

    private fun reload() {
        instances.clear()
        instances.addAll(InstanceStore.load(this).sortedByDescending { it.lastOpenedAt })
        adapter.notifyDataSetChanged()
        binding.empty.visibility = if (instances.isEmpty()) View.VISIBLE else View.GONE
    }

    /** 接收 deep link（扫码 URL）与系统分享（含链接的文本）。返回是否消化了外部入口。 */
    private fun handleIncoming(intent: Intent?): Boolean {
        intent ?: return false
        val candidate = when (intent.action) {
            Intent.ACTION_VIEW -> intent.dataString
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        } ?: return false
        val raw = candidate ?: return false
        val url = Urls.sanitize(raw) ?: SharedText.extractUrl(raw)?.let { Urls.sanitize(it) }
        // 处理完立即清空 intent，避免旋转/重建后重复弹出
        setIntent(Intent(this, MainActivity::class.java))
        if (url == null) {
            Toast.makeText(this, getString(R.string.invalid_url), Toast.LENGTH_LONG).show()
            return true
        }
        openEdit(url, Urls.suggestName(url))
        return true
    }

    private fun openEdit(url: String?, name: String?) {
        startActivity(InstanceEditActivity.createIntent(this, instanceId = null, url = url, name = name))
    }

    /**
     * 冷启动直达：打开最近一次使用的实例，省去再选一次主机。
     * App 在后台被系统回收后再点图标实际是冷启动，页面栈已丢——在这里按
     * lastOpenedAt（每次打开都会更新并持久化）恢复；进程未死的前台切换
     * 由系统保留原页面，不会走到这里。全部实例都从未打开过时，
     * 仅一台则沿用旧的单实例直达行为。
     */
    private fun restoreLastPage() {
        if (autoOpened) return
        val target = instances.filter { it.lastOpenedAt > 0L }.maxByOrNull { it.lastOpenedAt }
            ?: instances.singleOrNull()
            ?: return
        autoOpened = true
        openInstance(target)
    }

    private fun openInstance(instance: Instance) {
        instance.lastOpenedAt = System.currentTimeMillis()
        InstanceStore.upsert(this, instance)
        // 打开即消化该实例的红点与提醒
        InstanceStore.clearDone(this, instance.id)
        Notifier.cancel(this, instance.id)
        startActivity(WebActivity.intent(this, instance.id))
    }

    private fun copyUrl(instance: Instance) {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("url", instance.url))
        if (Build.VERSION.SDK_INT < 33) {
            Toast.makeText(this, R.string.copied, Toast.LENGTH_SHORT).show()
        }
    }

    private fun confirmDelete(instance: Instance) {
        AlertDialog.Builder(this)
            .setTitle(R.string.delete_confirm_title)
            .setMessage(getString(R.string.delete_confirm_msg, instance.name))
            .setPositiveButton(R.string.menu_delete) { _, _ ->
                InstanceStore.remove(this, instance.id)
                reload()
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun showItemMenu(anchor: View, instance: Instance) {
        val popup = PopupMenu(this, anchor)
        popup.menuInflater.inflate(R.menu.menu_instance_item, popup.menu)
        popup.setOnMenuItemClickListener { menuItem ->
            when (menuItem.itemId) {
                R.id.action_edit -> openEditFor(instance)
                R.id.action_copy -> copyUrl(instance)
                R.id.action_delete -> confirmDelete(instance)
            }
            true
        }
        popup.show()
    }

    private fun openEditFor(instance: Instance) {
        startActivity(
            InstanceEditActivity.createIntent(this, instanceId = instance.id, url = null, name = null)
        )
    }

    private inner class InstanceAdapter : BaseAdapter() {        override fun getCount(): Int = instances.size
        override fun getItem(position: Int): Instance = instances[position]
        override fun getItemId(position: Int): Long = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val item = convertView as? ItemInstanceBinding
                ?: ItemInstanceBinding.inflate(LayoutInflater.from(parent.context), parent, false)
            val instance = getItem(position)
            val uri = runCatching { Uri.parse(instance.url) }.getOrNull()
            item.name.text = instance.name
            item.subtitle.text = buildString {
                append(uri?.host ?: instance.url)
                append(" · ")
                append(relativeTime(this@MainActivity, instance.lastOpenedAt))
            }
            item.dot.visibility = if (instance.unreadDone) View.VISIBLE else View.GONE
            item.root.setOnClickListener { openInstance(instance) }
            item.more.setOnClickListener { showItemMenu(it, instance) }
            return item.root
        }
    }

    companion object {
        /** 进程级标记：一次存活期内只自动打开一次，避免从页面返回列表后被反复拉回。 */
        private var autoOpened = false
    }
}

private object SharedText {
    fun extractUrl(text: String): String? =
        Regex("https://\\S+").find(text)?.value
}
