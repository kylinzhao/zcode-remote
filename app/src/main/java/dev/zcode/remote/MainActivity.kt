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
        handleIncoming(intent)
        autoOpenIfSingle()
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
        handleIncoming(intent)
    }

    override fun onResume() {
        super.onResume()
        reload()
    }

    private fun reload() {
        instances.clear()
        instances.addAll(InstanceStore.load(this).sortedByDescending { it.lastOpenedAt })
        adapter.notifyDataSetChanged()
        binding.empty.visibility = if (instances.isEmpty()) View.VISIBLE else View.GONE
    }

    /** 接收 deep link（扫码 URL）与系统分享（含链接的文本）。 */
    private fun handleIncoming(intent: Intent?) {
        intent ?: return
        val candidate = when (intent.action) {
            Intent.ACTION_VIEW -> intent.dataString
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        } ?: return
        val raw = candidate ?: return
        val url = Urls.sanitize(raw) ?: SharedText.extractUrl(raw)?.let { Urls.sanitize(it) }
        // 处理完立即清空 intent，避免旋转/重建后重复弹出
        setIntent(Intent(this, MainActivity::class.java))
        if (url == null) {
            Toast.makeText(this, getString(R.string.invalid_url), Toast.LENGTH_LONG).show()
            return
        }
        openEdit(url, Urls.suggestName(url))
    }

    private fun openEdit(url: String?, name: String?) {
        startActivity(InstanceEditActivity.createIntent(this, instanceId = null, url = url, name = name))
    }

    /** 仅绑定一个实例时，进程内首次进入 App 直接打开该页面。 */
    private fun autoOpenIfSingle() {
        if (autoOpened) return
        val single = instances.singleOrNull() ?: return
        autoOpened = true
        openInstance(single)
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
