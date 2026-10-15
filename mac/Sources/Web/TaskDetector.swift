import Foundation
import UserNotifications

/// 注入远程页（zcode.z.ai/remote）的脚本：任务结束检测 + 下拉刷新防误触探测。
///
/// 任务结束检测原理：relay 传输是多层二进制协议，无法可靠解析；但任务流式执行时页面
/// WebSocket 的字节流量持续处于高位，结束后回落到只剩心跳（约 10s 一次、几十字节）。
/// 本脚本包一层 window.WebSocket 统计流量，「持续高位 → 回落且页面不可见」即判定
/// 任务结束，postMessage 通知 native。对协议升级、界面改版免疫。
/// 异常中断：进入「有任务」后连接断开（3s 内无自动重连），上报 {interrupted:true}——
/// 正常收尾不会有 close，执行中掉线即异常；native 据此发「任务中断」而非「已结束」。
/// payload 区分：{watchedMs:N}=正常结束；{interrupted:true}=执行中断连，任务状态未知。
///
/// 下拉刷新探测段在 mac 上无消费者（无 UIRefreshControl 对应物，见 mac/CONTRACT.md ③），
/// 仅保留脚本本体与 zcodePullGate handler 兑现桥协议，native 侧收到后不做任何事。
///
/// 注意：iOS / Android（DetectorJs.kt）持有同一份脚本的同步副本，改一处要同步三处。
enum TaskDetector {
    static let messageHandlerName = "zcodeTaskDone"
    static let pullGateHandlerName = "zcodePullGate"

    static let source = """
        (function () {
          if (window.__zcTaskDetector) return 'already';
          window.__zcTaskDetector = true;
          var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers['\(messageHandlerName)'];
          if (!bridge || typeof bridge.postMessage !== 'function') return 'no-bridge';
          var pullBridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers['\(pullGateHandlerName)'];
          function notifyPullGate(blocked) {
            if (pullBridge) { try { pullBridge.postMessage(blocked ? 1 : 0); } catch (e) {} }
          }
          var OrigWS = window.WebSocket;
          if (!OrigWS) return 'no-ws';

          // —— 阈值：每秒收包字节数判定 ——
          var TICK_MS = 1000;        // 统计窗口
          var HIGH_BYTES = 2048;     // 窗口内收到这么多字节视为「执行中」流量
          var ARM_MS = 15000;        // 高位需持续这么久才进入「有任务」状态（过滤翻历史等突发）
          var QUIET_MS = 6000;       // 「有任务」后需连续安静这么久才判定结束（过滤网络抖动）
          var GRACE_MS = 3000;       // 断连后等这么久排除页面自动重连，再定性为异常中断

          var bytesInWindow = 0;
          var highSince = 0;         // 本次连续高位起点，0 = 当前不是高位
          var armedAt = 0;           // 进入「有任务」状态的时刻
          var armed = false;
          var quietSince = 0;        // 回落后的安静起点
          var resolved = false;      // 本轮任务是否已出结果（已通知或用户在场看到）
          var openSockets = 0;
          var lastHighAt = 0;        // 最近一次高位窗口的时刻，断连时区分「执行中断」与「结束后断」
          var interruptTimer = 0;

          function sizeOf(data) {
            if (typeof data === 'string') return data.length;
            if (data && typeof data.size === 'number') return data.size;
            if (data && typeof data.byteLength === 'number') return data.byteLength;
            return 0;
          }

          function reset() {
            armed = false; resolved = false;
            highSince = 0; armedAt = 0; quietSince = 0;
            if (interruptTimer) { clearTimeout(interruptTimer); interruptTimer = 0; }
          }

          function onTick() {
            var now = Date.now();
            var high = bytesInWindow >= HIGH_BYTES && openSockets > 0;
            bytesInWindow = 0;
            if (high) {
              quietSince = 0;
              lastHighAt = now;
              if (!highSince) {
                highSince = now;
                if (resolved) { armed = false; resolved = false; } // 安静后流量再起 = 新一轮任务
              }
              if (!armed && now - highSince >= ARM_MS) {
                armed = true; armedAt = now; resolved = false;
              }
            } else {
              highSince = 0;
              if (armed && !resolved) {
                if (!quietSince) quietSince = now;
                if (now - quietSince >= QUIET_MS && openSockets > 0) {
                  resolved = true;
                  // 页面不可见（用户没在盯）才提醒；否则视为用户亲眼看到结束
                  if (document.hidden) {
                    try {
                      bridge.postMessage(JSON.stringify({ watchedMs: now - armedAt }));
                      console.info('[zc-task-detector] task finished, notified');
                    } catch (e) { /* bridge 不可用即放弃 */ }
                  }
                }
              }
            }
          }

          function ZcWebSocket(url, protocols) {
            var ws = protocols === undefined ? new OrigWS(url) : new OrigWS(url, protocols);
            ws.addEventListener('open', function () {
              openSockets += 1;
              if (interruptTimer) { clearTimeout(interruptTimer); interruptTimer = 0; } // 自动重连成功，不算中断
            });
            ws.addEventListener('close', function () {
              openSockets = Math.max(0, openSockets - 1);
              if (openSockets > 0) return;
              if (armed && !resolved && !interruptTimer) {
                // 执行中连接断开：正常收尾不会有 close。等一小段排除自动重连，
                // 仍无连接则定性——最近还有高位流量=执行中断，安静已久=结束但没赶上判定
                interruptTimer = setTimeout(function () {
                  interruptTimer = 0;
                  if (!armed || resolved || openSockets > 0) return;
                  var interrupted = Date.now() - lastHighAt < QUIET_MS;
                  resolved = true;
                  if (document.hidden) {
                    try {
                      bridge.postMessage(JSON.stringify(
                        interrupted ? { interrupted: true } : { watchedMs: Date.now() - armedAt }));
                    } catch (e) { /* bridge 不可用即放弃 */ }
                  }
                  reset();
                }, GRACE_MS);
              } else {
                reset();
              }
            });
            ws.addEventListener('error', function () {});
            ws.addEventListener('message', function (ev) { bytesInWindow += sizeOf(ev.data); });
            return ws;
          }
          ZcWebSocket.prototype = OrigWS.prototype;
          ZcWebSocket.CONNECTING = OrigWS.CONNECTING;
          ZcWebSocket.OPEN = OrigWS.OPEN;
          ZcWebSocket.CLOSING = OrigWS.CLOSING;
          ZcWebSocket.CLOSED = OrigWS.CLOSED;
          window.WebSocket = ZcWebSocket;

          setInterval(onTick, TICK_MS);

          // —— 下拉刷新防误触探测（双端 BODY 同步块，勿单边改动）——
          // 触点命中「还能向上滚」的内层容器（overflowY 可滚且 scrollTop>0）时，
          // 本次手势是内容滚动而非下拉刷新，探测结果交给 native 决定是否放行。
          document.addEventListener('touchstart', function (e) {
            var t = e.touches[0];
            if (!t) return;
            var el = document.elementFromPoint(t.clientX, t.clientY);
            var blocked = false;
            for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
              var oy = getComputedStyle(n).overflowY;
              if ((oy === 'auto' || oy === 'scroll' || oy === 'overlay') && n.scrollTop > 0) {
                blocked = true; break;
              }
            }
            notifyPullGate(blocked);
          }, { capture: true, passive: true });

          return 'ok';
        })();
        """
}

/// 任务结束提醒的 native 侧（mac）：可见性判定、Dock 角标与本地通知。
/// UserNotifications 在 macOS 同样可用；红点数据走 InstanceStore.unreadDone（列表 UI 由界面模块消费）。
/// appActive 由 App 入口按 scenePhase 维护、回前台时调 syncBadge（iOS ZCodeRemoteApp.swift 同构，mac 归界面模块）。
/// 通道二（ntfy 推送）到达也走这里：PushListener 解析后调 handlePush，通知相关逻辑仍收敛在本类型。
@MainActor
enum TaskDone {
    /// 远程页面容器是否在窗口层级里（WebScreen 出现/消失维护）。
    static var pageVisible = false
    /// 当前处于窗口层级的远程页是哪个实例（与 pageVisible 同源维护）。
    /// 通道二推送到达时用于判断「用户是否正盯着这台电脑」——别对正在看的人弹提醒。
    static var visibleInstanceID: UUID?
    /// App 是否在前台（App 入口 scenePhase 维护）。
    static var appActive = true

    static var userWatching: Bool { pageVisible && appActive }

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    /// 检测脚本上报：任务结束（interrupted=执行中连接断开，任务状态未知）。用户在场时视为亲眼看到，不打扰。
    static func handleFinished(instanceID: UUID, interrupted: Bool = false) {
        guard !userWatching else { return }
        let store = InstanceStore.shared
        guard store.instance(instanceID) != nil else { return }
        store.markDone(instanceID)
        syncBadge()
        postNotification(instanceID: instanceID, interrupted: interrupted)
    }

    /// 通道二（ntfy 推送）到达。电脑端 hook 已带文案（标题=主机·项目、正文=摘要，失败带 ❌），直接
    /// 透传显示（Android Notifier 同构）。与 Android 的差异一处：用户正盯着这台电脑的页面时不重复
    /// 打扰——沿用通道一「在场视为亲眼看到」的策略；空文案兜底本地默认文案。
    static func handlePush(instanceID: UUID, title: String, body: String) {
        guard let instance = InstanceStore.shared.instance(instanceID) else { return }
        if userWatching, visibleInstanceID == instanceID { return }
        InstanceStore.shared.markDone(instanceID)
        syncBadge()
        let content = UNMutableNotificationContent()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = t.isEmpty ? "ZCode 任务已结束" : t
        content.body = b.isEmpty ? "「\(instance.name)」的任务执行完毕，打开查看" : b
        content.sound = .default
        // 与通道一共用实例 id 作标识：打开实例时一并撤下，两通道不会叠两条
        let request = UNNotificationRequest(identifier: instanceID.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 用户打开该实例：消化红点与提醒。
    static func clear(for instanceID: UUID) {
        InstanceStore.shared.clearDone(instanceID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [instanceID.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [instanceID.uuidString])
        syncBadge()
    }

    /// Dock 图标角标 = 未读实例数（iOS 的桌面角标在 mac 上的对应物）。
    static func syncBadge() {
        UNUserNotificationCenter.current()
            .setBadgeCount(InstanceStore.shared.unreadDoneCount)
    }

    private static func postNotification(instanceID: UUID, interrupted: Bool) {
        guard let instance = InstanceStore.shared.instance(instanceID) else { return }
        let content = UNMutableNotificationContent()
        if interrupted {
            content.title = "ZCode 任务异常中断"
            content.body = "「\(instance.name)」执行中与电脑的连接断开，任务状态请打开确认"
        } else {
            content.title = "ZCode 任务已结束"
            content.body = "「\(instance.name)」的任务执行完毕，打开查看"
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: instanceID.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
