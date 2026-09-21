# T9 App 内扫码绑定（decision + task）

## Question

主入口不该是「复制/分享链接」绕道浏览器——应在 App 内直接扫电脑端 ZCode「远程访问」的
绑定二维码，扫码后自动把页面存为实例并打开。扫码技术方案怎么选？

## MECE 备选（受 T8 约束：禁止带资源的 AAR 依赖）

| 方案 | 评估 |
| --- | --- |
| a) ML Kit Barcode / CameraX / zxing-android-embedded | 全是带 res 的 AAR → 撞 T8 管线故障；ML Kit 还依赖 GMS — 否 |
| b) 华为/微信开源扫码 SDK | 同为 AAR，体积大 — 否 |
| c) **zxing `core`（纯 Java JAR，零资源）+ 平台 camera2 + 自绘取景框** | JAR 不进资源链接管线，T8 无影响；camera2/TextureView 为平台 API；解码/权限/预览全自控 — ✓ |

## Resolution（2026-09-21）

选 **c)**：

- 新增 `ScanActivity`：camera2 预览（TextureView + 覆盖裁剪矩阵）+ ImageReader YUV 帧 →
  zxing `MultiFormatReader` 解码（QR only + TRY_HARDER，四个旋转方向轮询），单线程解码池 + 忙位防抖；
- 取景框自绘（半透明遮罩 + 中央方孔 + 描边），手电筒开关（有闪光灯时显示）；
- 载荷处理：`extractRemoteUrl`（支持纯 URL 与文本内嵌 URL）→ `Urls.sanitize`（仍仅 https）→
  **按 URL 去重**：已存在直接打开，否则自动命名保存并打开（扫完即用，粘贴作为兜底入口保留）；
- 相机权限运行时请求，拒绝态给说明 + 重新授权按钮，粘贴兜底始终可用；
- 非远程链接的二维码：提示原始载荷前缀（便于发现「绑定码非 URL」的格式变化）。

验证（2026-09-21）：
- zxing 解码管线 JVM 单测 **4/4 通过**（真实格式远程 URL 的 QR 生成→解码、旋转姿态、
  非 QR 源返回 null、纯文本/内嵌 URL 载荷提取）；
- 模拟器实测：主页「＋」→ 扫码页（预览 cover-crop、遮罩取景框、手电筒、粘贴兜底），
  截图 `screens/07_scan_preview.png`；权限拒绝态与重授权路径走通；
- 保存→打开路径与 T6 已验证的深链接路径同源复用。
