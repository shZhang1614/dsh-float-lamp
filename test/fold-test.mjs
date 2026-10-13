// 状态机单元测试：模拟会话事件序列，断言聚合状态。
import { applyEvent, aggregate, foldEvents } from '../lib/index.js'

let failed = 0
function check(name, got, want) {
	const ok = got === want
	if (!ok) failed++
	console.log(`${ok ? 'PASS' : 'FAIL'} ${name}: got=${got} want=${want}`)
}

// 1. 空 → idle
check('empty', aggregate().state, 'idle')

// 2. 单会话 turn/start → running
applyEvent('s1', { type: 'turn/start', data: { turn: 1 } })
check('turn open', aggregate().state, 'running')

// 3. approval/asked → approval（橙优先于绿）
applyEvent('s1', { type: 'approval/asked', data: { id: 'a1', toolName: 'pwsh' } })
check('approval pending', aggregate().state, 'approval')

// 4. approval/decided → 回到 running
applyEvent('s1', { type: 'approval/decided', data: { id: 'a1', outcome: 'accepted' } })
check('approval decided', aggregate().state, 'running')

// 5. tool/call ask_user_question → question（蓝）
applyEvent('s1', { type: 'tool/call', data: { turn: 1, step: 2, callId: 'c1', name: 'ask_user_question', arguments: '{}' } })
check('question pending', aggregate().state, 'question')

// 6. tool/result → 回到 running
applyEvent('s1', { type: 'tool/result', data: { turn: 1, step: 2, message: {} } })
check('question answered', aggregate().state, 'running')

// 7. exit_plan_mode 也算交互
applyEvent('s1', { type: 'tool/call', data: { turn: 1, step: 3, callId: 'c2', name: 'exit_plan_mode', arguments: '{}' } })
check('plan question', aggregate().state, 'question')

// 8. turn/end → idle
applyEvent('s1', { type: 'turn/end', data: { turn: 1, reason: 'success' } })
check('turn end', aggregate().state, 'idle')

// 9. 多会话：s2 待授权 + s3 运行 → approval 优先
applyEvent('s2', { type: 'turn/start', data: { turn: 1 } })
applyEvent('s2', { type: 'approval/asked', data: { id: 'a2' } })
applyEvent('s3', { type: 'turn/start', data: { turn: 1 } })
const agg = aggregate()
check('multi priority', agg.state, 'approval')
check('multi counts', JSON.stringify(agg.counts), JSON.stringify({ approval: 1, question: 0, running: 1 }))

// 10. 待交互优先于运行
applyEvent('s2', { type: 'approval/decided', data: { id: 'a2' } })
applyEvent('s2', { type: 'tool/call', data: { turn: 1, step: 1, callId: 'c9', name: 'ask_user_question', arguments: '{}' } })
check('question over running', aggregate().state, 'question')

// 11. foldEvents 重放（重启播种）
applyEvent('s4', { type: 'turn/start', data: {} })
foldEvents('s5', [
	{ type: 'turn/start', data: {} },
	{ type: 'approval/asked', data: { id: 'x' } },
])
check('fold seed', aggregate().state, 'approval')

// 12. 悬停任务信息：user/message 标题 + 正在执行的工具
applyEvent('s3', { type: 'user/message', data: { role: 'user', content: [{ type: 'text', text: '修复灯插件的\n悬停功能' }] } })
applyEvent('s3', { type: 'tool/call', data: { turn: 1, step: 1, callId: 'c10', name: 'pwsh', arguments: '{}' } })
const tasks = aggregate().tasks
const t3 = tasks.find((t) => t.title.includes('修复灯插件'))
check('task title', t3 && t3.title, '修复灯插件的 悬停功能')
check('task tool', t3 && t3.tool, 'pwsh')
check('task sorted first', tasks[0].state, 'approval')

// 13. tool/result → 工具队列清空
applyEvent('s3', { type: 'tool/result', data: { turn: 1, step: 1, message: {} } })
check('task tool cleared', aggregate().tasks.find((t) => t.title.includes('修复灯')).tool, '')

// 14. 清理后回到 idle
applyEvent('s2', { type: 'turn/end', data: {} })
applyEvent('s3', { type: 'turn/end', data: {} })
applyEvent('s4', { type: 'turn/end', data: {} })
applyEvent('s5', { type: 'turn/end', data: {} })
applyEvent('s1', { type: 'turn/end', data: {} })
check('all idle', aggregate().state, 'idle')

process.exit(failed ? 1 : 0)
