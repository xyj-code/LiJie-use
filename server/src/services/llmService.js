/**
 * LLM 智能分析服务
 * 使用阿里云百炼（DashScope）兼容 OpenAI 格式的 API
 * 
 * 支持模型：qwen-plus / qwen-max / qwen-turbo
 * 文档：https://help.aliyun.com/zh/model-studio/developer-reference/use-qwen-by-calling-api
 */

// 如果不想装 openai 包，可以取消注释下方 fetch 实现
// const { OpenAI } = require('openai');

const DASHSCOPE_BASE_URL = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
const LLM_MODEL = process.env.LLM_MODEL || 'qwen-plus';

// ─── 方式一：使用 openai 包（推荐，需 npm install openai）───
// const openai = new OpenAI({
//   apiKey: process.env.DASHSCOPE_API_KEY,
//   baseURL: DASHSCOPE_BASE_URL,
// });

// async function chatCompletion(messages) {
//   const response = await openai.chat.completions.create({
//     model: LLM_MODEL,
//     messages,
//     temperature: 0.3,
//     max_tokens: 2000,
//   });
//   return response.choices[0].message.content;
// }

// ─── 方式二：原生 fetch 实现（无需额外依赖）───
async function chatCompletion(messages) {
  const apiKey = process.env.DASHSCOPE_API_KEY;
  if (!apiKey) {
    throw new Error('DASHSCOPE_API_KEY 未配置，请在 server/.env 中添加');
  }

  const response = await fetch(`${DASHSCOPE_BASE_URL}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: LLM_MODEL,
      messages,
      temperature: 0.3,
      max_tokens: 2000,
    }),
  });

  if (!response.ok) {
    const errBody = await response.text();
    throw new Error(`LLM API 调用失败 (${response.status}): ${errBody}`);
  }

  const data = await response.json();
  return data.choices[0].message.content;
}

/**
 * 生成自然语言态势摘要
 */
async function generateSituationReport(data) {
  const prompt = `你是一名应急救援指挥中心的智能分析助手。请根据以下实时数据，生成一段简洁专业的态势摘要报告。

## 数据概览
- 全国求救点总数：${data.total} 个
- 危重人员：${data.criticalCount} 人
- 紧急人员：${data.urgentCount} 人
- 血型分布：${JSON.stringify(data.bloodDistribution)}

## 各省分布
${(data.provinceDistribution || []).map(p => `- ${p.name}: ${p.count} 个求救点`).join('\n')}

## 等待最久的求救
${(data.longestWaiting || []).map(w => `- 等待 ${w.elapsedMin} 分钟 | 等级: ${w.severityLevel} | 病史: ${w.medicalHistory || '无'}`).join('\n')}

## 最高优先级
${(data.topPriorities || []).map((p, i) => `- #${i + 1} | 分数: ${p.score} | 等级: ${p.severityLevel} | 病史: ${p.medicalHistory || '无'} | 血型: ${p.bloodType}`).join('\n')}

## 要求
1. 用中文输出，语气专业简洁
2. 突出最需要关注的风险点和优先级
3. 控制在 200 字以内
4. 分三段：总体态势 → 重点关注 → 行动建议`;

  return chatCompletion([
    { role: 'system', content: '你是应急救援指挥中心的智能分析助手，负责生成简洁专业的态势摘要报告。' },
    { role: 'user', content: prompt },
  ]);
}

/**
 * 智能问答 — 基于 SOS 数据回答用户问题
 */
async function answerQuestion(question, contextData) {
  const contextStr = `
## 当前 SOS 数据上下文
- 总求救点数: ${contextData.total}
- 危重: ${contextData.criticalCount}, 紧急: ${contextData.urgentCount}
- 各省分布: ${(contextData.provinceDistribution || []).map(p => `${p.name}(${p.count})`).join(', ')}
- 血型分布: ${JSON.stringify(contextData.bloodDistribution)}
- 最高优先级前5: ${(contextData.topPriorities || []).map(p => `${p.mac}(分数${p.score},${p.severityLevel})`).join(', ')}
- 最长等待: ${(contextData.longestWaiting || []).map(w => `${w.mac}(等待${w.elapsedMin}分钟)`).join(', ')}
`;

  return chatCompletion([
    { role: 'system', content: '你是应急救援指挥中心的智能分析助手。用户会问你关于当前救援态势的问题。请基于提供的数据上下文准确回答。如果数据中没有相关信息，请如实告知。回答要简洁专业，用中文。' },
    { role: 'user', content: `${contextStr}\n\n用户问题：${question}` },
  ]);
}

module.exports = { generateSituationReport, answerQuestion };
