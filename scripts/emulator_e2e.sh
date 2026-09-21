#!/bin/zsh
# 模拟器端到端验证脚本：创建 AVD → 无头启动 → 安装 → 深链接添加真实实例 → 截图
set -e
SDK=/Users/zhaoliang/android-sdk
EMU=$SDK/emulator/emulator
ADB=$SDK/platform-tools/adb
AVDM=$SDK/cmdline-tools/latest/bin/avdmanager
APK=/Users/zhaoliang/guazi/work/zcode-app/dist/ZCodeRemote-v1.0.0-release.apk
SHOT=/Users/zhaoliang/guazi/work/zcode-app/screens
REAL_URL='REPLACE_WITH_REAL_REMOTE_URL'

mkdir -p "$SHOT"

echo '== 1. 创建 AVD'
echo no | "$AVDM" create avd --force -n zctest -k "system-images;android-34;google_apis;arm64-v8a" -d pixel_6 >/dev/null 2>&1 || true

echo '== 2. 启动模拟器(无头)'
"$EMU" -avd zctest -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -no-snapshot -memory 3072 >/tmp/emu.log 2>&1 &
EMU_PID=$!

echo '== 3. 等待开机'
"$ADB" wait-for device
until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 3; done
echo '   booted.'

shot() { "$ADB" exec-out screencap -p > "$SHOT/$1"; echo "   shot: $1"; }
tap_ui() { # uiautomator 定位控件中心并点击
  local desc="$1"
  local xy=$("$ADB" shell uiautomator dump /dev/tty 2>/dev/null | tr -d '\r' | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'content-desc=\"$desc\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml)
if m:
    print((int(m.group(1)) + int(m.group(3))) // 2, (int(m.group(2)) + int(m.group(4))) // 2)
")
  [ -n "$xy" ] && "$ADB" shell input tap $xy
}

echo '== 4. 安装 APK'
"$ADB" install -r "$APK"

echo '== 5. 冷启动(空列表)'
"$ADB" shell am start -n dev.zcode.remote/.MainActivity >/dev/null
sleep 3
shot 01_empty_list.png

echo '== 6. 深链接添加真实实例'
"$ADB" shell "am start -a android.intent.action.VIEW -d '$REAL_URL' dev.zcode.remote" >/dev/null
sleep 2
shot 02_edit_prefilled.png
"$ADB" shell input keyevent KEYCODE_ENTER 2>/dev/null || true
# 点击「保存」(文本定位)
XY=$("$ADB" shell uiautomator dump /dev/tty 2>/dev/null | tr -d '\r' | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'text=\"保存\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml)
if m: print((int(m.group(1)) + int(m.group(3))) // 2, (int(m.group(2)) + int(m.group(4))) // 2
)")
"$ADB" shell input tap $XY
echo '== 7. 等待远程页加载'
sleep 12
shot 03_remote_loaded.png

echo '== 8. 返回列表 + 错误页场景'
"$ADB" shell input keyevent KEYCODE_BACK; sleep 1
shot 04_list_with_instance.png
"$ADB" shell am start -n dev.zcode.remote/.InstanceEditActivity --es url 'https://127.0.0.1:9/refused' --es name '测试错误页' >/dev/null
sleep 1
XY=$("$ADB" shell uiautomator dump /dev/tty 2>/dev/null | tr -d '\r' | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'text=\"保存\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml)
if m: print((int(m.group(1)) + int(m.group(3))) // 2, (int(m.group(2)) + int(m.group(4))) // 2
)")
"$ADB" shell input tap $XY; sleep 8
shot 05_error_page.png

echo '== 完成。模拟器保持运行(PID '$EMU_PID')'
