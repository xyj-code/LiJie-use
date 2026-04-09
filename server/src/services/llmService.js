/**
 * LLM analysis service.
 * Uses DashScope's OpenAI-compatible chat completions API.
 */

const DASHSCOPE_BASE_URL = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
const LLM_MODEL = process.env.LLM_MODEL || 'qwen-plus';

async function chatCompletion(messages) {
  const apiKey = process.env.DASHSCOPE_API_KEY;
  if (!apiKey) {
    throw new Error('DASHSCOPE_API_KEY is not configured. Please update server/.env');
  }

  const response = await fetch(`${DASHSCOPE_BASE_URL}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: LLM_MODEL,
      messages,
      temperature: 0.1,
      max_tokens: 1600,
    }),
  });

  if (!response.ok) {
    const errBody = await response.text();
    throw new Error(`LLM API call failed (${response.status}): ${errBody}`);
  }

  const data = await response.json();
  return data.choices[0].message.content;
}

async function generateSituationReport(data) {
  const prompt = `你是应急救援指挥中心分析助手。请根据以下实时数据，生成简洁、专业的中文态势摘要。

概览：
- 求救点总数：${data.total}
- 危重人数：${data.criticalCount}
- 紧急人数：${data.urgentCount}
- 血型分布：${JSON.stringify(data.bloodDistribution)}

省份分布：
${(data.provinceDistribution || []).map((p) => `- ${p.name}: ${p.count} 个`).join('\n')}

等待最久：
${(data.longestWaiting || [])
  .map((w) => `- 等待 ${w.elapsedMin} 分钟 | 等级 ${w.severityLevel} | 病史 ${w.medicalHistory || '无'}`)
  .join('\n')}

最高优先级：
${(data.topPriorities || [])
  .map((p, i) => `- #${i + 1} | 分数 ${p.score} | 等级 ${p.severityLevel} | 病史 ${p.medicalHistory || '无'}`)
  .join('\n')}

要求：
1. 用中文输出。
2. 先写整体态势，再写重点风险，最后写行动建议。
3. 内容简洁，不空泛。`;

  return chatCompletion([
    {
      role: 'system',
      content: '你是应急救援指挥中心分析助手，擅长输出简洁专业的中文态势报告。',
    },
    { role: 'user', content: prompt },
  ]);
}

function formatCase(item, index) {
  return [
    `- #${index + 1}`,
    `姓名: ${item.name || '未登记'}`,
    `MAC: ${item.mac}`,
    `年龄: ${item.age || '未知'}`,
    `优先级分数: ${item.priorityScore}`,
    `等级: ${item.severityLevel}`,
    `等待时长: ${item.elapsedMin} 分钟`,
    `血型: ${item.bloodTypeName}`,
    `病史: ${item.medicalHistory || '无'}`,
    `过敏: ${item.allergies || '无'}`,
    `紧急联系人: ${item.emergencyContact || '无'}`,
    `位置: ${item.locationText}`,
    item.addressText ? `地址概述: ${item.addressText}` : null,
    item.nearbyLandmark ? `附近地标: ${item.nearbyLandmark}` : null,
    item.formattedAddress ? `详细地址: ${item.formattedAddress}` : null,
    `置信度: ${item.confidence}`,
  ].filter(Boolean).join(' | ');
}

function formatPlan(plan) {
  const route = plan.routeSummary;
  const hospitals = (plan.recommendedHospitals || [])
    .map((hospital) => `${hospital.name}(${hospital.distanceKm}km, 约${hospital.estimatedTimeMinutes}分钟)`)
    .join('；');

  return [
    `- 规划对象: ${plan.name || '未登记'} / ${plan.mac}`,
    `优先级: ${plan.priorityScore} (${plan.severityLevel})`,
    `地址: ${plan.address || '未知'}`,
    route
      ? `推荐路线: 前往${route.toHospital}，距离${route.distanceKm}km，预计${route.estimatedTimeMinutes}分钟，过路费${route.tolls}`
      : '推荐路线: 无',
    plan.dispatchHint ? `调度提示: ${plan.dispatchHint}` : '调度提示: 无',
    hospitals ? `候选医院: ${hospitals}` : '候选医院: 无',
    plan.aiRecommendations?.length ? `行动建议: ${plan.aiRecommendations.join('；')}` : '行动建议: 无',
  ].join(' | ');
}

function formatChatContext(contextData = {}) {
  const summary = contextData.summary || {};
  const rankedCases = Array.isArray(contextData.rankedCases) ? contextData.rankedCases : [];
  const generatedPlans = Array.isArray(contextData.generatedPlans) ? contextData.generatedPlans : [];
  const intent = contextData.intent || 'general';

  const sections = [
    '## 当前态势',
    `- 问题意图: ${intent}`,
    `- 活跃求救点总数: ${summary.total ?? 0}`,
    `- 危重: ${summary.criticalCount ?? 0}`,
    `- 紧急: ${summary.urgentCount ?? 0}`,
  ];

  if (rankedCases.length > 0) {
    sections.push('## 相关个案');
    sections.push(rankedCases.map(formatCase).join('\n'));
  }

  if (generatedPlans.length > 0) {
    sections.push('## 自动生成的救援规划');
    sections.push(generatedPlans.map(formatPlan).join('\n'));
  }

  return sections.join('\n');
}

function buildFriendlyRouteSteps(route) {
  const fullSteps = Array.isArray(route?.fullSteps) ? route.fullSteps : [];
  if (fullSteps.length === 0) {
    return Array.isArray(route?.keySteps) ? route.keySteps.slice(0, 6) : [];
  }

  return fullSteps.slice(0, 6).map((step, index) => formatDrivingStep(step, index, fullSteps.length));
}

function formatDrivingStep(step, index, totalSteps) {
  const road = String(step?.road || '').trim();
  const orientation = String(step?.orientation || '').trim();
  const action = String(step?.action || '').trim();
  const distance = Number.isFinite(step?.distance) ? `${step.distance}米` : '';

  const roadText = road ? `沿${road}` : '从当前位置';
  const moveText = orientation && distance ? `向${orientation}行驶${distance}` : (distance ? `行驶${distance}` : '继续前进');

  if (index === totalSteps - 1) {
    if (action) {
      return `${roadText}${moveText}后${action}，即可到达目的地。`;
    }
    return `${roadText}${moveText}，即可到达目的地。`;
  }

  if (action) {
    return `${roadText}${moveText}后${action}。`;
  }

  return `${roadText}${moveText}。`;
}

function buildDeterministicAnswer(question, contextData = {}) {
  const intent = contextData.intent || 'general';
  const rankedCases = Array.isArray(contextData.rankedCases) ? contextData.rankedCases : [];
  const generatedPlans = Array.isArray(contextData.generatedPlans) ? contextData.generatedPlans : [];
  const normalizedQuestion = String(question || '');

  if (intent === 'route_plan' && generatedPlans.length > 0) {
    const plan = generatedPlans[0];
    const route = plan.routeSummary;
    const topHospital = (plan.recommendedHospitals || [])[0] || null;
    const target = plan.name ? `${plan.name} / ${plan.mac}` : plan.mac;
    const wantsDetailedRoute = /路线|怎么走|如何走|怎么去|过去|导航|步骤/.test(normalizedQuestion);

    if (route) {
      const routeLines = [
        `对象: ${target}`,
        `最近医院: ${route.toHospital}`,
        `路线: ${route.distanceKm} km，约 ${route.estimatedTimeMinutes} 分钟`,
        plan.address ? `位置: ${plan.address}` : null,
        plan.dispatchHint ? `调度提示: ${plan.dispatchHint}` : null,
      ].filter(Boolean);

      if (wantsDetailedRoute && Array.isArray(route.keySteps) && route.keySteps.length > 0) {
        routeLines.push('导航步骤:');
        buildFriendlyRouteSteps(route).forEach((step, index) => {
          routeLines.push(`${index + 1}. ${step}`);
        });
      }

      return routeLines.join('\n');
    }

    if (topHospital) {
      return [
        `对象: ${target}`,
        `最近医院: ${topHospital.name}`,
        `距离: ${topHospital.distanceKm} km，约 ${topHospital.estimatedTimeMinutes} 分钟`,
      ].join('\n');
    }

    return '无法确认。';
  }

  if (intent === 'location' && rankedCases.length > 0) {
    const item = rankedCases[0];
    return [
      item.name ? `对象: ${item.name} / ${item.mac}` : `对象: ${item.mac}`,
      item.addressText ? `位置: ${item.addressText}` : null,
      item.nearbyLandmark ? `附近地标: ${item.nearbyLandmark}` : null,
      item.locationText ? `坐标: ${item.locationText}` : null,
    ].filter(Boolean).join('\n');
  }

  return null;
}

async function answerQuestion(question, contextData) {
  const deterministicAnswer = buildDeterministicAnswer(question, contextData);
  if (deterministicAnswer) {
    return deterministicAnswer;
  }

  const contextStr = formatChatContext(contextData);

  return chatCompletion([
    {
      role: 'system',
      content:
        '你是救援指挥中心的智能调度助手。请严格遵守以下规则：'
        + '\n1. 只能使用上下文中的事实，不得编造。'
        + '\n2. 若无法从当前数据直接回答，唯一允许输出是“无法确认。”'
        + '\n3. 只回答用户问题本身，不要扩写无关信息。'
        + '\n4. 禁止补充电话、药品、输血、设备、收费、医院内部流程等未提供信息。'
        + '\n5. 可给出保守的调度级建议，如呼叫120、提前通知接诊医院、属地就近调度、跨区域协同。'
        + '\n6. 不要输出具体药物、剂量、输血、设备准备、侵入性操作。'
        + '\n7. 如果已有路线明显超长，要明确指出属地就近调度或跨区域协同。'
        + '\n8. 回答保持简洁、准确，适合指挥席直接阅读。',
    },
    {
      role: 'user',
      content:
        `${contextStr}\n\n## 用户问题\n${question}\n\n`
        + '要求：'
        + '\n- 仅使用与问题直接相关的字段回答。'
        + '\n- 如果是人员查询，优先回答姓名、MAC、等待时长、位置。'
        + '\n- 如果是位置问题，优先回答区县、街道、附近地标或建筑；有坐标时可附坐标。'
        + '\n- 如果是规划/路线/送医问题，优先回答路线、医院、调度提示、立即行动。'
        + '\n- 如果是优先级问题，优先回答对象、分数、等级、等待时长和简短建议。'
        + '\n- 无法确认时，只输出“无法确认。”',
    },
  ]);
}

module.exports = { generateSituationReport, answerQuestion };
