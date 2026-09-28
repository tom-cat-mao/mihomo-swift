# Kumo 多开 Mihomo 核心 Bug 分析报告

> 调查日期：2026-09-28
> 源码版本：ProjectKumo/KumoApp（GitHub main 分支，2026-09-28 克隆）
> 本机环境：macOS，Kumo + 特权助手 `io.kumo.KumoService`（launchd root 守护），mihomo v1.19.31

## 现象

系统中同时存在多个 mihomo 核心进程（均为 root、父进程均为 KumoService），但 `kumo status` 报告 "Mihomo core stopped"——状态追踪与实际进程完全脱节。

现场（2026-09-28 下午）：

| PID | 启动时间 | 状态 |
|---|---|---|
| 77971 | 09-27 11:24 | 实际持有 7897/9097/utun4，正常服务，但 Kumo 已失去其 pid 记录 |
| 98138 | 09-28 16:16 | 启动卡死（cache.db 被 77971 锁定、端口绑定失败），成为僵尸，不退出 |

## 根因（源码实锤）

### 主因：`isProcessAlive` 对 EPERM 的误判

`Sources/KumoCoreKit/Runtime/CoreSupervisor.swift:255`：

```swift
private func isProcessAlive(_ pid: Int32) -> Bool {
    Darwin.kill(pid, 0) == 0
}
```

核心经特权助手以 **root** 身份运行，而 Kumo app / CLI 以普通用户运行。`kill(pid, 0)` 对"活着但属于其他用户"的进程返回 -1 且 `errno == EPERM`，代码将其误判为"进程已死"。

### 触发链

1. `status()` 优先走 service socket（`runningServiceClient()`），判断依据是 socket ping（`KumoServiceManager.status()`：`isPrivileged ? socketExists : ping()`）。
2. **ping 失败的瞬间**（service 重启、socket 抖动等），调用方静默降级到本地 `supervisor.status()`。
3. 本地路径下 root 核心被误判为死 → 触发 `core.stale_pid` 事件，**清除 pid 记录**，状态置为 stopped。
4. 之后 `start()` 经 service 检查时记录已空，直接拉起新核心 → **双开**。

### 实际事件序列（runtime-events.jsonl）

```
09-27 03:24:46Z  core.started   pid 77971（之后再无其 stopped 记录）
09-28 08:16:18Z  core.stale_pid 清除记录 ← 77971 此时活着，被 EPERM 误判
09-28 08:16:27Z  core.started   pid 98138（双开产生）
09-28 08:16:29Z  core.stale_pid 再次清除 ← 98138 的记录又被误判清掉
09-28 08:16:56Z  core.started   pid 98261（第三个）
09-28 08:17:34Z  core.stopped   只杀了 98261（唯一有记录的）
```

## 次生问题

1. **僵尸不可回收**：`stop()` 只杀 `recordedPIDs`（state.json + core.pid 文件）。记录被误清后，`stop` 直接报 "already stopped"，残留核心再也无法通过 Kumo 管理，只能手动 `sudo kill`。
2. **start 无端口/单实例兜底**：启动前不检查 7897/9097 是否已有 mihomo 在监听。
3. **mihomo 启动失败不退出**：核心 bind 端口失败或 TUN 冲突后不死，挂成半初始化僵尸（98138 只完成了 provider 初始化，从未打出 listening 日志）。
4. **重启不等旧核心退出**：手动 `sudo kill` 旧核心后，service 立刻拉起新核心，与旧核心的优雅关闭（约 6 秒释放 utun4/端口）发生竞态，新核心撞车再次卡死（pid 5000 案例）。
5. **日志文件交错损坏**：多个核心同时向同一 `core.log` append，出现行内时间戳混排，增加排查难度。

## 修复建议

1. `isProcessAlive` 将 EPERM 视为存活：

   ```swift
   private func isProcessAlive(_ pid: Int32) -> Bool {
       if Darwin.kill(pid, 0) == 0 { return true }
       return errno == EPERM
   }
   ```

2. 非特权降级路径**只读不写**：本地 `status()` 不得清除 pid 记录、不得改写状态；只有能确认进程归属的路径（service 侧 root）才允许执行 stale 清理。
3. `start()` 前检查控制端口（9097）是否已有 mihomo 在响应（如 GET `/version`），有则 adopt 其 pid 或报错拒绝，而不是直接再拉一个。
4. 重启/自动拉起前等待旧核心完全退出（pid 消失 + 端口释放），加超时与重试。
5. 给核心启动加端口/TUN 冲突的快速失败路径：bind 失败应终止进程并上抛错误，而不是半初始化悬挂。

## 临时处置（本次已执行）

```bash
sudo kill 98138 77971   # 清理双开现场（示例 pid）
# 若有半死核心：sudo kill -9 <pid>
# 确认无 mihomo 进程、无 7897/9097 监听、无 utun4(198.18.0.1) 后：
kumo start
```
