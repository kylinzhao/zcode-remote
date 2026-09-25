package dev.zcode.remote

/**
 * 注入远程页（zcode.z.ai/remote）的脚本：任务结束检测 + 下拉刷新防误触探测。
 *
 * 任务结束检测原理：relay 传输是多层二进制协议，无法可靠解析；但任务流式执行时页面
 * WebSocket 的字节流量持续处于高位，结束后回落到只剩心跳（约 10s 一次、几十字节）。
 * 本脚本包一层 window.WebSocket 统计流量，「持续高位 → 回落且页面不可见」即判定
 * 任务结束，通过 __ZcodeNative.onTaskFinished 通知 native。对协议升级、界面改版免疫。
 *
 * 下拉刷新探测：远程页是「外层不滚、聊天记录是内层滚动容器」的布局，native 侧
 * 只能看到外层滚动位置，内层滚动一律被误判成下拉刷新。脚本在 touchstart 时探测
 * 触点是否落在还能向上滚的内层容器里，经 __ZcodeNative.onPullGate 告知 native，
 * 命中则该手势让给页面滚动。
 *
 * 注意：ios/ZCodeRemote/TaskDetector.swift 是同一份脚本的移植副本，改动需两处同步。
 */
object DetectorJs {
    const val BRIDGE_NAME = "__ZcodeNative"

    val source: String = PROLOGUE + BODY

    private const val PROLOGUE = """
        (function () {
          if (window.__zcTaskDetector) return 'already';
          window.__zcTaskDetector = true;
          var bridge = window['__ZcodeNative'];
          if (!bridge || typeof bridge.onTaskFinished !== 'function') return 'no-bridge';
          function notifyPullGate(blocked) {
            try { bridge.onPullGate(blocked); } catch (e) { /* 旧版 native 无此方法 */ }
          }
          var OrigWS = window.WebSocket;
          if (!OrigWS) return 'no-ws';
    """

    private const val BODY = """
          // —— 阈值：每秒收包字节数判定 ——
          var TICK_MS = 1000;        // 统计窗口
          var HIGH_BYTES = 2048;     // 窗口内收到这么多字节视为「执行中」流量
          var ARM_MS = 15000;        // 高位需持续这么久才进入「有任务」状态（过滤翻历史等突发）
          var QUIET_MS = 6000;       // 「有任务」后需连续安静这么久才判定结束（过滤网络抖动）

          var bytesInWindow = 0;
          var highSince = 0;         // 本次连续高位起点，0 = 当前不是高位
          var armedAt = 0;           // 进入「有任务」状态的时刻
          var armed = false;
          var quietSince = 0;        // 回落后的安静起点
          var resolved = false;      // 本轮任务是否已出结果（已通知或用户在场看到）
          var openSockets = 0;

          function sizeOf(data) {
            if (typeof data === 'string') return data.length;
            if (data && typeof data.size === 'number') return data.size;
            if (data && typeof data.byteLength === 'number') return data.byteLength;
            return 0;
          }

          function reset() {
            armed = false; resolved = false;
            highSince = 0; armedAt = 0; quietSince = 0;
          }

          function onTick() {
            var now = Date.now();
            var high = bytesInWindow >= HIGH_BYTES && openSockets > 0;
            bytesInWindow = 0;
            if (high) {
              quietSince = 0;
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
                      bridge.onTaskFinished(JSON.stringify({ watchedMs: now - armedAt }));
                      console.info('[zc-task-detector] task finished, notified');
                    } catch (e) { /* bridge 不可用即放弃 */ }
                  }
                }
              }
            }
          }

          function ZcWebSocket(url, protocols) {
            var ws = protocols === undefined ? new OrigWS(url) : new OrigWS(url, protocols);
            ws.addEventListener('open', function () { openSockets += 1; });
            ws.addEventListener('close', function () {
              openSockets = Math.max(0, openSockets - 1);
              if (openSockets === 0) reset();
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
