#!/bin/zsh
# T12 E2E：冷启动恢复上次实例 + 回前台保持页面
set -e
SDK=/Users/zhaoliang/android-sdk
ADB=$SDK/platform-tools/adb
APK=/Users/zhaoliang/guazi/work/zcode-app/app/build/outputs/apk/debug/app-debug.apk
SHOT=/Users/zhaoliang/guazi/work/zcode-app/screens
PKG=dev.zcode.remote
mkdir -p "$SHOT"

# 取当前前台 Activity
top_act() { "$ADB" shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep -m1 'topResumedActivity' | grep -oE 'u0 [^/ ]+/[^ }]+' | awk '{print $2}'; }
# 从 UI 树按 text 找控件并点击（dump 落盘再读，/dev/tty 直读不稳定）
tap_text() {
  local text="$1"
  for i in 1 2 3 4 5; do
    "$ADB" shell uiautomator dump /sdcard/t12.xml >/dev/null 2>&1
    local xy=$("$ADB" shell cat /sdcard/t12.xml 2>/dev/null | tr -d '\r' | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'text=\"$text\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml)
if m: print((int(m.group(1))+int(m.group(3)))//2, (int(m.group(2))+int(m.group(4)))//2)
")
    [ -n "$xy" ] && { "$ADB" shell input tap $xy; return 0; }
    sleep 1.5
  done
  echo "!! 未找到控件: $text"; return 1
}
shot() { "$ADB" exec-out screencap -p > "$SHOT/$1"; echo "   shot: $1  top=$(top_act)"; }
add_via_link() { # 深链接打开编辑页(预填) → 保存 → 自动打开该实例
  "$ADB" shell "am start -a android.intent.action.VIEW -d '$1' $PKG" >/dev/null
  sleep 2; tap_text "保存"; sleep 3
}

echo '== 0. 启动模拟器(无头)'
"$ADB" devices | grep -q "emulator-" && echo '   已在运行' || {
  "$SDK/emulator/emulator" -avd zctest -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -no-snapshot -memory 3072 >/tmp/emu-t12.log 2>&1 &
}
"$ADB" wait-for-device
until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 3; done
echo '   booted.'

echo '== 1. 全新安装(清数据) + 冷启动 → 空列表'
"$ADB" uninstall $PKG >/dev/null 2>&1 || true
"$ADB" install -r "$APK" >/dev/null
"$ADB" shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null || true
"$ADB" shell "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $PKG/.MainActivity" >/dev/null; sleep 3
shot t12_01_empty.png

echo '== 2. 深链接添加「甲电脑」(保存后自动打开甲)'
add_via_link 'https://zcode.z.ai/remote/v4?sid=aaa&hash=h1&name=甲电脑&pc=A'
shot t12_02_opened_jia.png

echo '== 3. 返回列表，深链接添加「乙电脑」(保存后自动打开乙) → 乙为最近实例'
"$ADB" shell input keyevent KEYCODE_BACK; sleep 1.5
add_via_link 'https://zcode.z.ai/remote/v4?sid=bbb&hash=h2&name=乙电脑&pc=B'
shot t12_03_opened_yi.png

echo '== 4. 回前台保持（进程活着）：HOME → 再进 → 应仍在乙页面'
"$ADB" shell input keyevent KEYCODE_HOME; sleep 1
"$ADB" shell "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $PKG/.MainActivity" >/dev/null; sleep 3
shot t12_04_foreground_keep.png

echo '== 5. 后台杀进程(任务栈保留)：HOME → am kill → 再进 → 系统重建栈，仍在乙页面'
"$ADB" shell input keyevent KEYCODE_HOME; sleep 1
"$ADB" shell am kill $PKG; sleep 1
"$ADB" shell "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $PKG/.MainActivity" >/dev/null; sleep 4
shot t12_05_after_amkill.png

echo '== 6. force-stop(任务栈清除，等价激进 ROM) → 再进 → 冷启动直达乙页面'
"$ADB" shell am force-stop $PKG; sleep 1
"$ADB" shell "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $PKG/.MainActivity" >/dev/null; sleep 4
shot t12_06_cold_restore.png

echo '== 7. 列表态 force-stop → 冷启动仍直达最近实例（乙）'
"$ADB" shell input keyevent KEYCODE_BACK; sleep 1.5   # 从乙页面退回列表
shot t12_07_on_list.png
"$ADB" shell input keyevent KEYCODE_HOME; sleep 1
"$ADB" shell am force-stop $PKG; sleep 1
"$ADB" shell "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $PKG/.MainActivity" >/dev/null; sleep 4
shot t12_08_cold_from_list.png

echo '== 8. 不保留活动(系统重建栈)：乙页面 → HOME → 再进 → 仍在乙页面'
"$ADB" shell settings put global always_finish_activities 1
"$ADB" shell input keyevent KEYCODE_HOME; sleep 1
"$ADB" shell "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n $PKG/.MainActivity" >/dev/null; sleep 5
shot t12_09_rebuild_stack.png
"$ADB" shell settings put global always_finish_activities 0

echo '== 完成'
