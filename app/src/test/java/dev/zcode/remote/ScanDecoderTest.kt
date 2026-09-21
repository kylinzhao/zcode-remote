package dev.zcode.remote

import com.google.zxing.BarcodeFormat
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ScanDecoderTest {

    private fun makeQrSource(text: String, side: Int = 400): RGBLuminanceSource {
        val matrix = QRCodeWriter().encode(
            text, BarcodeFormat.QR_CODE, side, side, mapOf(EncodeHintType.MARGIN to 4)
        )
        val w = matrix.width
        val h = matrix.height
        val pixels = IntArray(w * h) { i ->
            if (matrix.get(i % w, i / w)) 0xFF000000.toInt() else 0xFFFFFFFF.toInt()
        }
        return RGBLuminanceSource(w, h, pixels)
    }

    @Test
    fun `decodes generated qr of remote url`() {
        val url = "https://zcode.z.ai/remote/v4?sid=d_test&hash=DJ%2Fxe%3D&t=1789986603105" +
            "&mid=00000000-0000-0000-0000-000000000000&name=MacBook-Air-57.local&app_version=3.14.0"
        assertEquals(url, ScanDecoder.decodeLuminance(makeQrSource(url)))
    }

    @Test
    fun `decodes rotated qr`() {
        val url = "https://zcode.z.ai/remote/v4?sid=rot&hash=abc"
        val src = makeQrSource(url)
        // RGBLuminanceSource 不支持就地旋转，手动顺时针旋转亮度数组（新宽 = 旧高）
        val w = src.width
        val h = src.height
        val rotatedPixels = IntArray(w * h) { i ->
            val x = i / h
            val y = h - 1 - (i % h)
            val v = src.matrix[y * w + x].toInt() and 0xFF
            0xFF000000.toInt() or (v shl 16) or (v shl 8) or v
        }
        val decoded = ScanDecoder.decodeLuminance(RGBLuminanceSource(h, w, rotatedPixels))
        assertEquals(url, decoded)
    }

    @Test
    fun `non qr source returns null`() {
        val blank = RGBLuminanceSource(200, 200, IntArray(200 * 200) { 0xFFFFFFFF.toInt() })
        assertNull(ScanDecoder.decodeLuminance(blank))
    }

    @Test
    fun `extracts url from plain and embedded payloads`() {
        val url = "https://zcode.z.ai/remote/v4?sid=1&hash=2"
        assertEquals(url, ScanDecoder.extractRemoteUrl(url))
        assertEquals(url, ScanDecoder.extractRemoteUrl("请打开：$url 连接电脑"))
        assertNull(ScanDecoder.extractRemoteUrl("hello world"))
    }
}
