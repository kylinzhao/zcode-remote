package dev.zcode.remote

import android.annotation.SuppressLint
import android.animation.ValueAnimator
import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ProgressBar
import kotlin.math.abs

/**
 * 零依赖下拉刷新容器。androidx 的 SwipeRefreshLayout 是带资源的 AAR，
 * 会进资源链接管线（wayfinder/T8 零资源红线），故用平台控件手搓。
 * Chrome 式：只出圆形进度，不出文字。
 *
 * XML 里放一个内容 View（WebView）和一个圆形 ProgressBar
 * （style=Widget.Material.ProgressBar，layout_gravity=top|center_horizontal），
 * 代码里 [setup] 绑定后即可用。内容滚到顶时下拉出现指示器，
 * 松手超过阈值触发回调；加载方完成后调 [setRefreshing](false) 收起。
 */
class PullRefreshLayout @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : FrameLayout(context, attrs) {

    private lateinit var target: View
    private lateinit var spinner: ProgressBar
    var onRefresh: (() -> Unit)? = null

    private val density = resources.displayMetrics.density
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val triggerDistance = 72f * density   // 触发刷新所需的显示位移
    private val maxDrag = 110f * density         // 可拉到的最大显示位移
    private val restOffset = 56f * density       // 刷新期间内容停留的位移

    private var refreshing = false
    private var dragging = false
    private var activePointerId = MotionEvent.INVALID_POINTER_ID
    private var downX = 0f
    private var downY = 0f
    private var lastY = 0f
    private var offset = 0f
    private var settleAnimator: ValueAnimator? = null
    // 页面卡死时 onLoadFinished 永远不来，超时兜底收起指示器
    private val refreshTimeout = Runnable { finishRefresh() }

    fun setup(target: View, spinner: ProgressBar, onRefresh: () -> Unit) {
        this.target = target
        this.spinner = spinner
        this.onRefresh = onRefresh
        applyOffset()
    }

    fun setRefreshing(active: Boolean) {
        if (active) beginRefresh() else finishRefresh()
    }

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        if (refreshing || !::target.isInitialized) return false
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> onDown(ev)
            MotionEvent.ACTION_MOVE -> maybeStartDrag(ev)
            else -> Unit
        }
        return dragging
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(ev: MotionEvent): Boolean {
        // 子 View 没消费事件时手势直接落到这里，与拦截路径共用一套拖拽逻辑
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> onDown(ev)
            MotionEvent.ACTION_MOVE -> {
                maybeStartDrag(ev)
                if (dragging) dragTo(ev)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> release(ev)
        }
        return true
    }

    private fun onDown(ev: MotionEvent) {
        activePointerId = ev.getPointerId(0)
        downX = ev.x
        downY = ev.y
        lastY = ev.y
        dragging = false
        settleAnimator?.cancel()
    }

    private fun maybeStartDrag(ev: MotionEvent) {
        if (dragging || ev.pointerCount != 1) return
        val index = ev.findPointerIndex(activePointerId)
        if (index < 0) return
        val dx = ev.getX(index) - downX
        val dy = ev.getY(index) - downY
        // 竖直向下、且内容已在顶部时才接管手势
        if (dy > touchSlop && dy > abs(dx) && !target.canScrollVertically(-1)) {
            dragging = true
            lastY = ev.getY(index)
        }
    }

    private fun dragTo(ev: MotionEvent) {
        val index = ev.findPointerIndex(activePointerId)
        if (index < 0) return
        offset = (offset + (ev.getY(index) - lastY) * DRAG_RATE).coerceIn(0f, maxDrag)
        lastY = ev.getY(index)
        applyOffset()
    }

    private fun release(ev: MotionEvent) {
        activePointerId = MotionEvent.INVALID_POINTER_ID
        if (!dragging) return
        dragging = false
        if (ev.actionMasked == MotionEvent.ACTION_UP && offset >= triggerDistance) {
            beginRefresh()
        } else {
            settleTo(0f)
        }
    }

    private fun beginRefresh() {
        if (refreshing) return
        refreshing = true
        spinner.isIndeterminate = true
        settleTo(restOffset)
        postDelayed(refreshTimeout, REFRESH_TIMEOUT_MS)
        onRefresh?.invoke()
    }

    private fun finishRefresh() {
        removeCallbacks(refreshTimeout)
        if (!refreshing && offset <= 0f) return
        refreshing = false
        spinner.isIndeterminate = false
        settleTo(0f)
    }

    private fun settleTo(targetOffset: Float) {
        settleAnimator?.cancel()
        settleAnimator = ValueAnimator.ofFloat(offset, targetOffset).apply {
            duration = 250
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                offset = it.animatedValue as Float
                applyOffset()
            }
            start()
        }
    }

    private fun applyOffset() {
        if (!::target.isInitialized) return
        target.translationY = offset
        if (::spinner.isInitialized) {
            // 指示器藏于内容顶边之上，随下拉同步露出
            spinner.translationY = offset - spinner.top - spinner.height
            spinner.progress = (offset / triggerDistance).coerceIn(0f, 1f).let { (it * 100).toInt() }
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        // setup 早于首帧布局，此处才能拿到 spinner 真实尺寸，把指示器归位到顶边之外
        applyOffset()
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(refreshTimeout)
        super.onDetachedFromWindow()
    }

    private companion object {
        const val DRAG_RATE = 0.65f
        const val REFRESH_TIMEOUT_MS = 20_000L
    }
}
