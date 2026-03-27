# BleMeshService Relay API 快速参考

## 核心方法

### 启动广播 (带自动中继)

```dart
await bleMeshService.startSosBroadcast(
  latitude: 39.9042,      // 纬度 (必需)
  longitude: 116.4074,     // 经度 (必需)
  bloodType: BloodType.o,  // 血型 (必需)
  sosFlag: true,           // SOS 标志 (可选，默认 true)
  companyId: 0xFFFF,       // 厂商标识 (可选，默认 0xFFFF)
);
```

**自动执行**:
- ✅ 启动 1.5 秒周期的轮询广播
- ✅ 从数据库加载未上传的 SOS 记录
- ✅ 将自己的 SOS 放在队列首位
- ✅ 每分钟自动刷新中继队列

---

### 停止广播

```dart
await bleMeshService.stopSosBroadcast();
```

**清理工作**:
- ✅ 停止轮询定时器
- ✅ 清空广播队列
- ✅ 停止蓝牙广播

---

### 监控状态

```dart
// 添加监听器
bleMeshService.addListener(() {
  print('队列长度：${bleMeshService.queueLength}');
  print('是否中继：${bleMeshService.isRelayActive}');
  print('正在广播：${bleMeshService.isBroadcastingNow}');
});

// 或直接读取属性
final queueLen = bleMeshService.queueLength;
final hasRelay = bleMeshService.isRelayActive;
final isBroadcasting = bleMeshService.isBroadcastingNow;
```

---

### 手动添加中继载荷

```dart
// 当 BLE 扫描器发现其他 SOS 信号时
final payload = SosAdvertisementPayload(
  companyId: 0xFFFF,
  latitude: 39.9042,
  longitude: 116.4074,
  bloodType: BloodType.a,
  sosFlag: true,
);

bleMeshService.addRelayPayload(payload);
```

**效果**: 立即将该 SOS 添加到广播队列末尾

---

### 标记为中继完成

```dart
// 当 SOS 通过网络上传到云端后
await bleMeshService.markRelayAsUploaded(messageId);
```

**效果**: 
- ✅ 更新数据库 `isUploaded = 1`
- ✅ 自动从广播队列移除

---

### 启用/禁用中继功能

```dart
// 禁用中继 (只广播自己的 SOS)
await bleMeshService.setRelayEnabled(false);

// 启用中继 (默认行为)
await bleMeshService.setRelayEnabled(true);
```

---

## 配置常量 (可修改)

```dart
// 在 BleMeshService 类中修改这些常量:

// 中继获取间隔
static const Duration _relayFetchInterval = Duration(minutes: 1);

// 中继最大年龄 (防风暴)
static const Duration _relayMaxAge = Duration(hours: 2);

// 最大中继数量
static const int _maxRelayPayloads = 5;

// 广播切换间隔
static const Duration _broadcastSwitchInterval = Duration(milliseconds: 1500);
```

---

## 完整工作流程示例

```dart
class SosPage extends StatefulWidget {
  @override
  _SosPageState createState() => _SosPageState();
}

class _SosPageState extends State<SosPage> {
  @override
  void initState() {
    super.initState();
    
    // 监听广播状态
    bleMeshService.addListener(_onBleServiceChanged);
  }
  
  @override
  void dispose() {
    bleMeshService.removeListener(_onBleServiceChanged);
    super.dispose();
  }
  
  void _onBleServiceChanged() {
    setState(() {}); // 触发 UI 更新
  }
  
  Future<void> _triggerSos() async {
    try {
      // 1. 获取当前位置
      final location = await getLocation();
      
      // 2. 获取用户血型
      final bloodType = EmergencyProfile.current.bloodType;
      
      // 3. 启动带中继的广播
      await bleMeshService.startSosBroadcast(
        latitude: location.latitude,
        longitude: location.longitude,
        bloodType: bloodType,
      );
      
      // 4. 显示状态
      showSuccess('SOS 广播已启动 (网络 + 蓝牙双通道)');
      
    } catch (error) {
      showError('SOS 启动失败：$error');
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 队列状态
        Text('正在中继 ${bleMeshService.queueLength} 个 SOS 信号'),
        
        // 广播开关
        ElevatedButton(
          onPressed: bleMeshService.isBroadcastingNow 
              ? null 
              : _triggerSos,
          child: Text(bleMeshService.isBroadcastingNow 
              ? '广播中...' 
              : '启动 SOS'),
        ),
        
        // 停止按钮
        if (bleMeshService.isBroadcastingNow)
          ElevatedButton(
            onPressed: () async {
              await bleMeshService.stopSosBroadcast();
              showSuccess('SOS 广播已停止');
            },
            child: Text('停止广播'),
          ),
      ],
    );
  }
}
```

---

## 数据库表结构

### sos_messages 表

```sql
CREATE TABLE sos_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sender_mac TEXT NOT NULL,      -- 发送者 MAC 地址
  latitude REAL NOT NULL,         -- 纬度
  longitude REAL NOT NULL,        -- 经度
  blood_type INTEGER NOT NULL,    -- 血型编码
  timestamp DATETIME NOT NULL,    -- 时间戳
  is_uploaded BOOLEAN DEFAULT 0   -- 是否已上传到云端
);
```

**查询条件**:
- `is_uploaded = 0`: 未上传到中继
- `timestamp >= NOW - 2h`: 最近 2 小时内
- `ORDER BY timestamp DESC`: 最新的优先
- `LIMIT 5`: 最多 5 个

---

## 错误处理

```dart
try {
  await bleMeshService.startSosBroadcast(...);
} on BleMeshUnsupportedException catch (e) {
  // 设备不支持 BLE
  showError('设备不支持蓝牙功能');
} on BleMeshBluetoothDisabledException catch (e) {
  // 蓝牙未开启
  showError('请先开启蓝牙');
} on BleMeshPermissionDeniedException catch (e) {
  // 权限被拒绝
  showError('蓝牙权限被拒绝，请在设置中授权');
} on BleMeshBroadcastFailedException catch (e) {
  // 广播启动失败
  showError('广播启动失败：${e.message}');
} catch (e) {
  // 未知错误
  showError('发生错误：$e');
}
```

---

## 调试技巧

### 1. 查看详细日志

```bash
# Android Logcat
adb logcat | grep -E "\[BLE.*Relay\]"
```

输出示例:
```
[BLE Relay] Interleaved broadcast started with 3 payloads
[BLE Relay] Fetched 2 relay payloads from database
[BLE Relay] Switching to payload #1
[BLE Relay] Queue rebuilt with 3 total payloads
```

### 2. 模拟数据库记录

```dart
// 在测试中插入假数据
await appDb.customInsert('''
  INSERT INTO sos_messages 
    (sender_mac, latitude, longitude, blood_type, timestamp, is_uploaded)
  VALUES (?, ?, ?, ?, ?, 0)
''', variables: [
  Variable<String>('AA:BB:CC:DD:EE:FF'),
  Variable<double>(39.9042),
  Variable<double>(116.4074),
  Variable<int>(3), // BloodType.o
  Variable<DateTime>(DateTime.now()),
  Variable<int>(0),
]);
```

### 3. 强制刷新队列

```dart
// 手动触发刷新 (用于测试)
await bleMeshService._refreshRelayPayloads(); // 私有方法，仅测试用
await bleMeshService._rebuildBroadcastQueue();
```

---

## 性能基准

### 典型场景 (5 个中继)

- **队列总长度**: 6 (自己 + 5 个中继)
- **完整循环时间**: 1.5 秒 × 6 = 9 秒
- **每个信号广播时长**: 1.5 秒
- **每小时切换次数**: 2400 次
- **预估功耗增加**: ~15-20% (相比单一广播)

### 极限场景 (满载 5 个中继)

- **最大队列长度**: 6
- **最坏延迟**: 9 秒后才能再次广播自己的信号
- **蓝牙占用率**: ~60% (考虑切换开销)

### 优化建议

- 如果周围设备密集 (>10 个)，考虑减少 `_maxRelayPayloads` 到 3
- 如果设备稀疏 (<3 个)，可以增加到 8-10 个
- 移动速度高时，缩短 `_relayFetchInterval` 到 30 秒
