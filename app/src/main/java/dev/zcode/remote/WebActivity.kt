package dev.zcode.remote

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.webkit.SslErrorHandler
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.PopupMenu
import android.widget.Toast
import dev.zcode.remote.databinding.ActivityWebBinding

class WebActivity : Activity() {

    private lateinit var binding: ActivityWebBinding
    private var instance: Instance? = null
    private var resumed = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityWebBinding.inflate(layoutInflater)
        setContentView(binding.root)

        val id = intent.getStringExtra(EXTRA_ID)
        instance = id?.let { target -> InstanceStore.load(this).firstOrNull { it.id == target } }
        if (instance == null) {
            finish(); return
        }
        instance?.let {
            it.lastOpenedAt = System.currentTimeMillis()
            InstanceStore.upsert(this, it)
        }

        binding.btnBack.setOnClickListener { finish() }
        binding.btnMore.setOnClickListener { anchor ->
            val popup = PopupMenu(this, anchor)
            popup.menuInflater.inflate(R.menu.menu_web, popup.menu)
            popup.setOnMenuItemClickListener { menuItem ->
                when (menuItem.itemId) {
                    R.id.action_add -> {
                        // 从页面内添加新实例：扫完/存完用 CLEAR_TOP 复用本页切换到新实例，返回栈保持 列表→页面
                        startActivity(
                            Intent(this, ScanActivity::class.java)
                                .putExtra(ScanActivity.EXTRA_CLEAR_TOP, true)
                        )
                        true
                    }
                    R.id.action_refresh -> { hideError(); binding.web.reload(); true }
                    R.id.action_browser -> { openExternally(instance?.url ?: ""); true }
                    R.id.action_copy -> { copyUrl(); true }
                    R.id.action_edit -> {
                        instance?.let {
                            startActivity(
                                InstanceEditActivity.createIntent(this, instanceId = it.id, url = null, name = null)
                            )
                        }
                        true
                    }
                    R.id.action_delete -> {
                        instance?.let {
                            InstanceStore.remove(this, it.id)
                            finish()
                        }
                        true
                    }
                    else -> false
                }
            }
            popup.show()
        }
        binding.btnRetry.setOnClickListener {
            hideError()
            instance?.let { binding.web.loadUrl(it.url) }
        }
        // 下拉刷新：页面卡死时的就地恢复手段
        binding.pull.setup(binding.web, binding.refreshSpinner) {
            hideError()
            binding.web.reload()
        }

        configureWebView()
        applyInstanceState()
        binding.web.loadUrl(instance!!.url)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        // 用户正在看这台电脑，红点与提醒就地消化
        instance?.let {
            InstanceStore.clearDone(this, it.id)
            Notifier.cancel(this, it.id)
        }
        // 编辑页可能改了名称/常亮开关/网址，回来时同步
        val id = instance?.id ?: return
        val fresh = InstanceStore.load(this).firstOrNull { it.id == id } ?: run {
            finish(); return
        }
        val old = instance
        instance = fresh
        applyInstanceState()
        LastPage.markPage(this, fresh.id)
        if (old != null && old.url != fresh.url && binding.error.visibility != View.VISIBLE) {
            binding.web.loadUrl(fresh.url)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        val fresh = InstanceStore.load(this).firstOrNull { it.id == id } ?: return
        val switched = fresh.id != instance?.id
        instance = fresh
        applyInstanceState()
        LastPage.markPage(this, fresh.id)
        if (switched) {
            hideError()
            binding.web.loadUrl(fresh.url)
        }
    }

    override fun onBackPressed() {
        val web = binding.web
        when {
            binding.error.visibility == View.VISIBLE -> finish()
            web.canGoBack() -> web.goBack()
            else -> super.onBackPressed()
        }
    }

    private fun applyInstanceState() {
        val instance = this.instance ?: return
        binding.tvTitle.text = instance.name
        binding.tvHost.text = runCatching { Uri.parse(instance.url).host }.getOrNull().orEmpty()
        if (instance.keepScreenOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView() {
        val web = binding.web
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            useWideViewPort = true
            loadWithOverviewMode = true
            builtInZoomControls = true
            displayZoomControls = false
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        web.setBackgroundColor(android.graphics.Color.TRANSPARENT)
        web.addJavascriptInterface(TaskBridge(), DetectorJs.BRIDGE_NAME)

        web.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                // 页面脚本执行前注入检测器（包一层 WebSocket 统计流量）
                view.evaluateJavascript(DetectorJs.source, null)
            }

            override fun onPageFinished(view: WebView, url: String) {
                binding.pull.setRefreshing(false)
                // 兜底：脚本内幂等，重复注入无害
                view.evaluateJavascript(DetectorJs.source, null)
            }

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val scheme = request.url.scheme?.lowercase()
                return when (scheme) {
                    "https" -> false // 站内继续用 WebView 加载（保持会话）
                    "http" -> {
                        Toast.makeText(this@WebActivity, R.string.toast_not_supported, Toast.LENGTH_SHORT).show()
                        true
                    }
                    "mailto", "tel", "sms", "geo", "intent" -> {
                        openExternally(request.url.toString())
                        true
                    }
                    else -> true
                }
            }

            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                // 安全策略：一律不放行证书错误
                handler.cancel()
                binding.pull.setRefreshing(false)
                showError(getString(R.string.error_ssl))
            }

            override fun onReceivedError(
                view: WebView, request: WebResourceRequest, error: WebResourceError
            ) {
                if (request.isForMainFrame) {
                    binding.pull.setRefreshing(false)
                    showError(getString(R.string.error_network))
                }
            }

            override fun onReceivedHttpError(
                view: WebView, request: WebResourceRequest, errorResponse: WebResourceResponse
            ) {
                if (request.isForMainFrame) {
                    binding.pull.setRefreshing(false)
                    showError(getString(R.string.error_http, errorResponse.statusCode))
                }
            }
        }
        web.setDownloadListener { url, _, _, _, _ ->
            if (url.isNotBlank()) openExternally(url)
        }
        web.webChromeClient = object : android.webkit.WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                binding.progress.visibility =
                    if (newProgress < 100 && binding.error.visibility != View.VISIBLE) View.VISIBLE
                    else View.GONE
            }
        }
    }

    /** 供注入脚本回调：检测到任务结束且用户不在场。 */
    private inner class TaskBridge {
        @JavascriptInterface
        fun onTaskFinished(payload: String) {
            val target = instance ?: return
            if (resumed) return // 双保险：页面认为不可见但本页其实在前台
            runOnUiThread {
                InstanceStore.markDone(this@WebActivity, target.id)
                Notifier.post(this@WebActivity, target.id, target.name)
            }
        }
    }

    private fun showError(message: String) {
        binding.errorMsg.text = message
        binding.error.visibility = View.VISIBLE
        binding.progress.visibility = View.GONE
    }

    private fun hideError() {
        binding.error.visibility = View.GONE
    }

    private fun openExternally(url: String) {
        if (url.isBlank()) return
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(this, R.string.toast_not_supported, Toast.LENGTH_SHORT).show()
        }
    }

    private fun copyUrl() {
        val url = instance?.url ?: return
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("url", url))
        if (Build.VERSION.SDK_INT < 33) {
            Toast.makeText(this, R.string.copied, Toast.LENGTH_SHORT).show()
        }
    }

    override fun onPause() {
        resumed = false
        instance?.let {
            InstanceStore.upsert(this, it)
            LastPage.markPage(this, it.id)
        }
        super.onPause()
    }

    override fun onDestroy() {
        binding.web.apply {
            loadUrl("about:blank")
            onPause()
            destroy()
        }
        super.onDestroy()
    }

    companion object {
        private const val EXTRA_ID = "id"

        fun intent(context: Context, instanceId: String, clearTop: Boolean = false): Intent =
            Intent(context, WebActivity::class.java).putExtra(EXTRA_ID, instanceId).apply {
                if (clearTop) {
                    addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                }
            }
    }
}
