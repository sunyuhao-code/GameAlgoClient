# Maker Lua SDK 的 Android 结束事件探针

这是一个 **Android 测试容器，不是 TapTap/Maker 宿主**。容器运行原样 SDK Lua 模块，使用原生 Lua 5.4、Android `HttpURLConnection` 和应用私有目录中的真实文件；对 Maker 的 Node 事件、File 和 HTTP 接口提供适配。JSON 适配使用 Android `org.json`。不测试 Maker 引擎本身或其原生 cjson 实现。

容器在 Android `onPause` 中触发 Will/Did 后台事件，随后暂停 Update 和 Lua HTTP 回调；原生 HTTP 线程仍可发送请求。本机测试服务在收到普通批次后故意延迟响应，以稳定复现“普通批次已经抵达，但结束事件等不到其回调”。测试服务只监听本机，SDK 使用专门的假 key、假用户及 debug 数据。

`prepare_assets.py` 将当前工作区 SDK 原样复制到构建目录，同时从固定提交 `417a619` 提取 `2.1.3-lua` 作对照。探针不修改 SDK 的 HTTP transport，不向 GamePropel 上报测试事件。

## 运行

需要 JDK 17、Android SDK 35、arm64 Android 模拟器，以及已配置的 `JAVA_HOME` 和 `ANDROID_HOME`。构建会从 Maven Central 获取固定版本 LuaJava 4.1.0。

在仓库根目录执行：

```sh
python3 lua/tests/android/prepare_assets.py
./android/gradlew -p lua/tests/android assembleDebug
adb -s emulator-5554 install -r lua/tests/android/build/outputs/apk/debug/MakerSessionEndProbe-debug.apk
python3 -u lua/tests/android/run_probe.py --serial emulator-5554 --output /tmp/maker-end-probe-results
```

Runner 会重置自己创建的 `com.gamepropel.makerprobe` 包数据，然后执行以下检查：

| 场景 | 检查 |
| --- | --- |
| 旧版：普通批次回调未完成便 Home、杀进程、重开 | 退出前结束事件未发送；本地仍有快照，重开后补传 |
| 新版：相同时序 | 退出时独立请求已到服务端；重开重放保持原事件 ID/Context/Session/时间 |
| 空闲时 Home、杀进程、重开 | 普通发送即可抵达，Will/Did 只产生一个快照 |
| 只有 Did 后台通知 | 仍生成、保存并发送结束快照 |
| 优先请求受控返回 503 | 快照留在已提交存储中，重开后成功补传 |
| Home 后原进程恢复 | 暂存回调完成，队列清空，Context/Session 保持原值 |
| 保持前台，先确认优先请求再完成普通请求 | 普通队列复用回执；清空队列并重开后不会复活已确认事件 |
| 旧版：普通批次阻塞时上报广告、Home、杀进程、重开 | 广告等待普通回调，重开后以原 ID 补传 |
| 新版：普通与广告请求都阻塞时 Home、杀进程、重开 | 广告已通过独立请求抵达，结束事件不等待两者；重开广告保留原完整事件 |

输出包含 `results.json`、测试服务原始接收记录和仅该探针的 logcat。`results.json.complete=true` 且九个场景均通过才算本轮完成。持久化检查按最高修订的快照和事件块读取，忽略旧恢复银行中残留的事件。

## 验证范围

该探针证明 SDK 在 Android 进程/网络/文件环境中的受控时序行为。它无法证明真实 Maker 宿主会发出哪些回调，或者宿主在退出时是否允许原生 HTTP 继续执行。没有任何生命周期通知的直接杀进程也无法产生一个新的结束事件。真实 Maker 验收应使用独立测试项目，并核对服务端首次接收时间，而不只看下一次启动后最终是否补齐。
