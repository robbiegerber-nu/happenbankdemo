/* A pretend AI for tests: no key, no cost. The question decides what it does. It also checks that the conversation it
   is sent is one the real API would accept, so a mistake in the history shows up here first. */
let n = 0;
const usage = { input_tokens: 3000, output_tokens: 300, cache_read_input_tokens: 2000, cache_creation_input_tokens: 0 };
const msg = (content, stop_reason) => ({ id: 'fake', role: 'assistant', content, stop_reason, usage });
const fail = (status, text) => { throw Object.assign(new Error(text), { status, name: 'FakeError' }); };
function check(messages) {
  if (!messages.length || messages[0].role !== 'user') fail(400, 'first message must be from the user');
  messages.forEach((m, i) => {
    if (i && messages[i - 1].role === m.role) fail(400, 'roles must alternate');
    const uses = i && messages[i - 1].role === 'assistant' ? messages[i - 1].content.filter((b) => b.type === 'tool_use').map((b) => b.id) : [], res = m.role === 'user' ? m.content.filter((b) => b.type === 'tool_result').map((b) => b.tool_use_id) : [];
    if (m.role === 'user' && (uses.length !== res.length || !uses.every((x) => res.includes(x)))) fail(400, 'tool results do not match');
  });
}
export async function fakeClaude(p) {
  check(p.messages);
  const last = p.messages[p.messages.length - 1], q = [...p.messages].reverse().flatMap((m) => (m.role === 'user' ? m.content.filter((b) => b.type === 'text').slice(-1) : []))[0].text, results = last.content.filter((b) => b.type === 'tool_result');
  if (q.includes('SLOW')) await new Promise((r) => setTimeout(r, 1500));
  if (q.includes('OVERLOAD')) fail(529, 'overloaded');
  if (q.includes('REFUSE')) return msg([], 'refusal');
  if (q.includes('COSTLY')) return { ...msg([{ type: 'text', text: 'expensive' }], 'end_turn'), usage: { input_tokens: 0, output_tokens: 60000 } };
  if (q.includes('LOOP') && (!p.tool_choice || p.tool_choice.type !== 'none')) return msg([{ type: 'tool_use', id: 'toolu_' + ++n, name: 'describe_data', input: {} }], 'tool_use');
  if (results.length && !last.content.some((b) => b.type === 'text')) { const r = JSON.parse(results[0].content); return msg([{ type: 'thinking', thinking: '', signature: 'x' }, { type: 'text', text: r.error ? 'The tool said: ' + r.error : r.months ? `It was **${r.first_to_last.from_value}** in ${r.first_to_last.from} and **${r.first_to_last.to_value}** in ${r.first_to_last.to}: ${r.first_to_last.reading}.` : r.rows ? `**${r.rows[0].name}** is first, at ${r.rows[0].value}.` : `Phone service level was **${r.value}** in October 2026.` }], 'end_turn'); }
  if (/TREND (\w+)/.test(q)) return msg([{ type: 'tool_use', id: 'toolu_' + ++n, name: 'trend', input: { metric: q.match(/TREND (\w+)/)[1] } }], 'tool_use');
  if (/BARS (\w+) (\w+)/.test(q)) { const [, metric, by] = q.match(/BARS (\w+) (\w+)/); return msg([{ type: 'tool_use', id: 'toolu_' + ++n, name: 'breakdown', input: { metric, by, from: '2026-10', chart: true } }], 'tool_use'); }
  if (/service level/i.test(q)) return msg([{ type: 'thinking', thinking: '', signature: 'x' }, { type: 'tool_use', id: 'toolu_' + ++n, name: 'get_metric', input: { metric: 'sl_phone', from: '2026-10' } }], 'tool_use');
  return msg([{ type: 'text', text: 'Pretend answer to: ' + q.slice(0, 80) }], 'end_turn');
}
