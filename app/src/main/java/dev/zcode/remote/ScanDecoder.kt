package dev.zcode.remote

import android.media.Image
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer

/** 二维码解码与载荷提取（单线程使用；decode 线程唯一）。 */
object ScanDecoder {

    private val reader = MultiFormatReader()

    init {
        reader.setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
            )
        )
    }

    /** 从 camera2 YUV_420_888 帧解码；对亮度数据做 90° 旋转重建源轮询四个朝向。调用方无需关闭 image。 */
    fun decodeFrame(image: Image): String? {
        val width = image.width
        val height = image.height
        val plane = image.planes[0]
        val buffer = plane.buffer
        val stride = plane.rowStride
        val data = if (stride == width) {
            ByteArray(width * height).also { buffer.get(it) }
        } else {
            val d = ByteArray(width * height)
            var pos = 0
            for (row in 0 until height) {
                buffer.position(row * stride)
                buffer.get(d, pos, width)
                pos += width
            }
            d
        }
        try {
            var d = data
            var w = width
            var h = height
            repeat(4) {
                val result = decodeLuminance(PlanarYUVLuminanceSource(d, w, h, 0, 0, w, h, false))
                if (result != null) return result
                val (rotated, dims) = rotate90(d, w, h)
                d = rotated
                w = dims.first
                h = dims.second
            }
            return null
        } finally {
            image.close()
        }
    }

    /** 顺时针旋转 90°（返回新数组与新 [宽, 高]）。 */
    fun rotate90(data: ByteArray, width: Int, height: Int): Pair<ByteArray, Pair<Int, Int>> {
        val out = ByteArray(data.size)
        for (y in 0 until height) {
            for (x in 0 until width) {
                out[x * height + (height - 1 - y)] = data[y * width + x]
            }
        }
        return out to (height to width)
    }

    /** 对单一朝向的亮度源解码一次。 */
    fun decodeLuminance(source: LuminanceSource): String? {
        return try {
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
        } catch (e: NotFoundException) {
            null
        } catch (e: Exception) {
            null
        } finally {
            reader.reset()
        }
    }

    /** 从二维码载荷中提取远程链接：纯 URL 直接返回，也支持文本内嵌 URL。 */
    fun extractRemoteUrl(text: String): String? {
        val t = text.trim()
        if (t.startsWith("https://", true) || t.startsWith("http://", true)) return t
        return Regex("https://\\S+").find(t)?.value
    }
}
