package dev.zcode.remote

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import dev.zcode.remote.databinding.ActivityEditBinding
import java.util.UUID

class InstanceEditActivity : Activity() {

    private lateinit var binding: ActivityEditBinding
    private var editingId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityEditBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.btnBack.setOnClickListener { finish() }

        editingId = intent.getStringExtra(EXTRA_ID)
        if (editingId != null) {
            val existing = InstanceStore.load(this).firstOrNull { it.id == editingId }
            if (existing == null) {
                finish(); return
            }
            binding.tvTitle.setText(R.string.title_edit_instance)
            binding.inputName.setText(existing.name)
            binding.inputUrl.setText(existing.url)
            binding.switchKeepScreenOn.isChecked = existing.keepScreenOn
            binding.inputTopic.setText(existing.ntfyTopic.orEmpty())
        } else {
            val url = intent.getStringExtra(EXTRA_URL)
            binding.inputUrl.setText(url)
            binding.inputName.setText(
                intent.getStringExtra(EXTRA_NAME) ?: url?.let { Urls.suggestName(it) }
            )
            if (url != null) binding.inputUrl.requestFocus()
            else binding.inputName.requestFocus()
        }

        binding.btnSave.setOnClickListener { save() }
        binding.btnCancel.setOnClickListener { finish() }
        binding.btnGenTopic.setOnClickListener {
            binding.inputTopic.setText(Ntfy.randomTopic())
        }
        binding.btnCopyInstall.setOnClickListener { copyInstallCommand() }
    }

    /** 复制电脑端一键安装命令（raw 模板把 __TOPIC__ 换成本实例的 topic）。 */
    private fun copyInstallCommand() {
        val topic = binding.inputTopic.text?.toString()?.trim().orEmpty()
        if (topic.isEmpty()) {
            Toast.makeText(this, R.string.topic_needed, Toast.LENGTH_LONG).show()
            return
        }
        val script = resources.openRawResource(R.raw.install_hook)
            .bufferedReader().use { it.readText() }
            .replace("__TOPIC__", topic)
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("install", script))
        if (Build.VERSION.SDK_INT < 33) {
            Toast.makeText(this, R.string.install_copied, Toast.LENGTH_LONG).show()
        }
    }

    private fun save() {
        val url = Urls.sanitize(binding.inputUrl.text?.toString().orEmpty())
        if (url == null) {
            Toast.makeText(this, R.string.invalid_url, Toast.LENGTH_LONG).show()
            return
        }
        val name = binding.inputName.text?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
            ?: Urls.suggestName(url)
            ?: getString(R.string.app_name)

        val topic = binding.inputTopic.text?.toString()?.trim().orEmpty()
        if (topic.isNotEmpty() && !Ntfy.isValidTopic(topic)) {
            Toast.makeText(this, R.string.topic_invalid, Toast.LENGTH_LONG).show()
            return
        }

        val id = editingId ?: UUID.randomUUID().toString()
        val existing = if (editingId != null) {
            InstanceStore.load(this).firstOrNull { it.id == id }
        } else null
        val instance = existing ?: Instance(
            id = id, name = name, url = url,
            keepScreenOn = false, createdAt = System.currentTimeMillis(), lastOpenedAt = 0L,
        )
        instance.name = name
        instance.url = url
        instance.keepScreenOn = binding.switchKeepScreenOn.isChecked
        instance.ntfyTopic = topic.ifEmpty { null }
        InstanceStore.upsert(this, instance)
        // 新增/删除 topic 都要同步监听服务的连接
        TaskListenService.ensure(this)

        if (existing == null) {
            val web = WebActivity.intent(this, id, intent.getBooleanExtra(EXTRA_CLEAR_TOP, false))
            startActivity(web)
        }
        finish()
    }

    companion object {
        private const val EXTRA_ID = "id"
        private const val EXTRA_URL = "url"
        private const val EXTRA_NAME = "name"
        const val EXTRA_CLEAR_TOP = "clearTop"

        fun createIntent(context: Context, instanceId: String?, url: String?, name: String?): Intent =
            Intent(context, InstanceEditActivity::class.java).apply {
                putExtra(EXTRA_ID, instanceId)
                putExtra(EXTRA_URL, url)
                putExtra(EXTRA_NAME, name)
            }
    }
}
