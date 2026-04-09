<template>
  <div ref="mapEl" class="map-wrap">
    <!-- 扫描线特效 -->
    <div class="scan-line"></div>
  </div>
</template>

<script setup>
import { ref, watchEffect, watch, onMounted, onUnmounted } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import 'leaflet.heat'
import 'leaflet.markercluster'
import 'leaflet.markercluster/dist/MarkerCluster.css'
import 'leaflet.markercluster/dist/MarkerCluster.Default.css'
import { useSocket, BLOOD_LABELS } from '../composables/useSocket'

const { alerts, searchState } = useSocket()
const mapEl    = ref(null)
const mapReady = ref(false)

let map         = null
let heatLayer   = null
let markerGroup = null
let provinceLayer = null
let staleTimer  = null
const added = new Map()   // key → marker ref，用于标记时效管理
const STALE_THRESHOLD = 30 * 60 * 1000  // 30 分钟

// 省份边界 GeoJSON 数据源（阿里云 DataV）
const PROVINCE_BOUNDARY_URL = 'https://geo.datav.aliyun.com/areas_v3/bound/100000_full.json'

// CartoDB Dark Matter 底图
const TILE = 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'

// 热力图配置
const HEAT_CONFIG = {
  radius: 35,
  blur: 25,
  maxZoom: 10,
  max: 1.0,
  gradient: {
    0.0: '#0066ff',
    0.25: '#00ffff',
    0.5: '#00ff88',
    0.75: '#ffcc00',
    1.0: '#ff3333',
  }
}

function updateHeatmap() {
  if (!map || !heatLayer) return
  
  // 只统计active状态的求救点
  const heatPoints = alerts.value
    .filter(sos => sos.status === 'active' && sos.location?.coordinates)
    .map(sos => {
      const [lng, lat] = sos.location.coordinates
      // 权重：中继次数越多，热度越高
      const weight = Math.min((sos.reportedBy?.length ?? 1) / 5, 1.0)
      return [lat, lng, weight]
    })
  
  heatLayer.setLatLngs(heatPoints)
}

function mkIcon() {
  return L.divIcon({
    className: '',
    html: `<div class="sos-marker">
             <div class="sos-dot"></div>
             <div class="sos-ring"></div>
             <div class="sos-ring r2"></div>
           </div>`,
    iconSize:    [30, 30],
    iconAnchor:  [15, 15],
    popupAnchor: [0, -18],
  })
}

function mkPopup(sos) {
  const bt   = sos.medicalProfile?.bloodTypeDetail !== undefined 
    ? BLOOD_LABELS[sos.medicalProfile.bloodTypeDetail] ?? '未知'
    : BLOOD_LABELS[sos.bloodType] ?? '未知'
  const time = new Date(sos.timestamp).toLocaleString('zh-CN')
  const relay = sos.reportedBy?.length ?? 1
  const mp = sos.medicalProfile || {}
  const [lng, lat] = sos.location?.coordinates || [0, 0]
  
  return `<div class="sos-popup">
    <div class="p-title">⚠ SOS 求救信号</div>
    <div class="p-row"><span>设备 MAC</span><span>${sos.senderMac}</span></div>
    ${mp.name ? `<div class="p-row"><span>姓名</span><span class="hi-green">${mp.name}</span></div>` : ''}
    ${mp.age ? `<div class="p-row"><span>年龄</span><span>${mp.age}</span></div>` : ''}
    <div class="p-row"><span>血型</span><span class="hi-red">${bt}</span></div>
    ${mp.allergies ? `<div class="p-row"><span class="warn">⚠ 过敏</span><span class="hi-orange">${mp.allergies}</span></div>` : ''}
    ${mp.medicalHistory ? `<div class="p-row"><span>病史</span><span>${mp.medicalHistory}</span></div>` : ''}
    ${mp.emergencyContact ? `<div class="p-row"><span>联系人</span><span class="hi-purple">${mp.emergencyContact}</span></div>` : ''}
    <div class="p-row"><span>坐标</span><span class="coord">${lng.toFixed(4)}°E, ${lat.toFixed(4)}°N</span></div>
    <div class="p-row"><span>求救时间</span><span>${time}</span></div>
    <div class="p-row"><span>中继次数</span><span class="hi">${relay} 次</span></div>
    <div class="p-row"><span>置信度</span><span class="hi">${sos.confidence ?? relay}</span></div>
  </div>`
}

function mkClusterPopup(cluster) {
  const members = cluster.getAllChildMarkers()
  const names = members
    .map(m => m.options.sosData?.medicalProfile?.name || m.options.sosData?.senderMac || '')
    .filter(Boolean)
  return `<div class="sos-popup sos-cluster-popup">
    <div class="p-title">📍 聚合区域 · ${members.length} 人</div>
    <div class="cluster-names">${names.map(n => `<span class="name-tag">${n}</span>`).join('')}</div>
  </div>`
}

function addMarker(sos) {
  const key = `${sos.senderMac}|${sos.timestamp}`
  if (added.has(key) || !map) return

  const [lng, lat] = sos.location.coordinates
  const marker = L.marker([lat, lng], { 
    icon: mkIcon(),
    sosData: sos
  })
    .bindPopup(mkPopup(sos), { className: 'sos-popup-wrap', maxWidth: 260 })
  
  markerGroup.addLayer(marker)
  
  // 入场爆闪动画
  setTimeout(() => {
    const el = marker.getElement()
    if (el) el.classList.add('flash-in')
  }, 50)
  
  // 记录标记引用
  added.set(key, marker)
  
  // 定时检查标记是否过期变旧
  scheduleStaleCheck()
}

function scheduleStaleCheck() {
  if (staleTimer) clearTimeout(staleTimer)
  staleTimer = setTimeout(updateStaleMarkers, 5000)
}

function updateStaleMarkers() {
  const now = Date.now()
  for (const [key, marker] of added) {
    const ts = marker.options.sosData?.timestamp
    if (!ts) continue
    const age = now - new Date(ts).getTime()
    const el = marker.getElement()
    if (!el) continue
    if (age > STALE_THRESHOLD) {
      el.classList.add('stale')
    } else {
      el.classList.remove('stale')
    }
  }
  // 继续轮询
  scheduleStaleCheck()
}

async function loadProvinceBoundary() {
  try {
    const res = await fetch(PROVINCE_BOUNDARY_URL)
    const geojson = await res.json()
    provinceLayer = L.geoJSON(geojson, {
      style: {
        color: 'rgba(0, 180, 255, 0.35)',
        weight: 1.2,
        fillColor: 'transparent',
        dashArray: '4, 6',
      },
    }).addTo(map)
  } catch (e) {
    console.warn('[Map] 省份边界加载失败:', e)
  }
}

// watchEffect：mapReady + alerts 双重依赖
// 每次 alerts 有新项或地图就绪时重跑，dedup 由 added Map 保证
watchEffect(() => {
  if (!mapReady.value) return
  alerts.value.forEach(addMarker)
  updateHeatmap()
})

onMounted(() => {
  map = L.map(mapEl.value, {
    center: [35.86, 104.19],
    zoom: 5,
    zoomControl: false,
    attributionControl: false,
    fadeAnimation: true,
    zoomAnimation: true,
    markerZoomAnimation: false,
  })

  // 地图容器底色设为深色，避免瓦片加载间隙露白/露黑
  mapEl.value.style.background = '#0a0e17'

  const tileLayer = L.tileLayer(TILE, {
    maxZoom: 19,
    maxNativeZoom: 19,
    subdomains: 'abcd',
    updateWhenIdle: false,
    updateWhenZooming: true,
    updateInterval: 200,
    keepBuffer: 4,
    fadeAnimation: true,
  }).addTo(map)
  L.control.zoom({ position: 'bottomright' }).addTo(map)
  
  // 初始化热力图层
  heatLayer = L.heatLayer([], { ...HEAT_CONFIG }).addTo(map)
  
  // 初始化标记聚类组
  markerGroup = L.markerClusterGroup({
    maxClusterRadius: 40,        // 减小聚类半径，减少计算量
    spiderfyOnMaxZoom: true,
    showCoverageOnHover: false,
    zoomToBoundsOnClick: true,
    disableClusteringAtZoom: 15, // 超过此zoom级别自动解散
    iconCreateFunction: function(cluster) {
      const count = cluster.getChildCount()
      let size = 'small'
      if (count > 10) size = 'large'
      else if (count > 5) size = 'medium'
      return L.divIcon({
        html: `<div class="cluster-icon ${size}">${count}</div>`,
        className: 'cluster-wrapper',
        iconSize: L.point(40, 40)
      })
    }
  })
  markerGroup.on('clusterclick', function(a) {
    if (map.getZoom() === map.getMaxZoom()) {
      a.layer.bindPopup(mkClusterPopup(a.layer), { className: 'sos-popup-wrap', maxWidth: 320 }).openPopup()
    }
  })
  map.addLayer(markerGroup)

  mapReady.value = true
  
  // 加载省份边界
  loadProvinceBoundary()
})

onUnmounted(() => {
  map?.remove()
  window.removeEventListener('map-flyto', handleFlyTo)
})

// 监听搜索状态变化，高亮/淡化标记
watch(() => searchState.activeKeys, () => {
  if (!mapReady.value) return
  for (const [, marker] of added) {
    const key = `${marker.options.sosData?.senderMac}|${marker.options.sosData?.timestamp}`
    const el = marker.getElement()
    if (!el) continue
    if (searchState.hasFilter && !searchState.activeKeys.has(key)) {
      el.classList.add('dimmed')
      el.classList.remove('highlighted')
    } else if (searchState.activeKeys.has(key)) {
      el.classList.remove('dimmed')
      el.classList.add('highlighted')
    } else {
      el.classList.remove('dimmed', 'highlighted')
    }
  }
}, { deep: true })

// 监听自定义 fly-to 事件
function handleFlyTo(e) {
  flyToSos(e.detail)
}
window.addEventListener('map-flyto', handleFlyTo)

// 监听飞入风险区域事件
function handleFlyToArea(e) {
  if (!map) return
  const { center, count } = e.detail
  const [lng, lat] = center
  const zoom = count >= 8 ? 10 : count >= 5 ? 11 : 12
  map.flyTo([lat, lng], zoom, { duration: 1.2 })
}
window.addEventListener('map-flyto-area', handleFlyToArea)

// 暴露给父组件：飞到指定求救点位置并打开弹窗
function flyToSos(sos) {
  if (!map || !sos?.location?.coordinates) return
  const [lng, lat] = sos.location.coordinates
  // 找到对应 marker
  for (const [, marker] of added) {
    if (marker.options.sosData?.senderMac === sos.senderMac &&
        marker.options.sosData?.timestamp === sos.timestamp) {
      map.flyTo([lat, lng], 14, { duration: 1.2 })
      setTimeout(() => marker.openPopup(), 1300)
      return
    }
  }
  // 没找到精确匹配，飞到坐标处
  map.flyTo([lat, lng], 12, { duration: 1.2 })
}

defineExpose({ flyToSos })
</script>

<style scoped>
.map-wrap {
  position: relative;
  width: 100%;
  height: 100%;
  border-radius: 6px;
  overflow: hidden;
  border: 1px solid rgba(0, 200, 255, 0.2);
  box-shadow: inset 0 0 30px rgba(0, 10, 30, 0.6);
}
/* 扫描线特效 */
.scan-line {
  position: absolute;
  left: 0; right: 0;
  height: 2px;
  background: linear-gradient(90deg, transparent, rgba(0, 229, 255, 0.4), transparent);
  animation: scan-line 6s linear infinite;
  z-index: 800;
  pointer-events: none;
}
</style>

<!-- 全局样式：聚类标记 + 弹窗 -->
<style>
/* 聚类图标容器 */
.cluster-wrapper {
  background: none;
  border: none;
}

/* 聚类圆形图标 */
.cluster-icon {
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  color: #fff;
  font-weight: bold;
  font-family: 'Courier New', monospace;
  font-size: 14px;
  border: 2px solid rgba(255, 255, 255, 0.6);
  box-shadow: 0 0 12px rgba(0, 200, 255, 0.5);
}

.cluster-icon.small {
  width: 30px; height: 30px;
  background: radial-gradient(circle, #00ccff, #0066aa);
  font-size: 12px;
}

.cluster-icon.medium {
  width: 40px; height: 40px;
  background: radial-gradient(circle, #ffcc00, #ff8800);
  font-size: 14px;
}

.cluster-icon.large {
  width: 50px; height: 50px;
  background: radial-gradient(circle, #ff3333, #cc0000);
  font-size: 16px;
  animation: cluster-pulse 2s ease-in-out infinite;
}

@keyframes cluster-pulse {
  0%, 100% { box-shadow: 0 0 12px rgba(255, 51, 51, 0.5); }
  50% { box-shadow: 0 0 24px rgba(255, 51, 51, 0.8); }
}

/* 聚类弹窗 */
.sos-cluster-popup {
  min-width: 180px;
  max-width: 320px;
}

.sos-cluster-popup .cluster-names {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 8px;
}

.sos-cluster-popup .name-tag {
  display: inline-block;
  padding: 2px 8px;
  background: rgba(0, 200, 255, 0.15);
  border: 1px solid rgba(0, 200, 255, 0.3);
  border-radius: 4px;
  color: #00e5ff;
  font-size: 12px;
  font-family: 'Courier New', monospace;
}

/* 覆盖 markercluster 默认样式 */
.marker-cluster-small {
  background-color: rgba(0, 204, 255, 0.2);
}
.marker-cluster-small div {
  background-color: rgba(0, 204, 255, 0.4);
  color: #fff;
}
.marker-cluster-medium {
  background-color: rgba(255, 204, 0, 0.2);
}
.marker-cluster-medium div {
  background-color: rgba(255, 204, 0, 0.4);
  color: #fff;
}
.marker-cluster-large {
  background-color: rgba(255, 51, 51, 0.2);
}
.marker-cluster-large div {
  background-color: rgba(255, 51, 51, 0.4);
  color: #fff;
}
</style>
