# T7 交付物清单（task）

## Question

最终交付什么、放在哪？

## Resolution（closed 2026-09-21，全部就位）

- `dist/ZCodeRemote-v1.0.0-release.apk` — 647KB，apksigner 验签通过，可直接 sideload 安装
- `keystore/release.keystore` — 签名密钥（README 记录口令与更换方法）
- `README.md` — 安装步骤、两台电脑接入指南、功能与安全说明
- `scripts/emulator_e2e.sh` — 模拟器端到端验证脚本（可重复执行）
- `wayfinder/` — 决策地图（含 T8 构建环境故障与绕行记录）
- 源码工程 `app/` + Gradle wrapper，零第三方依赖，可复现构建
