/**
 * 路径规划服务
 * 提供两点之间的路线计算、距离、预计时间等功能
 * 
 * 支持的地图服务商：
 * - 高德地图 (AMap) - 推荐国内使用
 * - 百度地图 (Baidu) - 备选
 */

// ============================================================================
// 🔑 API 配置区域 - 请在此处填入您的 API Key
// ============================================================================

/**
 * 【必填】高德地图 Web Service API Key（与地理编码共用）
 * 已在 geocodingService.js 中配置，此处复用
 */
const AMAP_API_KEY = process.env.AMAP_API_KEY || 'YOUR_AMAP_API_KEY_HERE';

/**
 * 【可选】百度地图 AK（与地理编码共用）
 */
const BAIDU_MAP_AK = process.env.BAIDU_MAP_AK || 'YOUR_BAIDU_MAP_AK_HERE';

/**
 * 【可选】是否启用缓存
 */
const ENABLE_ROUTECACHE = process.env.ENABLE_ROUTECACHE === 'true';

// ============================================================================
// 服务实现
// ============================================================================

let redisClient = null;

if (ENABLE_ROUTECACHE) {
  try {
    const redis = require('redis');
    redisClient = redis.createClient({
      url: process.env.REDIS_URL || 'redis://localhost:6379',
    });
    redisClient.connect().catch(console.error);
  } catch (err) {
    console.warn('[Routing] Redis 连接失败，缓存功能已禁用:', err.message);
  }
}

/**
 * 从缓存获取路线（如果启用）
 */
async function getCachedRoute(cacheKey) {
  if (!ENABLE_ROUTECACHE || !redisClient) return null;
  
  try {
    const cached = await redisClient.get(cacheKey);
    return cached ? JSON.parse(cached) : null;
  } catch (err) {
    console.warn('[Routing] 缓存读取失败:', err.message);
    return null;
  }
}

/**
 * 写入缓存（如果启用）
 */
async function setCachedRoute(cacheKey, data, ttlSeconds = 3600) {
  if (!ENABLE_ROUTECACHE || !redisClient) return;
  
  try {
    await redisClient.setEx(cacheKey, ttlSeconds, JSON.stringify(data));
  } catch (err) {
    console.warn('[Routing] 缓存写入失败:', err.message);
  }
}

/**
 * 使用高德地图计算驾车路线
 * @param {number} originLng - 起点经度
 * @param {number} originLat - 起点纬度
 * @param {number} destLng - 终点经度
 * @param {number} destLat - 终点纬度
 * @param {Object} [options] - 可选参数
 * @param {string} [options.strategy='0'] - 路径策略 (0=速度优先, 1=费用优先, 2=距离优先等)
 * @param {boolean} [options.avoidHighway=false] - 是否避开高速
 * @returns {Promise<Object>} 路线信息对象
 */
async function calculateDrivingRoute(originLng, originLat, destLng, destLat, options = {}) {
  const cacheKey = `route:amap:${originLng.toFixed(5)},${originLat.toFixed(5)}-${destLng.toFixed(5)},${destLat.toFixed(5)}-${options.strategy || '0'}`;
  
  // 尝试从缓存获取
  const cached = await getCachedRoute(cacheKey);
  if (cached) {
    return cached;
  }
  
  if (AMAP_API_KEY === 'YOUR_AMAP_API_KEY_HERE') {
    throw new Error('AMAP_API_KEY 未配置，请在 server/.env 中添加高德地图 API Key');
  }
  
  const baseUrl = 'https://restapi.amap.com/v3/direction/driving';
  const params = new URLSearchParams({
    origin: `${originLng},${originLat}`,
    destination: `${destLng},${destLat}`,
    key: AMAP_API_KEY,
    strategy: options.strategy || '0',
    avoidhighway: options.avoidHighway ? '1' : '0',
    show_fields: 'cost,polyline',
  });
  
  const response = await fetch(`${baseUrl}?${params}`);
  const data = await response.json();
  
  if (data.status !== '1') {
    throw new Error(`高德地图路径规划错误 (${data.infocode}): ${data.info}`);
  }
  
  if (!data.route.paths || data.route.paths.length === 0) {
    throw new Error('未找到可行路线');
  }
  
  const path = data.route.paths[0]; // 取第一条路线
  
  const result = {
    provider: 'amap',
    distance: parseInt(path.distance), // 米
    duration: parseInt(path.duration), // 秒
    tolls: parseFloat(path.tolls || 0), // 过路费元
    trafficLights: parseInt(path.traffic_lights || 0), // 红绿灯数
    
    // 路线概览
    overview: {
      startAddress: data.route.origin?.name || '',
      endAddress: data.route.destination?.name || '',
      taxiCost: parseFloat(path.taxi_cost || 0), // 打车费用估算
    },
    
    // 详细步骤
    steps: (path.steps || []).map((step, idx) => ({
      stepIndex: idx + 1,
      instruction: step.instruction, // 导航指令文本
      action: step.action, // 动作类型
      orientation: step.orientation, // 方向
      road: step.road, // 道路名称
      distance: parseInt(step.distance), // 本段距离（米）
      duration: parseInt(step.duration), // 本段时间（秒）
      polyline: step.polyline, // 坐标串（用于地图绘制）
      assistNodes: step.assist_nodes || [], // 辅助节点
    })),
    
    // 原始数据（供调试）
    raw: path,
  };
  
  // 写入缓存
  await setCachedRoute(cacheKey, result);
  
  return result;
}

/**
 * 使用百度地图计算驾车路线（备用方案）
 * @param {number} originLng - 起点经度
 * @param {number} originLat - 起点纬度
 * @param {number} destLng - 终点经度
 * @param {number} destLat - 终点纬度
 * @returns {Promise<Object>} 路线信息对象
 */
async function calculateDrivingRouteWithBaidu(originLng, originLat, destLng, destLat) {
  const cacheKey = `route:baidu:${originLng.toFixed(5)},${originLat.toFixed(5)}-${destLng.toFixed(5)},${destLat.toFixed(5)}`;
  
  // 尝试从缓存获取
  const cached = await getCachedRoute(cacheKey);
  if (cached) {
    return cached;
  }
  
  if (BAIDU_MAP_AK === 'YOUR_BAIDU_MAP_AK_HERE') {
    throw new Error('BAIDU_MAP_AK 未配置，请在 server/.env 中添加百度地图 AK');
  }
  
  const baseUrl = 'https://api.map.baidu.com/directionlite/v1/driving';
  const params = new URLSearchParams({
    ak: BAIDU_MAP_AK,
    origin: `${originLat},${originLng}`, // 注意：百度是 lat,lng 顺序
    destination: `${destLat},${destLng}`,
    coord_type_input: 'wgs84',
    coord_type_output: 'bd09ll',
  });
  
  const response = await fetch(`${baseUrl}?${params}`);
  const data = await response.json();
  
  if (data.status !== 0) {
    throw new Error(`百度地图路径规划错误 (${data.status}): ${data.message}`);
  }
  
  const result_data = data.result.routes[0];
  
  return {
    provider: 'baidu',
    distance: parseInt(result_data.distance),
    duration: parseInt(result_data.duration),
    tolls: 0, // 百度免费版不提供过路费
    trafficLights: 0,
    
    overview: {
      startAddress: '',
      endAddress: '',
      taxiCost: 0,
    },
    
    steps: (result_data.steps || []).map((step, idx) => ({
      stepIndex: idx + 1,
      instruction: step.instructions,
      action: '',
      orientation: '',
      road: step.road_name || '',
      distance: parseInt(step.distance),
      duration: parseInt(step.duration),
      polyline: step.polyline,
      assistNodes: [],
    })),
    
    raw: result_data,
  };
}

/**
 * 统一的路径规划接口
 * @param {number} originLng - 起点经度
 * @param {number} originLat - 起点纬度
 * @param {number} destLng - 终点经度
 * @param {number} destLat - 终点纬度
 * @param {Object} [options] - 可选参数
 * @param {string} [options.provider='amap'] - 地图提供商
 * @param {string} [options.strategy='0'] - 路径策略
 * @returns {Promise<Object>} 路线信息对象
 */
async function calculateRoute(originLng, originLat, destLng, destLat, options = {}) {
  // 验证坐标
  const isValidCoord = (lng, lat) => 
    lng >= -180 && lng <= 180 && lat >= -90 && lat <= 90;
  
  if (!isValidCoord(originLng, originLat) || !isValidCoord(destLng, destLat)) {
    throw new Error(`无效坐标: origin=[${originLng}, ${originLat}], dest=[${destLng}, ${destLat}]`);
  }
  
  const provider = options.provider || 'amap';
  
  try {
    switch (provider.toLowerCase()) {
      case 'amap':
      case 'gaode':
        return await calculateDrivingRoute(originLng, originLat, destLng, destLat, options);
      case 'baidu':
        return await calculateDrivingRouteWithBaidu(originLng, originLat, destLng, destLat);
      default:
        throw new Error(`不支持的地图提供商: ${provider}`);
    }
  } catch (err) {
    console.error(`[Routing] ${provider} 路径规划失败:`, err.message);
    
    // 如果是主提供商失败，尝试备用方案
    if (provider === 'amap' && BAIDU_MAP_AK !== 'YOUR_BAIDU_MAP_AK_HERE') {
      console.log('[Routing] 尝试切换到百度地图...');
      return await calculateDrivingRouteWithBaidu(originLng, originLat, destLng, destLat);
    }
    
    throw err;
  }
}

/**
 * 批量计算路线（用于多目标优化）
 * @param {Object} origin - 起点 {lng, lat}
 * @param {Array} destinations - 终点数组 [{lng, lat, id}, ...]
 * @param {number} [concurrency=3] - 并发数
 * @returns {Promise<Array>} 路线结果数组
 */
async function batchCalculateRoutes(origin, destinations, concurrency = 3) {
  const results = [];
  const queue = [...destinations];
  const inProgress = new Set();
  
  return new Promise((resolve, reject) => {
    const processNext = async () => {
      if (queue.length === 0 && inProgress.size === 0) {
        resolve(results);
        return;
      }
      
      while (inProgress.size < concurrency && queue.length > 0) {
        const dest = queue.shift();
        const index = destinations.indexOf(dest);
        inProgress.add(index);
        
        calculateRoute(origin.lng, origin.lat, dest.lng, dest.lat)
          .then(route => {
            results[index] = {
              ...dest,
              route,
              success: true,
            };
          })
          .catch(err => {
            results[index] = {
              ...dest,
              error: err.message,
              success: false,
            };
          })
          .finally(() => {
            inProgress.delete(index);
            processNext();
          });
      }
    };
    
    processNext();
  });
}

/**
 * 计算直线距离（Haversine公式，无需API）
 * @param {number} lng1 - 起点经度
 * @param {number} lat1 - 起点纬度
 * @param {number} lng2 - 终点经度
 * @param {number} lat2 - 终点纬度
 * @returns {number} 距离（米）
 */
function calculateStraightDistance(lng1, lat1, lng2, lat2) {
  const R = 6371e3; // 地球半径（米）
  const φ1 = (lat1 * Math.PI) / 180;
  const φ2 = (lat2 * Math.PI) / 180;
  const Δφ = ((lat2 - lat1) * Math.PI) / 180;
  const Δλ = ((lng2 - lng1) * Math.PI) / 180;
  
  const a = Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
            Math.cos(φ1) * Math.cos(φ2) *
            Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  
  return Math.round(R * c);
}

module.exports = {
  calculateRoute,
  batchCalculateRoutes,
  calculateDrivingRoute,
  calculateDrivingRouteWithBaidu,
  calculateStraightDistance,
};
