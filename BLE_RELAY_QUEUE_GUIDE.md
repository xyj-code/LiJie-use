# BLE Relay Queue 架构指南

## 概述

本指南详细说明了 Rescue Mesh 系统中的**轮询广播队列 (Relay Queue)**机制，该机制实现了真正的多跳中继 (Store & Forward) 功能。

## 核心架构

### 1. 轮询广播算法 (Interleaved Broadcast Algorithm)

```
时间线:
第 0.0 秒  ──► 广播自己的 SOS 信号 (索引 0)
第 1.5 秒  ──► 停止广播 → 切换 → 广播伤者 A 的信号 (索引 1)
第 3.0 秒  ──► 停止广播 → 切换 → 广播伤者 B 的信号 (索引 2)
第 4.5 秒  ──► 停止广播 → 切换 → 广播伤者 C 的信号 (索引 3)
第 6.0 秒  ──► 停止广播 → 切换 → 回到自己的信号 (索引 0)
... 无限循环
```

### 2. 广播队列结构

```dart
List<List<int>> _broadcastQueue;

队列布局:
┌─────────────────────────────────────────────────────┐
│ 索引 0 │ 索引 1    │ 索引 2    │ 索引 3    │ 索引 4    │
├────────┼──────────┼──────────┼──────────┼──────────┤
│ 自己   │ 伤者 A    │ 伤者 B    │ 伤者 C    │ 伤者 D    │
│ SOS    │ 中继信号  │ 中继信号  │ 中继信号  │ 中继信号  │
└─────────────────────────────────────────────────────┘
  ↑                                                      ↑
  永远优先 (如果开启)                                  最多 5 个中继
```

## 核心组件

### 1. 获取接力弹药 (`_fetchRelayPayloads`)

**职责**: 从本地数据库查询需要接力的 SOS 信标

**防风暴机制**:
- ✅ **时间窗口限制**: 只获取最近 2 小时内的记录
- ✅ **数量限制**: 最多 5 条最新记录 (防止蓝牙载荷过载)
- ✅ **状态过滤**: 只查询 `isUploaded == false` 的记录

**SQL 查询**:
```sql
SELECT id, sender_mac, latitude, longitude, blood_type, timestamp, is_uploaded
FROM sos_messages
WHERE is_uploaded = 0 AND timestamp >= ?
ORDER BY timestamp DESC
LIMIT 5
```

**参数**:
- `threshold`: 当前时间 - 2 小时
- `LIMIT 5`: 防止队列过长导致广播频率过低

### 2. 转管机枪式轮询广播 (`_startInterleavedBroadcast`)

**职责**: 维护广播队列并周期性切换广播内容

**核心流程**:
1. 获取初始中继载荷
2. 重建广播队列 (自己 + 中继)
3. 启动 1.5 秒周期定时器
4. 每次触发 `_switchBroadcastPayload()`

**定时器配置**:
```dart
static const Duration _broadcastSwitchInterval = Duration(milliseconds: 1500);
Timer.periodic(_broadcastSwitchInterval, (_) => _switchBroadcastPayload());
```

### 3. 资源释放与容错

#### 安全切换流程 (`_switchBroadcastPayload`)

```dart
Future<void> _switchBroadcastPayload() async {
  // 1. 计算下一个索引 (循环)
  _currentBroadcastIndex = (_currentBroadcastIndex + 1) % _broadcastQueue.length;
  
  // 2. 确保先停止当前广播
  await _stopNativeBroadcast();
  
  // 3. 等待蓝牙硬件就绪 (100ms 延迟)
  await Future.delayed(const Duration(milliseconds: 100));
  
  // 4. 启动新广播
  await _startNativeBroadcast(nextPayload);
}
```

**异常处理**:
- ✅ 所有异步操作都有 try-catch 包裹
- ✅ 切换失败不会中断定时器 (继续尝试下一次)
- ✅ 蓝牙硬件繁忙时自动重试

#### 停止广播 (`stopSosBroadcast`)

```dart
Future<void> stopSosBroadcast() async {
  // 1. 停止轮询定时器
  _interleavedBroadcastTimer?.cancel();
  _relayFetchTimer?.cancel();
  
  // 2. 清空队列
  _broadcastQueue.clear();
  _currentBroadcastIndex = 0;
  
  // 3. 停止原生广播
  await _stopNativeBroadcast();
}
```

## 关键常量配置

```dart
// 中继获取间隔：每分钟从数据库刷新一次
static const Duration _relayFetchInterval = Duration(minutes: 1);

// 中继最大年龄：只广播 2 小时内的 SOS (防止无限循环)
static const Duration _relayMaxAge = Duration(hours: 2);

// 最大中继数量：防止队列过长导致单个信号广播频率太低
static const int _maxRelayPayloads = 5;

// 广播切换间隔：每 1.5 秒切换一次广播内容
static const Duration _broadcastSwitchInterval = Duration(milliseconds: 1500);
```

## 使用示例

### 1. 启动带中继的 SOS 广播

```dart
// 在 SOS 页面或其他地方调用
await bleMeshService.startSosBroadcast(
  latitude: 39.9042,
  longitude: 116.4074,
  bloodType: BloodType.o,
  sosFlag: true,
);

// 此时会自动:
// 1. 启动轮询广播机制
// 2. 从数据库加载未上传的 SOS 记录
// 3. 开始 1.5 秒周期的循环广播
```

### 2. 实时监控队列状态

```dart
// 监听服务状态变化
bleMeshService.addListener(() {
  print('队列长度：${bleMeshService.queueLength}');
  print('是否中继活跃：${bleMeshService.isRelayActive}');
});

// 或者直接查询
print('当前队列中有 ${bleMeshService.queueLength} 个待广播的 SOS 信号');
```

### 3. 手动添加实时中继载荷

当 BLE 扫描器发现其他设备的 SOS 信号时:

```dart
// 在 BLE 扫描器的回调中
void onDiscoveredSosMessage(SosMessage message) {
  // 保存到数据库 (会自动触发刷新)
  await appDb.saveIncomingSos(message);
  
  // 也可以直接添加到广播队列 (可选)
  final payload = SosAdvertisementPayload(
    companyId: 0xFFFF,
    latitude: message.latitude,
    longitude: message.longitude,
    bloodType: message.bloodType,
    sosFlag: true,
  );
  
  bleMeshService.addRelayPayload(payload);
}
```

### 4. 标记中继为已上传

当某个中继的 SOS 信号通过网络上传到云端后:

```dart
// 从队列中移除该信号
await bleMeshService.markRelayAsUploaded(messageId);

// 这会自动触发队列重建，移除已上传的信号
```

## 数据流图

```
┌─────────────────────────────────────────────────────────────┐
│                      AppDatabase                            │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ sos_messages 表                                      │   │
│  │ - id, sender_mac, latitude, longitude, blood_type    │   │
│  │ - timestamp, is_uploaded                             │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ _fetchRelayPayloads()
                            ▼ (每分钟刷新)
┌─────────────────────────────────────────────────────────────┐
│                   BleMeshService                            │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ _rebuildBroadcastQueue()                             │   │
│  │                                                       │   │
│  │ 广播队列：                                            │   │
│  │ [自己的 SOS] → [伤者 A] → [伤者 B] → [伤者 C]        │   │
│  └──────────────────────────────────────────────────────┘   │
│                            │                                  │
│                            │ Timer.periodic (1.5 秒)          │
│                            ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ _switchBroadcastPayload()                            │   │
│  │ 1. _stopNativeBroadcast()                            │   │
│  │ 2. Delay 100ms                                       │   │
│  │ 3. _startNativeBroadcast(nextPayload)                │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ MethodChannel
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                  Android Kotlin 端                          │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ AdvertiserManager.startAdvertising()                 │   │
│  │ - manufacturerData                                   │   │
│  │ - advertiseMode: ADVERTISE_MODE_LOW_LATENCY          │   │
│  │ - txPowerLevel: TX_POWER_LEVEL_HIGH                  │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 防风暴机制详解

### 问题背景

如果没有防风暴机制，可能会出现:
1. **无限循环**: A 广播 → B 接收并中继 → A 再次接收并中继 → 死循环
2. **队列爆炸**: 大量历史 SOS 记录堆积，导致广播频率过低
3. **带宽拥塞**: 过多信号争抢蓝牙广播信道

### 解决方案

#### 1. 时间窗口限制 (2 小时)

```dart
static const Duration _relayMaxAge = Duration(hours: 2);
final threshold = DateTime.now().subtract(_relayMaxAge);

// SQL: WHERE timestamp >= threshold
```

**效果**: SOS 信号最多在网络中传播 2 小时，之后自动"过期"

#### 2. 数量限制 (最多 5 个)

```dart
static const int _maxRelayPayloads = 5;

// SQL: LIMIT 5
```

**效果**: 
- 保证每个信号至少有 `1.5 秒 × (5+1) = 9 秒` 的广播窗口
- 防止队列过长导致实时性下降

#### 3. 状态标记 (`isUploaded`)

```dart
// 只查询未上传的记录
WHERE is_uploaded = 0
```

**效果**: 一旦某个 SOS 通过网络上传到云端，立即从中继队列移除

## 异常处理策略

### 1. 蓝牙硬件繁忙

```dart
try {
  await _startNativeBroadcast(payload);
} on PlatformException catch (error) {
  if (error.code == 'advertise_failed') {
    // 可能是硬件繁忙，等待下一次切换
    debugPrint('[BLE] 广播失败，等待下次切换');
  }
}
```

**策略**: 不抛出异常，等待 1.5 秒后的下一次切换机会

### 2. 数据库查询失败

```dart
try {
  final messages = await _fetchRelayPayloads();
} catch (error) {
  debugPrint('[BLE] 数据库查询失败：$error');
  return []; // 返回空列表，继续广播自己的信号
}
```

**策略**: 降级处理，只广播自己的 SOS 信号

### 3. 队列重建失败

```dart
Future<void> _rebuildBroadcastQueue() async {
  try {
    // ... 重建逻辑
  } catch (error) {
    debugPrint('[BLE] 队列重建失败：$error');
    // 保持现有队列继续工作
  }
}
```

**策略**: 保持现有队列继续循环广播

## 性能优化建议

### 1. 调整广播切换频率

```dart
// 更激进 (更快轮换，但每个信号广播时间更短)
static const Duration _broadcastSwitchInterval = Duration(milliseconds: 1000);

// 更保守 (更慢轮换，但每个信号广播时间更长)
static const Duration _broadcastSwitchInterval = Duration(milliseconds: 2000);
```

**推荐**: 1.5 秒是一个平衡点

### 2. 调整中继数量上限

```dart
// 更多中继 (覆盖更广，但轮换更慢)
static const int _maxRelayPayloads = 10;

// 更少中继 (更专注于最近的信号)
static const int _maxRelayPayloads = 3;
```

**推荐**: 5 个适合大多数场景

### 3. 动态调整刷新频率

```dart
// 移动场景中更频繁刷新
if (isMoving) {
  _relayFetchInterval = Duration(seconds: 30);
} else {
  _relayFetchInterval = Duration(minutes: 2);
}
```

## 测试场景

### 场景 1: 单设备广播

```dart
// 只有自己，没有中继
await bleMeshService.startSosBroadcast(...);
expect(bleMeshService.queueLength, 1); // 只有自己
```

### 场景 2: 多设备中继

```dart
// 模拟数据库中有 3 个未上传的 SOS
await _seedDatabaseWithRelayMessages(3);
await bleMeshService.startSosBroadcast(...);
await Future.delayed(Duration(seconds: 2)); // 等待刷新

expect(bleMeshService.queueLength, 4); // 自己 + 3 个中继
```

### 场景 3: 防风暴机制

```dart
// 插入 10 个历史消息 (超过 2 小时)
final oldTimestamp = DateTime.now().subtract(Duration(hours: 3));
await _insertSosMessage(timestamp: oldTimestamp);

await bleMeshService.startSosBroadcast(...);
await Future.delayed(Duration(seconds: 2));

// 应该被过滤掉
expect(bleMeshService.queueLength, 1); // 只有自己
```

## 监控与调试

### 启用详细日志

```dart
// 在开发环境中
debugPrint('[BLE Relay] 当前队列：${bleMeshService.queueLength} 个载荷');
debugPrint('[BLE Relay] 当前索引：$_currentBroadcastIndex');
debugPrint('[BLE Relay] 下次切换：${_interleavedBroadcastTimer?.isActive}');
```

### 监控指标

- `queueLength`: 当前队列长度
- `isRelayActive`: 是否有中继信号
- `isBroadcastingNow`: 是否正在广播
- `lastError`: 最后一次错误信息

## 常见问题 FAQ

### Q: 为什么我的中继队列一直是空的？

**A**: 检查以下几点:
1. 数据库中是否有 `isUploaded = 0` 的记录？
2. 记录的时间戳是否在最近 2 小时内？
3. `_relayEnabled` 是否为 `true`？

### Q: 广播切换频率太快/太慢怎么办？

**A**: 修改 `_broadcastSwitchInterval` 常量:
```dart
static const Duration _broadcastSwitchInterval = Duration(milliseconds: 2000);
```

### Q: 如何优先广播某些特定的 SOS 信号？

**A**: 当前实现按时间戳倒序排列。如需自定义优先级，可以修改 `_fetchRelayPayloads` 中的 SQL ORDER BY 子句。

### Q: 设备重启后中继队列会丢失吗？

**A**: 不会。队列数据存储在 SQLite 数据库中，重启后会自动重新加载。但需要重新调用 `startSosBroadcast()` 来启动广播。

## 未来优化方向

1. **自适应切换频率**: 根据周围设备密度动态调整切换间隔
2. **优先级队列**: 根据伤情严重程度 (血型) 给予不同优先级
3. **地理围栏**: 只中继距离较近的 SOS 信号
4. **能耗优化**: 在电量低时减少切换频率
5. **机器学习**: 预测最优的中继路径和广播策略
