# AI救援规划引擎 - API密钥配置指南

本文档指导您如何获取和配置AI救援规划功能所需的API密钥。

---

## 📋 所需API密钥清单

### 1. 高德地图Web服务API Key（必需）⭐

**用途：**
- 逆地理编码（GPS坐标 → 详细地址）
- 路径规划（计算驾车路线、距离、时间）

**获取步骤：**

1. 访问 [高德开放平台控制台](https://console.amap.com/dev/index)
2. 注册/登录账号
3. 点击"创建新应用"
   - 应用名称：`Rescue Mesh App`
   - 应用类型：选择"其他"
4. 在应用中"添加Key"
   - Key名称：`rescue-mesh-backend`
   - 服务平台：选择"Web服务"
5. 复制生成的Key

**填写位置：**

```bash
# server/.env 文件
AMAP_API_KEY=你的高德API_Key_粘贴在这里
```

或者直接在代码中修改：
- `server/src/services/geocodingService.js` 第15行
- `server/src/services/routingService.js` 第18行

**配额限制：**
- 免费额度：每日30,000次调用
- QPS限制：每秒50次请求
- 超出后可申请提升配额

---

### 2. 百度地图AK（可选，备用方案）

**用途：**
- 当高德API失败时的备选方案

**获取步骤：**

1. 访问 [百度地图开放平台](https://lbsyun.baidu.com/apiconsole/key#/home)
2. 注册/登录账号
3. 点击"创建应用"
   - 应用名称：`Rescue Mesh Backup`
   - 应用类型：选择"服务端"
4. 勾选"逆地理编码"和"方向规划"服务
5. 复制生成的AK

**填写位置：**

```bash
# server/.env 文件
BAIDU_MAP_AK=你的百度AK_粘贴在这里
```

或者直接在代码中修改：
- `server/src/services/geocodingService.js` 第16行
- `server/src/services/routingService.js` 第19行

---

### 3. Redis缓存（可选，性能优化）

**用途：**
- 缓存地理编码结果，减少API调用次数
- 缓存路径规划结果，加速重复查询

**安装方式：**

**Windows:**
```powershell
# 使用Chocolatey安装
choco install redis-64

# 或使用Docker
docker run -d -p 6379:6379 --name redis-cache redis:alpine
```

**Linux/Mac:**
```bash
# Ubuntu/Debian
sudo apt-get install redis-server

# macOS
brew install redis
```

**配置位置：**

```bash
# server/.env 文件（如果不配置则禁用缓存）
REDIS_URL=redis://localhost:6379
```

**注意：**
- 如果不使用Redis，系统会自动降级到内存缓存
- 生产环境强烈建议使用Redis以提升性能和降低成本

---

### 4. DashScope通义千问API Key（已有）

**用途：**
- LLM智能问答
- 生成救援建议文本

**确认配置：**

检查 `server/src/services/llmService.js` 第10行是否已配置：

```javascript
const DASHSCOPE_API_KEY = process.env.DASHSCOPE_API_KEY || 'YOUR_DASHSCOPE_API_KEY_HERE';
```

如果尚未获取：
1. 访问 [阿里云DashScope控制台](https://dashscope.console.aliyun.com/)
2. 开通DashScope服务
3. 创建API Key
4. 填入 `server/.env`：

```bash
DASHSCOPE_API_KEY=sk-xxxxxxxxxxxxxxx
```

---

## 🔧 配置文件模板

在项目根目录创建或编辑 `server/.env` 文件：

```env
# ==================== 服务器配置 ====================
PORT=3000
NODE_ENV=development

# ==================== MongoDB配置 ====================
MONGODB_URI=mongodb://localhost:27017/rescue_mesh

# ==================== 高德地图API（必需）====================
AMAP_API_KEY=amap_your_key_here

# ==================== 百度地图AK（可选备用）==================
BAIDU_MAP_AK=baidu_ak_here

# ==================== Redis缓存（可选）=====================
# REDIS_URL=redis://localhost:6379

# ==================== DashScope LLM（已有）=================
DASHSCOPE_API_KEY=sk-your_dashcope_key_here

# ==================== 调试模式 ===========================
DEBUG=true
```

---

## ✅ 验证配置

启动服务器后，测试各个API端点：

### 1. 测试逆地理编码

```bash
curl "http://localhost:3000/api/sos/ai/rescue-plan/AA:BB:CC:DD:EE:FF"
```

预期响应应包含 `addressInfo` 字段：
```json
{
  "data": {
    "addressInfo": {
      "formattedAddress": "北京市朝阳区建国路XX号",
      "province": "北京市",
      "city": "北京市",
      "district": "朝阳区",
      "street": "建国路"
    }
  }
}
```

### 2. 测试路径规划

同上请求，检查 `routeInfo` 字段：
```json
{
  "data": {
    "routeInfo": {
      "distance": 12500,
      "duration": 1800,
      "steps": [...]
    }
  }
}
```

### 3. 测试批量优化

```bash
curl -X POST http://localhost:3000/api/sos/ai/batch-rescue-plan \
  -H "Content-Type: application/json" \
  -d '{
    "macs": ["AA:BB:CC:DD:EE:FF", "11:22:33:44:55:66"],
    "originLng": 116.397,
    "originLat": 39.918,
    "originName": "市第一人民医院",
    "optimizationStrategy": "efficiency"
  }'
```

---

## 🚨 常见问题

### Q1: API调用返回403 Forbidden

**原因：** API Key未生效或配额耗尽

**解决：**
1. 检查Key是否正确复制到 `.env` 文件
2. 重启Node.js服务器使环境变量生效
3. 登录高德控制台查看配额使用情况
4. 确认Key的服务平台设置为"Web服务"

### Q2: 地理编码返回空地址

**原因：** 坐标超出中国境内范围或精度不足

**解决：**
1. 确认SOS记录的经纬度在中国境内（经度73-135，纬度18-54）
2. 检查坐标系是否为GCJ-02（火星坐标系）
3. 如果是WGS-84坐标，需要先转换

### Q3: 路径规划超时

**原因：** 网络问题或并发请求过多

**解决：**
1. 检查网络连接
2. 降低并发请求数量（调整 `routingService.js` 中的 `MAX_CONCURRENT_REQUESTS`）
3. 启用Redis缓存减少重复调用

### Q4: Redis连接失败

**症状：** 日志显示 `[Redis] 连接失败`

**解决：**
1. 确认Redis服务正在运行：`redis-cli ping` 应返回 `PONG`
2. 检查 `REDIS_URL` 格式是否正确
3. 如果不需要缓存，注释掉该环境变量即可

---

## 📊 成本估算

假设日均处理100个求救信号：

| 服务项目 | 单次调用 | 日调用量 | 月费用 |
|---------|---------|---------|--------|
| 高德逆地理编码 | 免费 | 100次 | ¥0 |
| 高德路径规划 | 免费 | 100次 | ¥0 |
| DashScope LLM | ~¥0.01/次 | 50次 | ¥15 |
| **总计** | - | - | **~¥15/月** |

**结论：** 在高德免费额度内，主要成本来自LLM调用，整体成本极低。

---

## 🔐 安全建议

1. **不要提交API Key到Git仓库**
   ```bash
   # 确保 .gitignore 包含
   echo "server/.env" >> .gitignore
   ```

2. **设置IP白名单**
   - 在高德控制台限制API Key只能从您的服务器IP调用

3. **定期轮换密钥**
   - 每3个月更换一次API Key

4. **监控用量告警**
   - 在高德控制台设置用量阈值提醒

---

## 📞 技术支持

如遇问题，请参考：
- [高德地图Web服务文档](https://lbs.amap.com/api/webservice/guide/api/georegeo)
- [百度地图Web服务文档](http://lbsyun.baidu.com/index.php?title=webapi)
- [DashScope API文档](https://help.aliyun.com/zh/dashscope/)

或在项目中提出Issue。
