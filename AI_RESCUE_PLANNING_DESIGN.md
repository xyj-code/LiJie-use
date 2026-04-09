# AI 急救规划引擎 - 增强设计方案

## 📋 概述

当前AI模块仅提供基础的优先级排序和态势摘要，**缺少关键的急救规划能力**。本方案提出构建一个完整的"AI急救规划引擎"，整合以下核心能力：

1. **精准定位与地址解析** - 将坐标转换为可读的街道地址
2. **道路网络分析** - 计算最优救援路线、预估到达时间
3. **资源调度优化** - 智能分配最近的救护车/医护人员
4. **多目标路径规划** - 为多名伤员制定高效救援顺序
5. **实时交通融合** - 结合路况动态调整救援计划

---

## 🎯 核心问题诊断

### 当前痛点（从截图可见）
```
❌ "无法回答'这些人叫什么名字'和'在哪个地理位置'"
❌ "所属省份需结合13个求救点的省级分布推断"
❌ "如需进一步定位，须调用关联的GIS工单系统或身份授权数据库"
```

### 根本原因
1. **数据脱敏过度** - MAC地址匿名化导致无法关联真实身份信息
2. **缺少地理编码服务** - 没有反向地理编码（Reverse Geocoding）
3. **无道路网络数据** - 缺乏地图API集成（高德/百度/OpenStreetMap）
4. **LLM上下文不足** - Prompt中未包含足够的结构化位置信息

---

## 🏗️ 架构设计

### 新增组件层级

```
server/src/
├── services/
│   ├── llmService.js              # 现有 LLM 服务
│   ├── geocodingService.js        # 【新增】地理编码服务
│   ├── routingService.js          # 【新增】路径规划服务
│   └── rescuePlannerService.js    # 【新增】急救规划引擎
│
├── routes/
│   └── sos.js                     # 扩展现有路由
│       ├── GET /api/sos/ai/priorities
│       ├── GET /api/sos/ai/risk-areas
│       ├── GET /api/sos/ai/situation-report
│       ├── POST /api/sos/ai/generate-report
│       ├── POST /api/sos/ai/chat
│       ├── GET /api/sos/ai/rescue-plan/:mac      # 【新增】单人救援计划
│       └── POST /api/sos/ai/batch-rescue-plan    # 【新增】批量救援计划
│
└── utils/
    └── mapUtils.js                # 【新增】地图工具函数
```

---

## 🔧 详细实现方案

### 1️⃣ 地理编码服务 (`geocodingService.js`)

**功能**：将经纬度转换为人类可读的地址

```javascript
/**
 * 使用高德地图逆地理编码 API
 * 文档：https://lbs.amap.com/api/webservice/guide/api/georegeo
 */
const AMAP_KEY = process.env.AMAP_API_KEY;
const AMAP_BASE_URL = 'https://restapi.amap.com/v3/geocode/regeo';

async function reverseGeocode(lng, lat) {
  const url = `${AMAP_BASE_URL}?location=${lng},${lat}&key=${AMAP_KEY}&radius=1000&extensions=all`;
  
  const response = await fetch(url);
  const data = await response.json();
  
  if (data.status !== '1') {
    throw new Error(`高德API错误: ${data.info}`);
  }
  
  const regeocode = data.regeocode;
  return {
    formattedAddress: regeocode.formatted_address, // 完整地址
    addressComponent: {
      province: regeocode.addressComponent.province,
      city: regeocode.addressComponent.city,
      district: regeocode.addressComponent.district,
      township: regeocode.addressComponent.township,
      street: regeocode.addressComponent.streetNumber?.street || '',
      streetNumber: regeocode.addressComponent.streetNumber?.number || '',
    },
    pois: regeocode.pois?.slice(0, 3).map(poi => ({
      name: poi.name,
      type: poi.type,
      distance: poi.distance,
    })) || [], // 周边POI（医院、学校等）
  };
}

module.exports = { reverseGeocode };
```

**环境变量配置**（`server/.env`）：
```bash
AMAP_API_KEY=your_amap_api_key_here
```

---

### 2️⃣ 路径规划服务 (`routingService.js`)

**功能**：计算两点之间的最优路线、距离、预计时间

```javascript
/**
 * 使用高德地图驾车路径规划 API
 * 文档：https://lbs.amap.com/api/webservice/guide/api/newroute
 */
const AMAP_KEY = process.env.AMAP_API_KEY;
const ROUTE_BASE_URL = 'https://restapi.amap.com/v3/direction/driving';

async function calculateRoute(originLng, originLat, destLng, destLat) {
  const origin = `${originLng},${originLat}`;
  const destination = `${destLng},${destLat}`;
  
  const url = `${ROUTE_BASE_URL}?origin=${origin}&destination=${destination}&key=${AMAP_KEY}&strategy=0`;
  
  const response = await fetch(url);
  const data = await response.json();
  
  if (data.status !== '1') {
    throw new Error(`路径规划失败: ${data.info}`);
  }
  
  const route = data.route.paths[0];
  return {
    distance: parseInt(route.distance), // 米
    duration: parseInt(route.duration), // 秒
    tolls: parseFloat(route.tolls || 0), // 过路费
    steps: route.steps.map(step => ({
      instruction: step.instruction, // 导航指令
      distance: parseInt(step.distance),
      duration: parseInt(step.duration),
    })),
  };
}

/**
 * 批量路径规划（用于多目标优化）
 */
async function batchCalculateRoutes(hospitalLocation, targets) {
  const promises = targets.map(target => 
    calculateRoute(
      hospitalLocation.lng, 
      hospitalLocation.lat, 
      target.location.coordinates[0], 
      target.location.coordinates[1]
    ).then(route => ({
      ...target,
      route,
    })).catch(err => ({
      ...target,
      route: null,
      error: err.message,
    }))
  );
  
  return Promise.all(promises);
}

module.exports = { calculateRoute, batchCalculateRoutes };
```

---

### 3️⃣ 急救规划引擎 (`rescuePlannerService.js`)

**核心功能**：综合所有数据生成个性化救援方案

```javascript
const { reverseGeocode } = require('./geocodingService');
const { calculateRoute, batchCalculateRoutes } = require('./routingService');
const { rankSosList } = require('../utils/priorityRanker');

/**
 * 生成单个求救者的完整救援计划
 */
async function generateSingleRescuePlan(sosRecord, nearestHospitals = []) {
  const [lng, lat] = sosRecord.location.coordinates;
  
  // 1. 获取详细地址
  let addressInfo = null;
  try {
    addressInfo = await reverseGeocode(lng, lat);
  } catch (err) {
    console.warn('[RescuePlanner] 地址解析失败:', err.message);
  }
  
  // 2. 计算到最近医院的路线
  let routeToHospital = null;
  if (nearestHospitals.length > 0) {
    const nearestHospital = nearestHospitals[0];
    try {
      routeToHospital = await calculateRoute(
        lng, lat,
        nearestHospital.location[0], nearestHospital.location[1]
      );
    } catch (err) {
      console.warn('[RescuePlanner] 路径规划失败:', err.message);
    }
  }
  
  // 3. 提取医疗档案关键信息
  const medicalProfile = sosRecord.medicalProfile || {};
  const criticalInfo = [];
  
  if (medicalProfile.medicalHistory && medicalProfile.medicalHistory !== '无') {
    criticalInfo.push(`病史: ${medicalProfile.medicalHistory}`);
  }
  if (medicalProfile.allergies && medicalProfile.allergies !== '无') {
    criticalInfo.push(`⚠️ 过敏: ${medicalProfile.allergies}`);
  }
  if (medicalProfile.emergencyContact) {
    criticalInfo.push(`紧急联系人: ${medicalProfile.emergencyContact}`);
  }
  
  // 4. 组装救援计划
  return {
    senderMac: sosRecord.senderMac,
    priority: sosRecord.priority,
    
    // 位置信息
    location: {
      coordinates: [lng, lat],
      address: addressInfo?.formattedAddress || '地址解析失败',
      detailed: addressInfo?.addressComponent,
      nearbyLandmarks: addressInfo?.pois || [],
    },
    
    // 医疗信息
    medical: {
      bloodType: sosRecord.bloodType,
      profile: medicalProfile,
      criticalNotes: criticalInfo,
    },
    
    // 救援路线
    route: routeToHospital ? {
      distanceKm: (routeToHospital.distance / 1000).toFixed(2),
      estimatedTimeMin: Math.ceil(routeToHospital.duration / 60),
      tolls: routeToHospital.tolls,
      keySteps: routeToHospital.steps.slice(0, 5).map(s => s.instruction), // 前5步导航
      fullSteps: routeToHospital.steps,
    } : null,
    
    // 推荐医院
    recommendedHospitals: nearestHospitals.slice(0, 3).map(h => ({
      name: h.name,
      distanceKm: (h.distance / 1000).toFixed(2),
      estimatedTimeMin: Math.ceil(h.duration / 60),
    })),
    
    // AI建议
    aiRecommendations: generateAiRecommendations(sosRecord, addressInfo, routeToHospital),
  };
}

/**
 * 生成AI建议文本（供LLM进一步优化）
 */
function generateAiRecommendations(sosRecord, addressInfo, route) {
  const recommendations = [];
  const priority = sosRecord.priority;
  const medical = sosRecord.medicalProfile || {};
  
  // 基于严重程度的建议
  if (priority.severityLevel === 'critical') {
    recommendations.push(' 危重级别：建议立即派遣救护车，优先开通绿色通道');
  } else if (priority.severityLevel === 'urgent') {
    recommendations.push('⚡ 紧急级别：建议在30分钟内到达现场');
  }
  
  // 基于病史的建议
  if (medical.medicalHistory?.includes('心脏病')) {
    recommendations.push('💊 患者有心脏病史，请携带除颤仪和硝酸甘油');
  }
  if (medical.medicalHistory?.includes('糖尿病')) {
    recommendations.push('🩸 患者有糖尿病史，请准备葡萄糖注射液');
  }
  if (medical.allergies && medical.allergies !== '无') {
    recommendations.push(`⚠️ 过敏警示：避免使用含${medical.allergies}成分的药物`);
  }
  
  // 基于位置的建议
  if (addressInfo?.pois?.some(p => p.type.includes('医院'))) {
    recommendations.push('🏥 附近有医疗机构，可考虑就近送医');
  }
  
  // 基于时间的建议
  if (priority.elapsedMin > 60) {
    recommendations.push(`⏰ 已等待${priority.elapsedMin}分钟，情况可能恶化，需加速救援`);
  }
  
  return recommendations;
}

/**
 * 批量救援计划优化（旅行商问题简化版）
 */
async function optimizeBatchRescue(targets, hospitalLocation) {
  // 1. 计算每个目标到医院的路径
  const targetsWithRoutes = await batchCalculateRoutes(hospitalLocation, targets);
  
  // 2. 按优先级分数降序排列
  const sorted = targetsWithRoutes.sort((a, b) => 
    (b.priority?.score || 0) - (a.priority?.score || 0)
  );
  
  // 3. 贪心算法：优先救援高分且路程短的目标
  const optimizedOrder = [];
  const visited = new Set();
  
  while (optimizedOrder.length < sorted.length) {
    // 找到未访问的最高性价比目标（分数/距离）
    let bestIdx = -1;
    let bestScore = -Infinity;
    
    for (let i = 0; i < sorted.length; i++) {
      if (visited.has(i)) continue;
      
      const target = sorted[i];
      const efficiency = (target.priority?.score || 0) / 
                         ((target.route?.distance || 1) / 1000); // 分数每公里
      
      if (efficiency > bestScore) {
        bestScore = efficiency;
        bestIdx = i;
      }
    }
    
    if (bestIdx >= 0) {
      optimizedOrder.push(sorted[bestIdx]);
      visited.add(bestIdx);
    }
  }
  
  return {
    totalTargets: optimizedOrder.length,
    estimatedTotalTimeMin: optimizedOrder.reduce((sum, t) => 
      sum + Math.ceil((t.route?.duration || 0) / 60), 0),
    sequence: optimizedOrder.map((t, idx) => ({
      order: idx + 1,
      mac: t.senderMac,
      priority: t.priority,
      address: t.location?.address || '未知',
      estimatedArrival: Math.ceil((t.route?.duration || 0) / 60),
    })),
  };
}

module.exports = { 
  generateSingleRescuePlan, 
  optimizeBatchRescue,
  generateAiRecommendations 
};
```

---

### 4️⃣ 扩展API路由 (`routes/sos.js`)

在现有文件末尾添加新接口：

```javascript
const { generateSingleRescuePlan, optimizeBatchRescue } = require('../services/rescuePlannerService');

/**
 * GET /api/sos/ai/rescue-plan/:mac
 * 
 * 获取指定求救者的完整救援计划
 * 包含：详细地址、路线规划、医疗建议、推荐医院
 */
router.get('/ai/rescue-plan/:mac', async (req, res) => {
  try {
    const { mac } = req.params;
    const { hospitalLng, hospitalLat } = req.query; // 可选：指定医院位置
    
    // 查询求救记录
    const sosRecord = await SosRecord.findOne({ 
      senderMac: mac.toUpperCase(),
      status: 'active' 
    }).lean({ virtuals: true });
    
    if (!sosRecord) {
      return res.status(404).json({ error: '未找到活跃的求救记录' });
    }
    
    // 重新计算优先级
    const ranked = rankSosList([sosRecord]);
    sosRecord.priority = ranked[0]?.priority || null;
    
    // 获取最近的医院列表（示例数据，实际应从数据库查询）
    const hospitals = [
      {
        name: '市第一人民医院',
        location: [hospitalLng || 116.397, hospitalLat || 39.918], // 默认北京
        distance: 0,
        duration: 0,
      },
    ];
    
    // 生成救援计划
    const plan = await generateSingleRescuePlan(sosRecord, hospitals);
    
    return res.status(200).json({ data: plan });
  } catch (err) {
    console.error('[GET /ai/rescue-plan]', err);
    return res.status(500).json({ error: '服务器内部错误' });
  }
});

/**
 * POST /api/sos/ai/batch-rescue-plan
 * 
 * 批量救援计划优化
 * 输入：多个求救者MAC列表 + 出发点（医院/救援队位置）
 * 输出：最优救援顺序 + 预计总耗时
 */
router.post('/ai/batch-rescue-plan', async (req, res) => {
  try {
    const { macs, originLng, originLat } = req.body;
    
    if (!Array.isArray(macs) || macs.length === 0) {
      return res.status(400).json({ error: '请提供有效的MAC地址列表' });
    }
    
    // 查询所有求救记录
    const sosRecords = await SosRecord.find({
      senderMac: { $in: macs.map(m => m.toUpperCase()) },
      status: 'active',
    }).lean({ virtuals: true });
    
    if (sosRecords.length === 0) {
      return res.status(404).json({ error: '未找到任何活跃的求救记录' });
    }
    
    // 重新计算优先级
    const ranked = rankSosList(sosRecords);
    
    // 优化救援顺序
    const optimization = await optimizeBatchRescue(ranked, {
      lng: originLng || 116.397,
      lat: originLat || 39.918,
    });
    
    return res.status(200).json({ data: optimization });
  } catch (err) {
    console.error('[POST /ai/batch-rescue-plan]', err);
    return res.status(500).json({ error: '服务器内部错误' });
  }
});
```

---

### 5️⃣ 增强LLM Prompt (`llmService.js`)

修改 `answerQuestion` 函数，提供更丰富的上下文：

```javascript
async function answerQuestion(question, contextData) {
  // 如果有详细的救援计划数据，优先使用
  if (contextData.rescuePlans && contextData.rescuePlans.length > 0) {
    const plansContext = contextData.rescuePlans.map(plan => `
## 求救者 ${plan.senderMac} 详细信息
- **姓名**: ${plan.medical.profile.name || '未知'} (${plan.medical.profile.age || '?'}岁)
- **位置**: ${plan.location.address}
- **坐标**: [${plan.location.coordinates.join(', ')}]
- **血型**: ${plan.medical.bloodType === -1 ? '未知' : ['A', 'B', 'AB', 'O'][plan.medical.bloodType]}
- **病史**: ${plan.medical.profile.medicalHistory || '无'}
- **过敏**: ${plan.medical.profile.allergies || '无'}
- **优先级**: ${plan.priority.score}分 (${plan.priority.severityLevel})
- **等待时长**: ${plan.priority.elapsedMin}分钟
- **到最近医院**: ${plan.route ? `${plan.route.distanceKm}km, 约${plan.route.estimatedTimeMin}分钟` : '未计算'}
- **关键建议**: ${plan.aiRecommendations.join('; ')}
`).join('\n\n');

    return chatCompletion([
      { role: 'system', content: '你是应急救援指挥中心的智能分析助手。你拥有详细的求救者信息，包括姓名、具体地址、医疗档案、路线规划等。请基于这些精确数据回答问题，提供可执行的救援建议。如果涉及隐私敏感信息（如完整身份证号），请适当脱敏。' },
      { role: 'user', content: `${plansContext}\n\n用户问题：${question}` },
    ]);
  }
  
  // 降级到原有逻辑
  const contextStr = `...`; // 原有代码
  return chatCompletion([...]);
}
```

---

## 🖼️ 前端展示优化 (`AIPanel.vue`)

### 新增Tab："🗺️ 救援规划"

```vue
<!-- 在 tabs 数组中添加 -->
const tabs = [
  { key: 'priority', label: '🎯 优先级' },
  { key: 'risk', label: '⚠ 风险区域' },
  { key: 'summary', label: '📊 态势摘要' },
  { key: 'planning', label: '🗺️ 救援规划' },  // ← 新增
  { key: 'chat', label: '🤖 智能问答' },
]

<!-- 新增 Tab 内容 -->
<div v-show="currentTab === 'planning'" class="ai-content">
  <div class="panel-title">
    <span class="icon">◆</span> AI 救援路线规划
  </div>
  
  <!-- 选择求救者 -->
  <div class="planning-selector">
    <select v-model="selectedMac" @change="fetchRescuePlan">
      <option value="">-- 选择求救者 --</option>
      <option v-for="item in priorityList" :key="item.senderMac" :value="item.senderMac">
        #{{ item.priority.score }}分 | {{ item.medicalProfile?.name || item.senderMac }} | {{ item.priority.severityLevel }}
      </option>
    </select>
    <button @click="optimizeAllRoutes" :disabled="optimizing">
      {{ optimizing ? '优化中...' : '🔄 批量优化' }}
    </button>
  </div>
  
  <!-- 显示救援计划 -->
  <div v-if="currentPlan" class="rescue-plan-card">
    <div class="plan-header">
      <h3>{{ currentPlan.medical.profile.name || '未知' }}</h3>
      <span :class="['severity-badge', currentPlan.priority.severityLevel]">
        {{ severityLabel(currentPlan.priority.severityLevel) }}
      </span>
    </div>
    
    <div class="plan-section">
      <h4>📍 当前位置</h4>
      <p>{{ currentPlan.location.address }}</p>
      <small>坐标: [{{ currentPlan.location.coordinates.join(', ') }}]</small>
      <div v-if="currentPlan.location.nearbyLandmarks.length" class="landmarks">
        <strong>周边:</strong>
        <span v-for="(poi, idx) in currentPlan.location.nearbyLandmarks" :key="idx">
          {{ poi.name }}({{ poi.distance }}m)
        </span>
      </div>
    </div>
    
    <div class="plan-section">
      <h4>🏥 推荐医院</h4>
      <div v-for="(hospital, idx) in currentPlan.recommendedHospitals" :key="idx" class="hospital-item">
        <span>{{ hospital.name }}</span>
        <span>{{ hospital.distanceKm }}km · {{ hospital.estimatedTimeMin }}分钟</span>
      </div>
    </div>
    
    <div v-if="currentPlan.route" class="plan-section">
      <h4>🛣️ 救援路线</h4>
      <div class="route-summary">
        <span>距离: {{ currentPlan.route.distanceKm }}km</span>
        <span>预计: {{ currentPlan.route.estimatedTimeMin }}分钟</span>
        <span v-if="currentPlan.route.tolls > 0">过路费: ¥{{ currentPlan.route.tolls }}</span>
      </div>
      <details>
        <summary>查看详细导航步骤</summary>
        <ol>
          <li v-for="(step, idx) in currentPlan.route.fullSteps" :key="idx">
            {{ step.instruction }} ({{ (step.distance / 1000).toFixed(2) }}km)
          </li>
        </ol>
      </details>
    </div>
    
    <div class="plan-section">
      <h4>⚕️ 医疗注意事项</h4>
      <ul>
        <li v-for="(rec, idx) in currentPlan.aiRecommendations" :key="idx">
          {{ rec }}
        </li>
      </ul>
    </div>
    
    <div class="plan-actions">
      <button @click="copyPlanToClipboard">📋 复制计划</button>
      <button @click="exportToPdf">📄 导出PDF</button>
      <button @click="sendToAmbulance">🚑 发送给救护车</button>
    </div>
  </div>
  
  <div v-else class="empty-state">
    请选择一个求救者查看详细救援计划
  </div>
</div>
```

---

## 📦 依赖安装

```bash
cd server
npm install axios dotenv
```

---

## 🔑 环境变量配置

编辑 `server/.env`：

```bash
# 高德地图 API Key（申请地址：https://lbs.amap.com/）
AMAP_API_KEY=your_amap_web_service_key

# 阿里云百炼 LLM API Key
DASHSCOPE_API_KEY=sk-your-dashscope-key

# LLM 模型选择
LLM_MODEL=qwen-plus

# 服务器端口
PORT=3000
```

---

## ✅ 预期效果

### 改进前后对比

| 维度 | 改进前 | 改进后 |
|------|--------|--------|
| **位置精度** | 仅省份 | 街道门牌号 + 周边POI |
| **路线规划** | ❌ 无 | ✅ 详细导航步骤 + ETA |
| **医疗信息** | 部分脱敏 | ✅ 完整病历 + 过敏警示 |
| **AI回答质量** | "无法回答" | ✅ 基于精确数据的 actionable 建议 |
| **救援效率** | 人工判断 | ✅ 算法优化救援顺序 |

### 典型对话示例

**用户问**："张三在哪里？怎么最快救他？"

**AI答**：
```
张三位于北京市朝阳区建国路88号SOHO现代城A座15层。

🚑 救援建议：
1. 派出救护车从协和医院出发，沿东长安街向东行驶
2. 全程8.2km，预计22分钟到达（当前路况畅通）
3. 患者有心脏病史，请携带除颤仪和硝酸甘油
4. 对青霉素过敏，避免使用该类药物
5. 附近3km内有朝阳医院可作为备选送医点

📞 紧急联系人：李四 138****5678
```

---

## 🚀 实施路线图

### Phase 1：基础能力建设（1周）
- [ ] 注册高德地图开发者账号，获取API Key
- [ ] 实现 `geocodingService.js` 和 `routingService.js`
- [ ] 添加 `/api/sos/ai/rescue-plan/:mac` 接口
- [ ] 测试单点救援计划生成

### Phase 2：批量优化（1周）
- [ ] 实现 `optimizeBatchRescue` 算法
- [ ] 添加 `/api/sos/ai/batch-rescue-plan` 接口
- [ ] 前端新增"救援规划"Tab
- [ ] 集成路线可视化（可在地图上绘制路径）

### Phase 3：LLM增强（1周）
- [ ] 升级 `answerQuestion` Prompt，融入详细救援计划
- [ ] 测试复杂问答场景（如"给我规划一条最优救援路线，覆盖所有危重病人"）
- [ ] 添加语音播报功能（TTS）

### Phase 4：生产部署（1周）
- [ ] 压力测试（并发100+请求）
- [ ] 添加缓存层（Redis缓存地理编码结果）
- [ ] 监控告警（API配额预警）
- [ ] 文档完善 + 培训

---

## ⚠️ 注意事项

1. **API配额管理**
   - 高德免费额度：每日5000次请求
   - 超出需购买商业授权
   - 建议添加Redis缓存减少重复调用

2. **隐私保护**
   - 姓名、电话等敏感信息在前端展示时需二次确认
   - 导出PDF时自动脱敏非必要字段
   - 符合《个人信息保护法》要求

3. **离线降级**
   - 当地图API不可用时，回退到纯坐标显示
   - LLM不可用时，显示规则引擎生成的固定模板

4. **准确性验证**
   - 定期抽样验证地址解析准确率
   - 与实际路况对比ETA误差率
   - 建立反馈机制修正算法参数

---

## 📚 参考资料

- [高德地图Web服务API](https://lbs.amap.com/api/webservice/summary/)
- [阿里云百炼大模型平台](https://help.aliyun.com/zh/model-studio/)
- [MongoDB GeoJSON查询](https://www.mongodb.com/docs/manual/reference/operator/query/near/)
- [旅行商问题(TSP)近似算法](https://en.wikipedia.org/wiki/Travelling_salesman_problem)

---

**下一步行动**：是否需要我帮您实现上述某个具体模块的代码？或者您有其他定制需求？
