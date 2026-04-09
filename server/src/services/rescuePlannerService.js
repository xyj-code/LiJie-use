/**
 * 急救规划引擎
 * 综合地理编码、路径规划、医疗信息，生成完整的救援方案
 */

const { reverseGeocode } = require('./geocodingService');
const { calculateRoute, batchCalculateRoutes, calculateStraightDistance } = require('./routingService');
const { rankSosList } = require('../utils/priorityEngine');

// ============================================================================
// 🔑 配置区域
// ============================================================================

/**
 * 【可选】默认医院位置（当未指定时使用）
 * 格式：{ name: '医院名称', lng: 经度, lat: 纬度 }
 * 建议：根据实际部署地区修改为当地主要医院
 */
const DEFAULT_HOSPITALS = process.env.DEFAULT_HOSPITALS ? 
  JSON.parse(process.env.DEFAULT_HOSPITALS) : [
    {
      name: '市第一人民医院',
      lng: 116.397, // 北京示例坐标，请修改
      lat: 39.918,
    },
  ];

/**
 * 【可选】最大并发路径计算数
 */
const MAX_ROUTE_CONCURRENCY = parseInt(process.env.MAX_ROUTE_CONCURRENCY) || 5;

/**
 * 【可选】是否启用详细日志
 */
const DEBUG_MODE = process.env.DEBUG_RESCUE_PLANNER === 'true';

// ============================================================================
// 核心功能
// ============================================================================

/**
 * 生成单个求救者的完整救援计划
 * @param {Object} sosRecord - SOS记录对象（需包含 priority 字段）
 * @param {Array} [hospitals] - 候选医院列表 [{name, lng, lat}, ...]
 * @param {Object} [options] - 可选参数
 * @param {boolean} [options.includeFullSteps=true] - 是否包含完整导航步骤
 * @param {number} [options.maxNearbyHospitals=3] - 最多返回几个附近医院
 * @returns {Promise<Object>} 救援计划对象
 */
async function generateSingleRescuePlan(sosRecord, hospitals = null, options = {}) {
  const startTime = Date.now();
  
  if (DEBUG_MODE) {
    console.log(`[RescuePlanner] 开始生成救援计划: ${sosRecord.senderMac}`);
  }
  
  const {
    includeFullSteps = true,
    maxNearbyHospitals = 3,
  } = options;
  
  const [lng, lat] = sosRecord.location.coordinates;
  const hospitalList = hospitals || DEFAULT_HOSPITALS;
  
  try {
    // ==========================================================================
    // 1. 获取详细地址信息
    // ==========================================================================
    let addressInfo = null;
    try {
      addressInfo = await reverseGeocode(lng, lat);
      if (DEBUG_MODE) {
        console.log(`[RescuePlanner] ✓ 地址解析成功: ${addressInfo.formattedAddress}`);
      }
    } catch (err) {
      console.warn(`[RescuePlanner] ⚠ 地址解析失败: ${err.message}`);
      addressInfo = {
        formattedAddress: '地址解析失败',
        addressComponent: {},
        pois: [],
      };
    }
    
    // ==========================================================================
    // 2. 计算到各医院的路线，找出最近的
    // ==========================================================================
    const hospitalDistances = [];
    
    for (const hospital of hospitalList) {
      try {
        const route = await calculateRoute(
          lng, lat,
          hospital.lng, hospital.lat,
          { strategy: '0' } // 速度优先
        );
        
        hospitalDistances.push({
          ...hospital,
          distance: route.distance,
          duration: route.duration,
          route: includeFullSteps ? route : {
            distance: route.distance,
            duration: route.duration,
            tolls: route.tolls,
            overview: route.overview,
          },
        });
      } catch (err) {
        console.warn(`[RescuePlanner] ⚠ 到医院 ${hospital.name} 的路径规划失败:`, err.message);
        // 降级：使用直线距离估算
        const straightDist = calculateStraightDistance(lng, lat, hospital.lng, hospital.lat);
        hospitalDistances.push({
          ...hospital,
          distance: straightDist,
          duration: Math.round(straightDist / 500 * 60), // 假设平均时速30km/h
          error: err.message,
        });
      }
    }
    
    // 按距离排序
    hospitalDistances.sort((a, b) => a.distance - b.distance);
    const nearestHospital = hospitalDistances[0];
    
    if (DEBUG_MODE) {
      console.log(`[RescuePlanner] ✓ 最近医院: ${nearestHospital.name} (${(nearestHospital.distance / 1000).toFixed(2)}km)`);
    }
    
    // ==========================================================================
    // 3. 提取医疗档案关键信息
    // ==========================================================================
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
    if (medicalProfile.name) {
      criticalInfo.push(`姓名: ${medicalProfile.name}${medicalProfile.age ? ` (${medicalProfile.age}岁)` : ''}`);
    }
    
    // ==========================================================================
    // 4. 生成AI建议
    // ==========================================================================
    const aiRecommendations = generateAiRecommendations(sosRecord, addressInfo, nearestHospital);
    
    // ==========================================================================
    // 5. 组装最终救援计划
    // ==========================================================================
    const plan = {
      senderMac: sosRecord.senderMac,
      generatedAt: new Date().toISOString(),
      
      // 优先级信息
      priority: sosRecord.priority || {
        score: 0,
        severityLevel: 'unknown',
        elapsedMin: 0,
        breakdown: [],
      },
      
      // 位置信息
      location: {
        coordinates: [lng, lat],
        address: addressInfo.formattedAddress,
        detailed: addressInfo.addressComponent,
        nearbyLandmarks: addressInfo.pois || [],
        nearbyRoads: addressInfo.roads || [],
      },
      
      // 医疗信息
      medical: {
        bloodType: sosRecord.bloodType,
        bloodTypeName: getBloodTypeName(sosRecord.bloodType),
        profile: medicalProfile,
        criticalNotes: criticalInfo,
      },
      
      // 救援路线
      route: nearestHospital.route ? {
        toHospital: nearestHospital.name,
        distanceMeters: nearestHospital.route.distance,
        distanceKm: (nearestHospital.route.distance / 1000).toFixed(2),
        estimatedTimeSeconds: nearestHospital.route.duration,
        estimatedTimeMinutes: Math.ceil(nearestHospital.route.duration / 60),
        tolls: nearestHospital.route.tolls,
        trafficLights: nearestHospital.route.trafficLights,
        keySteps: (nearestHospital.route.steps || []).slice(0, 5).map(s => s.instruction),
        fullSteps: includeFullSteps ? nearestHospital.route.steps : undefined,
      } : null,
      
      // 推荐医院列表
      recommendedHospitals: hospitalDistances.slice(0, maxNearbyHospitals).map(h => ({
        name: h.name,
        distanceMeters: h.distance,
        distanceKm: (h.distance / 1000).toFixed(2),
        estimatedTimeMinutes: Math.ceil(h.duration / 60),
        hasError: !!h.error,
      })),
      
      // AI建议
      aiRecommendations,
      
      // 元数据
      metadata: {
        generationTimeMs: Date.now() - startTime,
        provider: addressInfo.provider || 'unknown',
      },
    };
    
    if (DEBUG_MODE) {
      console.log(`[RescuePlanner] ✓ 救援计划生成完成 (耗时 ${plan.metadata.generationTimeMs}ms)`);
    }
    
    return plan;
  } catch (err) {
    console.error('[RescuePlanner] ✗ 生成救援计划失败:', err);
    throw new Error(`救援计划生成失败: ${err.message}`);
  }
}

/**
 * 批量救援计划优化（贪心算法简化版TSP）
 * @param {Array} sosRecords - SOS记录数组
 * @param {Object} origin - 出发点 {lng, lat, name}
 * @param {Object} [options] - 可选参数
 * @param {string} [options.optimizationStrategy='efficiency'] - 优化策略 ('efficiency' | 'urgency' | 'distance')
 * @returns {Promise<Object>} 优化后的救援序列
 */
async function optimizeBatchRescue(sosRecords, origin, options = {}) {
  const startTime = Date.now();
  
  const {
    optimizationStrategy = 'efficiency', // efficiency=性价比, urgency=紧急度, distance=最短路径
  } = options;
  
  if (!sosRecords || sosRecords.length === 0) {
    throw new Error('求救记录列表不能为空');
  }
  
  if (!origin || !origin.lng || !origin.lat) {
    throw new Error('出发点坐标无效');
  }
  
  try {
    // ==========================================================================
    // 1. 重新计算所有记录的优先级
    // ==========================================================================
    const ranked = rankSosList(sosRecords);
    
    // ==========================================================================
    // 2. 批量计算到各目标的路线
    // ==========================================================================
    const destinations = ranked.map(record => ({
      mac: record.senderMac,
      lng: record.location.coordinates[0],
      lat: record.location.coordinates[1],
      priority: record.priority,
      medicalProfile: record.medicalProfile,
    }));
    
    if (DEBUG_MODE) {
      console.log(`[RescuePlanner] 开始批量路径计算 (${destinations.length}个目标)...`);
    }
    
    const targetsWithRoutes = await batchCalculateRoutes(
      origin,
      destinations,
      MAX_ROUTE_CONCURRENCY
    );
    
    // ==========================================================================
    // 3. 根据策略排序
    // ==========================================================================
    let sortedTargets;
    
    switch (optimizationStrategy) {
      case 'efficiency':
        // 性价比 = 优先级分数 / 距离(km)
        sortedTargets = targetsWithRoutes
          .filter(t => t.success && t.route)
          .sort((a, b) => {
            const efficiencyA = (a.priority?.score || 0) / ((a.route.distance || 1) / 1000);
            const efficiencyB = (b.priority?.score || 0) / ((b.route.distance || 1) / 1000);
            return efficiencyB - efficiencyA;
          });
        break;
        
      case 'urgency':
        // 纯紧急度优先
        sortedTargets = targetsWithRoutes
          .filter(t => t.success)
          .sort((a, b) => (b.priority?.score || 0) - (a.priority?.score || 0));
        break;
        
      case 'distance':
        // 最短路径优先（适合集中救援）
        sortedTargets = targetsWithRoutes
          .filter(t => t.success && t.route)
          .sort((a, b) => (a.route.distance || Infinity) - (b.route.distance || Infinity));
        break;
        
      default:
        throw new Error(`未知的优化策略: ${optimizationStrategy}`);
    }
    
    // ==========================================================================
    // 4. 生成优化序列
    // ==========================================================================
    const sequence = sortedTargets.map((target, idx) => ({
      order: idx + 1,
      mac: target.mac,
      priority: target.priority,
      medicalSummary: summarizeMedicalInfo(target.medicalProfile),
      location: {
        lng: target.lng,
        lat: target.lat,
      },
      route: target.route ? {
        distanceKm: (target.route.distance / 1000).toFixed(2),
        estimatedTimeMin: Math.ceil(target.route.duration / 60),
        tolls: target.route.tolls,
      } : null,
      cumulativeTimeMin: sortedTargets
        .slice(0, idx + 1)
        .reduce((sum, t) => sum + Math.ceil((t.route?.duration || 0) / 60), 0),
    }));
    
    const totalTimeMin = sequence.reduce((sum, item) => 
      sum + Math.ceil((item.route?.estimatedTimeMin || 0)), 0);
    
    const result = {
      optimizationStrategy,
      totalTargets: sequence.length,
      failedTargets: targetsWithRoutes.filter(t => !t.success).length,
      estimatedTotalTimeMin: totalTimeMin,
      origin: {
        name: origin.name || '出发点',
        lng: origin.lng,
        lat: origin.lat,
      },
      sequence,
      summary: generateBatchSummary(sequence),
      metadata: {
        generationTimeMs: Date.now() - startTime,
        algorithm: 'greedy_tsp_approximation',
      },
    };
    
    if (DEBUG_MODE) {
      console.log(`[RescuePlanner] ✓ 批量优化完成 (耗时 ${result.metadata.generationTimeMs}ms)`);
    }
    
    return result;
  } catch (err) {
    console.error('[RescuePlanner] ✗ 批量优化失败:', err);
    throw new Error(`批量救援优化失败: ${err.message}`);
  }
}

// ============================================================================
// 辅助函数
// ============================================================================

/**
 * 生成AI建议文本
 */
function generateAiRecommendations(sosRecord, addressInfo, nearestHospital) {
  const recommendations = [];
  const priority = sosRecord.priority || {};
  const medical = sosRecord.medicalProfile || {};
  
  // 基于严重程度
  if (priority.severityLevel === 'critical') {
    recommendations.push(' 危重级别：建议立即派遣救护车，优先开通绿色通道');
    recommendations.push('📞 提前通知医院急诊科准备抢救设备');
  } else if (priority.severityLevel === 'urgent') {
    recommendations.push('🟠 紧急级别：建议在30分钟内到达现场');
  } else if (priority.severityLevel === 'warning') {
    recommendations.push('🟡 注意级别：建议在1小时内处理');
  }
  
  // 基于病史
  if (medical.medicalHistory) {
    const history = medical.medicalHistory.toLowerCase();
    if (history.includes('心脏病') || history.includes('心脏')) {
      recommendations.push('💊 患者有心脏病史，请携带除颤仪(AED)和硝酸甘油');
    }
    if (history.includes('糖尿病')) {
      recommendations.push('🩸 患者有糖尿病史，请准备葡萄糖注射液和血糖仪');
    }
    if (history.includes('高血压')) {
      recommendations.push('🫀 患者有高血压史，避免剧烈移动，监测血压');
    }
    if (history.includes('哮喘') || history.includes('呼吸')) {
      recommendations.push('🌬️ 患者有呼吸系统疾病，请携带氧气瓶和支气管扩张剂');
    }
  }
  
  // 基于过敏
  if (medical.allergies && medical.allergies !== '无') {
    recommendations.push(`⚠️ 过敏警示：严禁使用含"${medical.allergies}"成分的药物`);
  }
  
  // 基于血型
  if (sosRecord.bloodType >= 0) {
    const bloodTypes = ['A型', 'B型', 'AB型', 'O型'];
    recommendations.push(`🩸 血型：${bloodTypes[sosRecord.bloodType]}，如需输血请提前准备`);
  }
  
  // 基于位置
  if (addressInfo?.pois?.some(p => p.type?.includes('医院'))) {
    recommendations.push('🏥 附近有医疗机构，可考虑就近送医或请求支援');
  }
  
  // 基于等待时间
  if (priority.elapsedMin > 60) {
    recommendations.push(`⏰ 已等待${priority.elapsedMin}分钟，情况可能恶化，需加速救援`);
  } else if (priority.elapsedMin > 30) {
    recommendations.push(`⏱️ 已等待${priority.elapsedMin}分钟，建议优先处理`);
  }
  
  // 基于路线
  if (nearestHospital?.route) {
    const timeMin = Math.ceil(nearestHospital.route.duration / 60);
    if (timeMin > 30) {
      recommendations.push(`🛣️ 路程较远(${timeMin}分钟)，建议途中持续监护生命体征`);
    }
    if (nearestHospital.route.tolls > 0) {
      recommendations.push(`💰 预计过路费¥${nearestHospital.route.tolls}，可申请应急报销`);
    }
  }
  
  // 默认建议
  if (recommendations.length === 0) {
    recommendations.push('✅ 按标准流程执行救援，保持通讯畅通');
  }
  
  return recommendations;
}

/**
 * 获取血型名称
 */
function getBloodTypeName(bloodTypeCode) {
  const types = {
    '-1': '未知',
    '0': 'A型',
    '1': 'B型',
    '2': 'AB型',
    '3': 'O型',
  };
  return types[String(bloodTypeCode)] || '未知';
}

/**
 * 简化医疗信息摘要
 */
function summarizeMedicalInfo(profile) {
  if (!profile) return null;
  
  const parts = [];
  if (profile.name) parts.push(profile.name);
  if (profile.age) parts.push(`${profile.age}岁`);
  if (profile.medicalHistory && profile.medicalHistory !== '无') {
    parts.push(`病史:${profile.medicalHistory}`);
  }
  if (profile.allergies && profile.allergies !== '无') {
    parts.push(`过敏:${profile.allergies}`);
  }
  
  return parts.join(' | ') || '无详细信息';
}

/**
 * 生成批量救援摘要
 */
function generateBatchSummary(sequence) {
  const severityCounts = {
    critical: 0,
    urgent: 0,
    warning: 0,
    normal: 0,
  };
  
  sequence.forEach(item => {
    const level = item.priority?.severityLevel || 'normal';
    if (severityCounts.hasOwnProperty(level)) {
      severityCounts[level]++;
    }
  });
  
  return {
    severityDistribution: severityCounts,
    averageDistanceKm: (sequence.reduce((sum, item) => 
      sum + parseFloat(item.route?.distanceKm || 0), 0) / sequence.length).toFixed(2),
    criticalFirst: sequence.findIndex(item => item.priority?.severityLevel === 'critical') + 1,
  };
}

module.exports = {
  generateSingleRescuePlan,
  optimizeBatchRescue,
  generateAiRecommendations,
  getBloodTypeName,
};
