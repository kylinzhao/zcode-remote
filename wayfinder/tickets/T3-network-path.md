# T3 网络路径与部署形态（decision）

## Question

手机与两台电脑之间的网络通路怎么解决？客户端要不要内置组网能力？

## MECE 备选

- a) 同一局域网直连：家里/公司不同网即失效；公司网常隔离 — 否
- b) 端口转发 + DDNS：把家用电脑暴露公网，安全面大、配置繁 — 否
- c) 组网 VPN（Tailscale/ZeroTier）：通用兜底方案 — 备用，不内置
- d) **ZCode 云中继（实测存在）**：桌面端扫码 URL 经 zcode.z.ai 中继，公网可达、零配置 — ✓

## Resolution（closed 2026-09-21）

采用 **d)**：云中继由 ZCode 桌面端负责，客户端零组网逻辑。App 设计为「任意 https URL 皆可添加」，
未来若桌面端提供局域网模式或用户走 Tailscale(备选 c)，无需改 App 即可纳入。
