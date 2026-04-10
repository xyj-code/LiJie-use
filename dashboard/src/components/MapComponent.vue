<template>
  <div ref="mapEl" class="map-wrap">
    <div v-if="currentRouteState" :class="['route-hud', { compact: isRouteHudCompact }]">
      <div class="route-hud-head">
        <div class="route-hud-head-copy">
          <div class="route-hud-title">导航路线已锁定</div>
          <div class="route-hud-subtitle">
            {{ currentRouteState.name || currentRouteState.mac }} → {{ currentRouteState.hospitalName }}
          </div>
        </div>
        <div class="route-hud-tools">
          <button class="route-hud-icon-btn" @click="toggleRouteHudCompact">
            {{ isRouteHudCompact ? '展开' : '收起' }}
          </button>
          <button class="route-hud-icon-btn" @click="clearRouteOverlay">关闭</button>
        </div>
      </div>
      <div v-if="isRouteHudCompact" class="route-hud-compact-summary">
        <span>{{ currentRouteState.route?.distanceKm || '--' }} km</span>
        <span>{{ currentRouteState.route?.estimatedTimeMinutes || '--' }} 分钟</span>
        <span>{{ activeRouteStepIndex >= 0 ? `步骤 #${activeRouteStepIndex + 1}` : '全线' }}</span>
      </div>
      <div v-else class="route-hud-metrics">
        <div class="route-hud-metric">
          <span class="route-hud-label">总距离</span>
          <strong>{{ currentRouteState.route?.distanceKm || '--' }} km</strong>
        </div>
        <div class="route-hud-metric">
          <span class="route-hud-label">预计时间</span>
          <strong>{{ currentRouteState.route?.estimatedTimeMinutes || '--' }} 分钟</strong>
        </div>
        <div class="route-hud-metric">
          <span class="route-hud-label">当前步骤</span>
          <strong>{{ activeRouteStepIndex >= 0 ? `#${activeRouteStepIndex + 1}` : '全线' }}</strong>
        </div>
      </div>
      <div v-if="!isRouteHudCompact" class="route-hud-step">
        {{ activeRouteStepIndex >= 0 ? getActiveRouteStepText() : '已高亮整条推荐路线，地图上的编号节点可与右侧步骤对应。' }}
      </div>
      <div v-if="!isRouteHudCompact" class="route-hud-actions">
        <button class="route-hud-btn" @click="focusWholeRoute">查看全线</button>
        <button class="route-hud-btn ghost" @click="clearRouteOverlay">隐藏路线</button>
      </div>
      <div v-if="!isRouteHudCompact" class="route-hud-note">虚线表示求救点或医院与实际可通行道路起终点之间的偏移。</div>
    </div>
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
let routeLayerGroup = null
let staleTimer  = null
const currentRouteState = ref(null)
const activeRouteStepIndex = ref(-1)
const isRouteHudCompact = ref(false)
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

function clearRouteOverlay() {
  routeLayerGroup?.clearLayers()
  currentRouteState.value = null
  activeRouteStepIndex.value = -1
  isRouteHudCompact.value = false
  setHeatmapRouteMode(false)
}

function toggleRouteHudCompact() {
  isRouteHudCompact.value = !isRouteHudCompact.value
}

function decodeStepPolyline(step) {
  const segments = String(step?.polyline || '').split(';').filter(Boolean)
  const points = []
  let lastKey = null

  segments.forEach((pair) => {
    const [lng, lat] = pair.split(',').map(Number)
    if (!Number.isFinite(lng) || !Number.isFinite(lat)) return
    const key = `${lat.toFixed(6)},${lng.toFixed(6)}`
    if (key === lastKey) return
    lastKey = key
    points.push([lat, lng])
  })

  return points
}

function decodeRoutePolyline(route) {
  const steps = Array.isArray(route?.fullSteps) ? route.fullSteps : []
  const points = []
  let lastKey = null

  steps.forEach((step) => {
    decodeStepPolyline(step).forEach(([lat, lng]) => {
      const key = `${lat.toFixed(6)},${lng.toFixed(6)}`
      if (key === lastKey) return
      lastKey = key
      points.push([lat, lng])
    })
  })

  return points
}

function calcMeters(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b)) return 0
  const toRad = (deg) => (deg * Math.PI) / 180
  const [lat1, lng1] = a
  const [lat2, lng2] = b
  const dLat = toRad(lat2 - lat1)
  const dLng = toRad(lng2 - lng1)
  const lat1Rad = toRad(lat1)
  const lat2Rad = toRad(lat2)
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(lat1Rad) * Math.cos(lat2Rad) * Math.sin(dLng / 2) ** 2
  return 6371000 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h))
}

function setHeatmapRouteMode(active) {
  if (!heatLayer?._canvas) return
  heatLayer._canvas.style.opacity = active ? '0.18' : '1'
  heatLayer._canvas.style.filter = active ? 'saturate(0.65)' : 'saturate(1)'
  heatLayer._canvas.style.transition = 'opacity 180ms ease, filter 180ms ease'
}

function makeEndpointIcon(kind, label) {
  return L.divIcon({
    className: '',
    html: `<div class="route-endpoint ${kind}">
      <div class="route-endpoint-badge">${kind === 'start' ? 'SOS' : '医'}</div>
      <div class="route-endpoint-label">${label}</div>
    </div>`,
    iconSize: [120, 34],
    iconAnchor: [18, 17],
    popupAnchor: [0, -16],
  })
}

function makeAnchorIcon(kind) {
  return L.divIcon({
    className: '',
    html: `<div class="route-anchor ${kind}"></div>`,
    iconSize: [12, 12],
    iconAnchor: [6, 6],
  })
}

function makeTurnIcon(index, active = false) {
  return L.divIcon({
    className: '',
    html: `<div class="route-turn-marker ${active ? 'active' : ''}">${index + 1}</div>`,
    iconSize: [24, 24],
    iconAnchor: [12, 12],
  })
}

function renderTurnMarkers(route) {
  const steps = Array.isArray(route?.fullSteps) ? route.fullSteps.slice(0, 6) : []
  steps.forEach((step, index) => {
    const stepPoints = decodeStepPolyline(step)
    if (stepPoints.length === 0) return
    const marker = L.marker(stepPoints[stepPoints.length - 1], {
      icon: makeTurnIcon(index, activeRouteStepIndex.value === index),
      zIndexOffset: 900 + index,
    })
      .bindPopup(`<div class="sos-popup"><div class="p-title">步骤 ${index + 1}</div><div class="p-row"><span>${step.instruction || ''}</span><span>${step.distance || 0}m</span></div></div>`)
      .on('click', () => highlightRouteStep(index))
      .addTo(routeLayerGroup)
    marker.stepIndex = index
  })
}

function rebuildRouteOverlay(detail, options = {}) {
  if (!map || !routeLayerGroup || !detail?.route) return

  const { focusBounds = true } = options
  currentRouteState.value = detail
  setHeatmapRouteMode(true)
  routeLayerGroup.clearLayers()

  const points = decodeRoutePolyline(detail.route)
  if (points.length < 2) return

  const routeShadow = L.polyline(points, {
    color: '#031623',
    weight: 12,
    opacity: 0.94,
    lineJoin: 'round',
    lineCap: 'round',
  }).addTo(routeLayerGroup)

  const routeGlow = L.polyline(points, {
    color: '#23e7ff',
    weight: 6,
    opacity: 0.98,
    lineJoin: 'round',
    lineCap: 'round',
  }).addTo(routeLayerGroup)

  const startCoords = Array.isArray(detail.route.sourceCoordinates)
    ? [detail.route.sourceCoordinates[1], detail.route.sourceCoordinates[0]]
    : points[0]
  const endCoords = Array.isArray(detail.route.destinationCoordinates)
    ? [detail.route.destinationCoordinates[1], detail.route.destinationCoordinates[0]]
    : points[points.length - 1]
  const routeStart = points[0]
  const routeEnd = points[points.length - 1]

  L.marker(startCoords, {
    icon: makeEndpointIcon('start', detail.name || detail.mac || '求救点'),
    zIndexOffset: 1200,
  })
    .bindPopup(
      `<div class="sos-popup route-popup"><div class="p-title">求救点</div><div class="p-row"><span>${detail.name || detail.mac || ''}</span><span>${detail.address || ''}</span></div></div>`,
      { className: 'route-popup-wrap', maxWidth: 320 },
    )
    .addTo(routeLayerGroup)

  L.marker(endCoords, {
    icon: makeEndpointIcon('end', detail.hospitalName || '目的医院'),
    zIndexOffset: 1200,
  })
    .bindPopup(
      `<div class="sos-popup route-popup"><div class="p-title">目的医院</div><div class="p-row"><span>${detail.hospitalName || '医院'}</span><span>${detail.route.distanceKm || ''} km</span></div></div>`,
      { className: 'route-popup-wrap', maxWidth: 320 },
    )
    .addTo(routeLayerGroup)

  if (calcMeters(startCoords, routeStart) > 20) {
    L.polyline([startCoords, routeStart], {
      color: '#00f0b8',
      weight: 2,
      opacity: 0.8,
      dashArray: '6, 6',
    }).addTo(routeLayerGroup)
    L.marker(routeStart, { icon: makeAnchorIcon('start'), interactive: false }).addTo(routeLayerGroup)
  }

  if (calcMeters(routeEnd, endCoords) > 20) {
    L.polyline([routeEnd, endCoords], {
      color: '#ffd966',
      weight: 2,
      opacity: 0.8,
      dashArray: '6, 6',
    }).addTo(routeLayerGroup)
    L.marker(routeEnd, { icon: makeAnchorIcon('end'), interactive: false }).addTo(routeLayerGroup)
  }

  renderTurnMarkers(detail.route)

  if (focusBounds) {
    map.fitBounds(routeShadow.getBounds(), {
      paddingTopLeft: [40, 120],
      paddingBottomRight: [40, 60],
      maxZoom: 16,
    })
  }

  if (activeRouteStepIndex.value >= 0) {
    highlightRouteStep(activeRouteStepIndex.value, { fly: false, rerender: false })
  }
}

function showRouteOverlay(detail) {
  if (!map || !routeLayerGroup || !detail?.route) return
  activeRouteStepIndex.value = -1
  rebuildRouteOverlay(detail)
}

function highlightRouteStep(stepIndex, options = {}) {
  const detail = currentRouteState.value
  const route = detail?.route
  const steps = Array.isArray(route?.fullSteps) ? route.fullSteps : []
  if (!route || stepIndex == null || stepIndex < 0 || stepIndex >= steps.length) {
    activeRouteStepIndex.value = -1
    if (detail) rebuildRouteOverlay(detail, { focusBounds: false })
    return
  }

  const { fly = true, rerender = true } = options
  activeRouteStepIndex.value = stepIndex
  if (rerender && detail) {
    rebuildRouteOverlay(detail, { focusBounds: false })
  }

  const stepPoints = decodeStepPolyline(steps[stepIndex])
  if (stepPoints.length < 2) return

  const emphasisShadow = L.polyline(stepPoints, {
    color: '#ffffff',
    weight: 12,
    opacity: 0.14,
    lineCap: 'round',
    lineJoin: 'round',
  }).addTo(routeLayerGroup)

  const emphasisLine = L.polyline(stepPoints, {
    color: '#ffea5b',
    weight: 7,
    opacity: 1,
    lineCap: 'round',
    lineJoin: 'round',
  }).addTo(routeLayerGroup)

  emphasisShadow.bringToFront()
  emphasisLine.bringToFront()

  if (fly) {
    map.fitBounds(emphasisLine.getBounds(), {
      paddingTopLeft: [50, 140],
      paddingBottomRight: [50, 80],
      maxZoom: 17,
    })
  }

  window.dispatchEvent(new CustomEvent('map-route-step-changed', {
    detail: { stepIndex },
  }))
}

function getActiveRouteStepText() {
  const steps = currentRouteState.value?.route?.fullSteps || []
  const step = steps[activeRouteStepIndex.value]
  return step?.instruction || '已锁定当前步骤。'
}

function focusWholeRoute() {
  if (!currentRouteState.value) return
  activeRouteStepIndex.value = -1
  rebuildRouteOverlay(currentRouteState.value)
  window.dispatchEvent(new CustomEvent('map-route-step-changed', {
    detail: { stepIndex: -1 },
  }))
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
  setHeatmapRouteMode(false)
  
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
  routeLayerGroup = L.layerGroup().addTo(map)

  mapReady.value = true
  
  // 加载省份边界
  loadProvinceBoundary()
})

onUnmounted(() => {
  map?.remove()
  window.removeEventListener('map-flyto', handleFlyTo)
  window.removeEventListener('map-show-route', handleShowRoute)
  window.removeEventListener('map-flyto-area', handleFlyToArea)
  window.removeEventListener('map-highlight-route-step', handleHighlightRouteStep)
  window.removeEventListener('map-focus-route', handleFocusRoute)
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

function handleShowRoute(e) {
  showRouteOverlay(e.detail)
}
window.addEventListener('map-show-route', handleShowRoute)

function handleHighlightRouteStep(e) {
  const stepIndex = Number(e.detail?.stepIndex)
  const detail = e.detail?.routeOverlay
  if (!currentRouteState.value && detail?.route) {
    showRouteOverlay(detail)
  }
  if (!Number.isInteger(stepIndex) || stepIndex < 0) {
    focusWholeRoute()
    return
  }
  highlightRouteStep(stepIndex)
}
window.addEventListener('map-highlight-route-step', handleHighlightRouteStep)

function handleFocusRoute(e) {
  const detail = e?.detail
  if (!currentRouteState.value && detail?.route) {
    showRouteOverlay(detail)
    return
  }
  focusWholeRoute()
}
window.addEventListener('map-focus-route', handleFocusRoute)

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

.route-hud {
  position: absolute;
  top: 14px;
  left: 14px;
  z-index: 950;
  width: min(360px, calc(100% - 28px));
  min-width: 240px;
  max-width: 460px;
  min-height: 96px;
  resize: both;
  overflow: auto;
  padding: 12px 14px;
  border-radius: 14px;
  border: 1px solid rgba(0, 229, 255, 0.16);
  background: linear-gradient(180deg, rgba(3, 19, 32, 0.95), rgba(1, 10, 22, 0.92));
  box-shadow: 0 18px 45px rgba(0, 0, 0, 0.28);
  backdrop-filter: blur(12px);
}

.route-hud.compact {
  width: min(300px, calc(100% - 28px));
  min-height: auto;
  resize: horizontal;
}

.route-hud-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 10px;
}

.route-hud-head-copy {
  min-width: 0;
  flex: 1;
}

.route-hud-tools {
  display: flex;
  gap: 6px;
  flex-shrink: 0;
}

.route-hud-icon-btn {
  height: 28px;
  padding: 0 10px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(255, 255, 255, 0.05);
  color: rgba(227, 246, 255, 0.82);
  font-size: 0.6rem;
  cursor: pointer;
}

.route-hud-icon-btn:hover {
  background: rgba(255, 255, 255, 0.1);
}

.route-hud-title {
  color: #9ff6ff;
  font-size: 0.78rem;
  font-weight: bold;
  letter-spacing: 0.06em;
}

.route-hud-subtitle {
  margin-top: 3px;
  color: rgba(208, 244, 255, 0.8);
  font-size: 0.67rem;
  line-height: 1.45;
  word-break: break-word;
}

.route-hud-compact-summary {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  color: rgba(220, 247, 255, 0.9);
  font-size: 0.64rem;
  line-height: 1.5;
}

.route-hud-metrics {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 8px;
}

.route-hud-metric {
  padding: 8px;
  border-radius: 10px;
  background: rgba(6, 28, 45, 0.82);
  border: 1px solid rgba(0, 229, 255, 0.08);
}

.route-hud-label {
  display: block;
  color: rgba(167, 212, 226, 0.62);
  font-size: 0.58rem;
  margin-bottom: 3px;
}

.route-hud-metric strong {
  color: #f2feff;
  font-size: 0.8rem;
}

.route-hud-step {
  margin-top: 10px;
  padding: 9px 10px;
  border-radius: 10px;
  background: rgba(10, 35, 57, 0.74);
  color: rgba(227, 248, 255, 0.88);
  font-size: 0.64rem;
  line-height: 1.5;
}

.route-hud-actions {
  display: flex;
  gap: 8px;
  margin-top: 10px;
}

.route-hud-btn {
  height: 30px;
  padding: 0 12px;
  border-radius: 999px;
  border: 1px solid rgba(0, 229, 255, 0.18);
  background: rgba(0, 229, 255, 0.1);
  color: #aaf4ff;
  font-size: 0.62rem;
  cursor: pointer;
}

.route-hud-btn.ghost {
  background: rgba(255, 255, 255, 0.04);
  color: rgba(217, 240, 250, 0.82);
}

.route-hud-note {
  margin-top: 9px;
  color: rgba(157, 200, 214, 0.56);
  font-size: 0.56rem;
  line-height: 1.45;
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

.route-endpoint {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-width: 110px;
  padding: 4px 10px 4px 4px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  box-shadow: 0 10px 24px rgba(0, 0, 0, 0.24);
  backdrop-filter: blur(10px);
}

.route-endpoint.start {
  background: rgba(255, 84, 84, 0.18);
}

.route-endpoint.end {
  background: rgba(255, 214, 56, 0.18);
}

.route-endpoint-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 26px;
  border-radius: 50%;
  font-size: 12px;
  font-weight: bold;
}

.route-endpoint.start .route-endpoint-badge {
  background: #ff5b5b;
  color: #fff;
  box-shadow: 0 0 18px rgba(255, 91, 91, 0.45);
}

.route-endpoint.end .route-endpoint-badge {
  background: #ffd44a;
  color: #201600;
  box-shadow: 0 0 18px rgba(255, 212, 74, 0.4);
}

.route-endpoint-label {
  max-width: 150px;
  color: #eefcff;
  font-size: 12px;
  font-family: 'Courier New', monospace;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.route-anchor {
  width: 12px;
  height: 12px;
  border-radius: 50%;
  border: 2px solid rgba(255, 255, 255, 0.95);
  box-shadow: 0 0 14px rgba(255, 255, 255, 0.18);
}

.route-anchor.start {
  background: #00f0b8;
}

.route-anchor.end {
  background: #ffd966;
}

.route-turn-marker {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 24px;
  height: 24px;
  border-radius: 50%;
  background: rgba(2, 18, 31, 0.92);
  border: 2px solid rgba(0, 229, 255, 0.75);
  color: #b7fbff;
  font-family: 'Courier New', monospace;
  font-size: 12px;
  font-weight: bold;
  box-shadow: 0 0 12px rgba(0, 229, 255, 0.24);
}

.route-turn-marker.active {
  border-color: rgba(255, 234, 91, 0.95);
  color: #fff4a3;
  box-shadow: 0 0 16px rgba(255, 234, 91, 0.35);
}

.route-popup-wrap .leaflet-popup-content-wrapper {
  background: linear-gradient(180deg, rgba(6, 20, 36, 0.98), rgba(3, 13, 25, 0.98));
  color: #effbff;
  border: 1px solid rgba(0, 229, 255, 0.18);
  border-radius: 16px;
  box-shadow: 0 16px 40px rgba(0, 0, 0, 0.36);
}

.route-popup-wrap .leaflet-popup-content {
  margin: 14px 16px;
  min-width: 220px;
}

.route-popup-wrap .leaflet-popup-tip {
  background: rgba(3, 13, 25, 0.98);
}

.route-popup .p-title {
  color: #ff7878;
  font-size: 0.96rem;
  font-weight: bold;
  margin-bottom: 10px;
}

.route-popup .p-row {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  padding-top: 8px;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  color: #eef8ff;
  font-size: 0.78rem;
  line-height: 1.5;
}

.route-popup .p-row span:first-child {
  color: rgba(177, 220, 235, 0.74);
}

.route-popup .p-row span:last-child {
  color: #dff4ff;
  text-align: right;
}
</style>
