package dev.zcode.remote

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Matrix
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.Toast
import dev.zcode.remote.databinding.ActivityScanBinding
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** 应用内扫码：对准电脑端 ZCode「远程访问」二维码，识别后自动保存实例并打开。 */
class ScanActivity : Activity(), TextureView.SurfaceTextureListener {

    private lateinit var binding: ActivityScanBinding

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var requestBuilder: CaptureRequest.Builder? = null
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null
    private var previewSize: Size? = null

    private var surfaceReady = false
    private var viewSize = intArrayOf(0, 0)
    private val decoding = AtomicBoolean(false)
    private val decodePool: ExecutorService = Executors.newSingleThreadExecutor()
    private var settled = false
    private var torchOn = false
    /** 从 WebActivity 菜单进入时为 true：扫完用 CLEAR_TOP 复用调用方页面切换实例。 */
    private val clearTop: Boolean
        get() = intent?.getBooleanExtra(EXTRA_CLEAR_TOP, false) ?: false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityScanBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.btnBack.setOnClickListener { finish() }
        binding.btnPaste.setOnClickListener {
            val edit = InstanceEditActivity.createIntent(this, instanceId = null, url = null, name = null)
            if (clearTop) edit.putExtra(InstanceEditActivity.EXTRA_CLEAR_TOP, true)
            startActivity(edit)
            finish()
        }
        binding.btnTorch.setOnClickListener { toggleTorch() }
        binding.btnGrant.setOnClickListener { requestCameraPermission() }
        binding.textureView.surfaceTextureListener = this
        if (binding.textureView.isAvailable) {
            // 表面早已就绪（权限弹窗等场景），手动触发一次
            binding.textureView.surfaceTexture?.let {
                onSurfaceTextureAvailable(it, binding.textureView.width, binding.textureView.height)
            }
        }

        if (hasCameraPermission()) {
            startCameraIfSurfaceReady()
        } else {
            requestCameraPermission()
        }
    }

    // ---------- 权限 ----------

    private fun hasCameraPermission(): Boolean =
        checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun requestCameraPermission() {
        requestPermissions(arrayOf(Manifest.permission.CAMERA), RC_CAMERA)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RC_CAMERA) {
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                binding.permissionTip.visibility = View.GONE
                startCameraIfSurfaceReady()
            } else {
                binding.permissionTip.visibility = View.VISIBLE
            }
        }
    }

    // ---------- 预览表面 ----------

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        surfaceReady = true
        viewSize[0] = width
        viewSize[1] = height
        if (hasCameraPermission()) startCameraIfSurfaceReady()
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
        viewSize[0] = width
        viewSize[1] = height
        previewSize?.let { applyPreviewTransform(it, width, height) }
    }

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        surfaceReady = false
        stopCamera()
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit

    // ---------- 相机 ----------

    private fun startCameraIfSurfaceReady() {
        if (!surfaceReady || cameraDevice != null) return
        val texture = binding.textureView.surfaceTexture ?: return
        startCamera(texture, viewSize[0], viewSize[1])
    }

    @SuppressLint("MissingPermission")
    private fun startCamera(texture: SurfaceTexture, viewW: Int, viewH: Int) {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = pickCamera(manager) ?: run {
            Toast.makeText(this, getString(R.string.scan_error, "无可用相机"), Toast.LENGTH_LONG).show()
            return
        }
        val chars = manager.getCameraCharacteristics(cameraId)
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return

        val preview = map.getOutputSizes(SurfaceTexture::class.java)
            .filter { it.width <= 1280 }
            .maxByOrNull { it.width * it.height } ?: Size(1280, 720)
        val analyze = map.getOutputSizes(ImageFormat.YUV_420_888)
            .filter { it.width <= 1280 }
            .maxByOrNull { it.width * it.height } ?: Size(640, 480)
        previewSize = preview
        texture.setDefaultBufferSize(preview.width, preview.height)
        applyPreviewTransform(preview, viewW, viewH)

        val hasFlash = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        binding.btnTorch.visibility = if (hasFlash) View.VISIBLE else View.GONE

        cameraThread = HandlerThread("scan-camera").also { it.start() }
        cameraHandler = Handler(cameraThread!!.looper)

        val reader = ImageReader.newInstance(analyze.width, analyze.height, ImageFormat.YUV_420_888, 2)
        reader.setOnImageAvailableListener(onImageAvailable, cameraHandler)
        imageReader = reader

        try {
            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    cameraDevice = device
                    createSession(device, Surface(texture), reader)
                }

                override fun onDisconnected(device: CameraDevice) {
                    device.close(); if (cameraDevice === device) cameraDevice = null
                }

                override fun onError(device: CameraDevice, error: Int) {
                    device.close(); if (cameraDevice === device) cameraDevice = null
                    runOnUiThread {
                        Toast.makeText(this@ScanActivity, getString(R.string.scan_error, "code=$error"), Toast.LENGTH_LONG).show()
                    }
                }
            }, cameraHandler)
        } catch (e: SecurityException) {
            Toast.makeText(this, getString(R.string.scan_error, e.message ?: "permission"), Toast.LENGTH_LONG).show()
        }
    }

    private fun createSession(device: CameraDevice, previewSurface: Surface, reader: ImageReader) {
        try {
            val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(previewSurface)
                addTarget(reader.surface)
            }
            requestBuilder = builder
            device.createCaptureSession(listOf(previewSurface, reader.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (cameraDevice !== device) return
                        captureSession = session
                        session.setRepeatingRequest(builder.build(), null, cameraHandler)
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        runOnUiThread {
                            Toast.makeText(this@ScanActivity, getString(R.string.scan_error, "session"), Toast.LENGTH_LONG).show()
                        }
                    }
                }, cameraHandler)
        } catch (e: Exception) {
            Toast.makeText(this, getString(R.string.scan_error, e.message ?: "capture"), Toast.LENGTH_LONG).show()
        }
    }

    private fun stopCamera() {
        try { captureSession?.close() } catch (e: Exception) {}
        try { cameraDevice?.close() } catch (e: Exception) {}
        try { imageReader?.close() } catch (e: Exception) {}
        captureSession = null
        cameraDevice = null
        imageReader = null
        requestBuilder = null
        torchOn = false
        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null
    }

    private fun pickCamera(manager: CameraManager): String? {
        val ids = manager.cameraIdList
        return ids.firstOrNull {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: ids.firstOrNull()
    }

    private fun applyPreviewTransform(preview: Size, viewW: Int, viewH: Int) {
        if (viewW == 0 || viewH == 0) return
        val rotation = windowManager.defaultDisplay.rotation
        val swapped = rotation == Surface.ROTATION_90 || rotation == Surface.ROTATION_270
        // 缓冲区映射到屏幕后的有效宽高（竖屏时横竖互换）
        val bufferW = if (swapped) preview.height.toFloat() else preview.width.toFloat()
        val bufferH = if (swapped) preview.width.toFloat() else preview.height.toFloat()

        val matrix = Matrix()
        val viewRect = RectF(0f, 0f, viewW.toFloat(), viewH.toFloat())
        val centerX = viewRect.centerX()
        val centerY = viewRect.centerY()
        // cover-crop：铺满视图、居中裁剪
        val bufferRect = RectF(0f, 0f, bufferW, bufferH)
        bufferRect.offset(centerX - bufferRect.centerX(), centerY - bufferRect.centerY())
        matrix.setRectToRect(viewRect, bufferRect, Matrix.ScaleToFit.FILL)
        val scale = maxOf(viewW / bufferW, viewH / bufferH)
        matrix.postScale(scale, scale, centerX, centerY)
        when (rotation) {
            Surface.ROTATION_90 -> matrix.postRotate(90f, centerX, centerY)
            Surface.ROTATION_180 -> matrix.postRotate(180f, centerX, centerY)
            Surface.ROTATION_270 -> matrix.postRotate(270f, centerX, centerY)
        }
        binding.textureView.setTransform(matrix)
    }

    private fun toggleTorch() {
        val session = captureSession ?: return
        val builder = requestBuilder ?: return
        torchOn = !torchOn
        builder.set(
            CaptureRequest.FLASH_MODE,
            if (torchOn) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF
        )
        runCatching { session.setRepeatingRequest(builder.build(), null, cameraHandler) }
    }

    // ---------- 解码 ----------

    private val onImageAvailable = ImageReader.OnImageAvailableListener {
        if (settled || !decoding.compareAndSet(false, true)) return@OnImageAvailableListener
        val image = try { it.acquireLatestImage() } catch (e: Exception) { null }
        if (image == null) {
            decoding.set(false)
            return@OnImageAvailableListener
        }
        decodePool.execute {
            try {
                val text = ScanDecoder.decodeFrame(image)
                if (text != null) runOnUiThread { onDecoded(text) }
            } catch (e: Exception) {
                // 帧异常直接丢弃
            } finally {
                decoding.set(false)
            }
        }
    }

    private fun onDecoded(text: String) {
        if (settled) return
        val url = ScanDecoder.extractRemoteUrl(text)?.let { Urls.sanitize(it) }
        if (url == null) {
            // 非远程链接：提示载荷前缀，继续扫
            Toast.makeText(this, getString(R.string.scan_invalid, text.take(24)), Toast.LENGTH_LONG).show()
            return
        }
        settled = true
        stopCamera()

        val existing = InstanceStore.load(this).firstOrNull { it.url == url }
        val instance = existing ?: run {
            val created = Instance(
                id = java.util.UUID.randomUUID().toString(),
                name = Urls.suggestName(url) ?: getString(R.string.app_name),
                url = url,
                keepScreenOn = false,
                createdAt = System.currentTimeMillis(),
                lastOpenedAt = 0L,
            )
            InstanceStore.upsert(this, created)
            created
        }
        Toast.makeText(
            this,
            if (existing == null) R.string.scan_added else R.string.scan_exists,
            Toast.LENGTH_SHORT
        ).show()
        startActivity(WebActivity.intent(this, instance.id, clearTop))
        finish()
    }

    override fun onResume() {
        super.onResume()
        if (hasCameraPermission()) {
            binding.permissionTip.visibility = View.GONE
            startCameraIfSurfaceReady()
        } else if (shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)) {
            binding.permissionTip.visibility = View.VISIBLE
        }
    }

    override fun onPause() {
        stopCamera()
        super.onPause()
    }

    override fun onDestroy() {
        decodePool.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val RC_CAMERA = 41
        const val EXTRA_CLEAR_TOP = "clearTop"
    }
}
