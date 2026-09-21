package dev.zcode.remote

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.util.AttributeSet
import android.view.View

/** 扫码取景框：半透明遮罩 + 中央方孔 + 描边。 */
class ScanBoxView(context: Context, attrs: AttributeSet?) : View(context, attrs) {

    private val dimPaint = Paint().apply { color = 0x99000000.toInt() }
    private val erasePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
    }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = 0xFF5A67F2.toInt()
        strokeWidth = resources.displayMetrics.density * 3f
    }
    private val cornerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.WHITE
        strokeWidth = resources.displayMetrics.density * 4f
        strokeCap = Paint.Cap.ROUND
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val density = resources.displayMetrics.density
        val side = (width * 0.72f).coerceAtMost(height * 0.5f)
        val left = (width - side) / 2f
        val top = (height - side) / 2f - 40f * density
        val right = left + side
        val bottom = top + side

        val layer = canvas.saveLayer(0f, 0f, width.toFloat(), height.toFloat(), null)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), dimPaint)
        canvas.drawRect(left, top, right, bottom, erasePaint)
        canvas.restoreToCount(layer)

        canvas.drawRect(left, top, right, bottom, strokePaint)

        // 四角短亮线
        val corner = side * 0.12f
        listOf(
            floatArrayOf(left, top, corner, 0f, 0f, corner),
            floatArrayOf(right, top, -corner, 0f, 0f, corner),
            floatArrayOf(left, bottom, corner, 0f, 0f, -corner),
            floatArrayOf(right, bottom, -corner, 0f, 0f, -corner),
        ).forEach { c ->
            canvas.drawLine(c[0], c[1], c[0] + c[2], c[1] + c[3], cornerPaint)
            canvas.drawLine(c[0], c[1], c[0] + c[4], c[1] + c[5], cornerPaint)
        }
    }
}
