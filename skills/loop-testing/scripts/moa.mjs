#!/usr/bin/env node
// moa.mjs — MoA (Mixture of Agents) multi-model decision engine for loop-testing.
//
// Node >= 20, ZERO third-party dependencies (node: builtins only).
//
// Flow (see docs/02-architecture.md §4, FR-5.1..5.7):
//   decision-context.md
//     -> fan out to N reference models IN PARALLEL (plain chat completion, no tools)
//     -> aggregator model reads the original context + all reference opinions
//     -> emit a Markdown decision block (问题摘要 / 各参考模型意见 / 聚合推荐方案 /
//        理由 / 风险与分歧点 / 元数据)
//
// CLI:
//   node moa.mjs --input <decision-context.md> [--output <file>]
//                [--config <moa.config.json>] [--dry-run]
//
// ---------------------------------------------------------------------------
// PROXY MECHANISM — EMPIRICAL NOTE (important; deviates from architecture §4.2)
// ---------------------------------------------------------------------------
// Architecture §4.2 prescribes `setGlobalDispatcher(new ProxyAgent(...))` from
// Node's "bundled undici". Verified on the target build (node v22.21.0) that
// this is NOT available zero-dependency:
//   - `import ... from 'undici'`      -> ERR_MODULE_NOT_FOUND (package not installed)
//   - `import ... from 'node:undici'` -> ERR_UNKNOWN_BUILTIN_MODULE (no such builtin)
//   - globalThis.ProxyAgent / setGlobalDispatcher -> undefined
// Node does not expose undici's ProxyAgent/setGlobalDispatcher as public API, and
// installing undici would violate the zero-dependency contract.
//
// Therefore this engine does NOT use global fetch. It uses node:http / node:https
// directly, and implements proxy support explicitly:
//   - HTTP origin through a proxy  -> forward with an absolute-form request-target.
//   - HTTPS origin through a proxy -> CONNECT tunnel (net -> CONNECT -> tls) via a
//     custom `createConnection`.
// This is fully zero-dependency AND testable with a local stub proxy. The proxy
// selection seam is `resolveProxy(url)` below.
// ---------------------------------------------------------------------------

import { parseArgs } from 'node:util';
import { readFile, writeFile } from 'node:fs/promises';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';
import { URL } from 'node:url';

// ===========================================================================
// CALIBRATE-AT-RELEASE CONSTANTS
// These are the default top-tier models. They WILL go stale (release checklist
// item "校准默认模型" is mandatory). Override at runtime via a config file or the
// LOOP_TESTING_MOA_MODELS / LOOP_TESTING_MOA_AGGREGATOR env vars — no code change
// needed. Names use OpenRouter's namespace by default.
// ===========================================================================
// Calibrated 2026-07-11 against a live OpenRouter /models listing + one real
// minimal completion per model (all three returned "ok" through the proxy
// path). Note: this account has a provider allowlist (openai / anthropic /
// google-ai-studio) — models routed only through other providers (e.g.
// deepseek/*) 404 at completion time even though /models lists them.
const DEFAULT_REFERENCE_MODELS = ['openai/gpt-5.6-sol', 'google/gemini-3.1-pro-preview'];
const DEFAULT_AGGREGATOR_MODEL = 'anthropic/claude-fable-5';
const DEFAULT_REFERENCE_TEMPERATURE = 0.6;
const DEFAULT_AGGREGATOR_TEMPERATURE = 0.4;
// Top-tier reasoning models spend time thinking before the first output
// token; raised from 60s to give long decision contexts headroom.
const DEFAULT_TIMEOUT_MS = 120_000;
// Token-consumption guards: hard ceilings against runaway output (reasoning
// models burn tokens thinking inside max_tokens, so these are stop-losses,
// not tight budgets — prompts additionally demand concise output), plus an
// input-size cap so an over-stuffed decision context can't multiply cost
// across every reference model.
const REFERENCE_MAX_TOKENS = 3000;
const AGGREGATOR_MAX_TOKENS = 4000;
const MAX_CONTEXT_CHARS = 16000;
// Transport-level stop-loss: cap a single response body so a misconfigured or
// hostile endpoint/proxy streaming unbounded data can't OOM a headless run.
// Override via LOOP_TESTING_MOA_MAX_RESPONSE_BYTES (chat completions are KBs).
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;

// Provider registry. Both are OpenAI chat-completions wire format.
const PROVIDERS = {
  openrouter: {
    keyEnv: 'OPENROUTER_API_KEY',
    baseUrlEnv: 'OPENROUTER_BASE_URL',
    defaultBaseUrl: 'https://openrouter.ai/api/v1',
  },
  openai: {
    keyEnv: 'OPENAI_API_KEY',
    baseUrlEnv: 'OPENAI_BASE_URL',
    defaultBaseUrl: 'https://api.openai.com/v1',
  },
};

// ===========================================================================
// Secret redaction
// ===========================================================================
function collectSecrets(env) {
  const secrets = [];
  for (const p of Object.values(PROVIDERS)) {
    const v = env[p.keyEnv];
    if (v && v.trim()) secrets.push(v);
  }
  // Proxy credentials (user:pass@host in *_PROXY) must not surface in errors either.
  for (const name of ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy']) {
    const v = env[name];
    if (!v || !v.trim()) continue;
    try {
      const u = new URL(v.trim());
      // Redact every form the credential can take: the raw URL field, its
      // percent-decoded value, AND the base64 `user:pass` blob that
      // proxyAuthHeader() actually writes to the wire (that blob IS the
      // credential — redacting only its parts would miss it if it ever surfaced).
      if (u.password) { secrets.push(u.password); secrets.push(decodeURIComponent(u.password)); }
      if (u.username) { secrets.push(u.username); secrets.push(decodeURIComponent(u.username)); }
      if (u.username) {
        secrets.push(Buffer
          .from(`${decodeURIComponent(u.username)}:${decodeURIComponent(u.password || '')}`)
          .toString('base64'));
      }
    } catch { /* not a parseable URL — nothing to redact */ }
  }
  return secrets;
}

function makeRedactor(secrets) {
  return (text) => {
    let out = String(text ?? '');
    for (const s of secrets) {
      if (s) out = out.split(s).join('***REDACTED***');
    }
    return out;
  };
}

// ===========================================================================
// Config resolution: defaults <- config file <- env overrides
// ===========================================================================
function normalizeModelEntry(entry) {
  if (typeof entry === 'string') {
    if (!entry.trim()) throw new Error('empty model name in config');
    return { model: entry };
  }
  if (entry && typeof entry === 'object' && typeof entry.model === 'string') {
    if (!entry.model.trim()) throw new Error('empty model name in config entry');
    // Validate an explicit provider here (config-file entries are the only path
    // that can carry one) so resolveConfig's try/catch surfaces a clean
    // `error:` + exit 1 — not a fatal stack from resolveModelProvider's throw,
    // which runs at three unguarded call sites (dry-run, aggregator, failed-ref).
    // A falsy provider (absent/null/"") falls through to defaultProvider(), matching
    // resolveModelProvider's `entry.provider || default` semantics.
    if (entry.provider && !PROVIDERS[entry.provider]) {
      throw new Error(`unknown provider "${entry.provider}" for model "${entry.model}" (valid: ${Object.keys(PROVIDERS).join(', ')})`);
    }
    return { model: entry.model, provider: entry.provider };
  }
  throw new Error(`invalid model entry: ${JSON.stringify(entry)}`);
}

async function resolveConfig(args, env) {
  const cfg = {
    reference_models: DEFAULT_REFERENCE_MODELS.map((m) => ({ model: m })),
    aggregator: { model: DEFAULT_AGGREGATOR_MODEL },
    reference_temperature: DEFAULT_REFERENCE_TEMPERATURE,
    aggregator_temperature: DEFAULT_AGGREGATOR_TEMPERATURE,
  };

  // Config file: explicit --config, else the conventional cwd path.
  const explicit = args.config;
  const configPath = explicit || 'docs/looptesting/moa.config.json';
  let raw = null;
  try {
    raw = await readFile(configPath, 'utf8');
  } catch (e) {
    if (explicit) throw new Error(`config file not readable: ${configPath}: ${e.message}`);
    // default path absent -> ignore
  }
  if (raw != null) {
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (e) {
      throw new Error(`config file is not valid JSON: ${configPath}: ${e.message}`);
    }
    // reference_models absent -> keep DEFAULT. Present -> must be a non-empty array:
    // a non-array typo silently fell back to the DEFAULT (wrong, paid-for) models,
    // and [] silently ran aggregator-only — both contradict "zero criteria -> refuse"
    // and are now clean errors instead of silent degradation (audit MO-2 / MO-3).
    if (parsed.reference_models !== undefined) {
      if (!Array.isArray(parsed.reference_models) || parsed.reference_models.length === 0) {
        throw new Error('config "reference_models" must be a non-empty array of model names');
      }
      cfg.reference_models = parsed.reference_models.map(normalizeModelEntry);
    }
    if (parsed.aggregator != null) cfg.aggregator = normalizeModelEntry(parsed.aggregator);
    if (typeof parsed.reference_temperature === 'number') cfg.reference_temperature = parsed.reference_temperature;
    if (typeof parsed.aggregator_temperature === 'number') cfg.aggregator_temperature = parsed.aggregator_temperature;
  }

  // Env overrides (highest precedence).
  if (env.LOOP_TESTING_MOA_MODELS) {
    const models = env.LOOP_TESTING_MOA_MODELS.split(',').map((s) => s.trim()).filter(Boolean);
    if (models.length) cfg.reference_models = models.map((m) => ({ model: m }));
  }
  if (env.LOOP_TESTING_MOA_AGGREGATOR && env.LOOP_TESTING_MOA_AGGREGATOR.trim()) {
    cfg.aggregator = { model: env.LOOP_TESTING_MOA_AGGREGATOR.trim() };
  }

  return cfg;
}

function defaultProvider(env) {
  return env[PROVIDERS.openrouter.keyEnv] && env[PROVIDERS.openrouter.keyEnv].trim()
    ? 'openrouter'
    : 'openai';
}

function resolveModelProvider(entry, env) {
  const provider = entry.provider || defaultProvider(env);
  const pc = PROVIDERS[provider];
  if (!pc) throw new Error(`unknown provider: ${provider}`);
  const baseUrl = (env[pc.baseUrlEnv] || pc.defaultBaseUrl).replace(/\/+$/, '');
  const key = (env[pc.keyEnv] || '').trim();
  return { provider, baseUrl, key, keyEnv: pc.keyEnv, hasKey: Boolean(key) };
}

// ===========================================================================
// Proxy selection.  Node's global fetch would ignore these; we honor them
// explicitly. For an https origin prefer HTTPS_PROXY; for http prefer HTTP_PROXY;
// ALL_PROXY and the other var are accepted as fallbacks so a single *_PROXY set
// still takes effect regardless of origin scheme.
// ===========================================================================
function proxyEnabled(env) {
  return Boolean(
    (env.HTTPS_PROXY || env.https_proxy || env.HTTP_PROXY || env.http_proxy || env.ALL_PROXY || env.all_proxy || '').trim(),
  );
}

function proxySourceName(env) {
  for (const name of ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy']) {
    if (env[name] && env[name].trim()) return name;
  }
  return null;
}

function makeProxyResolver(env) {
  return (urlStr) => {
    const isHttps = new URL(urlStr).protocol === 'https:';
    const order = isHttps
      ? ['HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy', 'HTTP_PROXY', 'http_proxy']
      : ['HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy', 'HTTPS_PROXY', 'https_proxy'];
    for (const name of order) {
      const v = env[name];
      if (v && v.trim()) return v.trim();
    }
    return null;
  };
}

// ===========================================================================
// Zero-dependency HTTP(S) client with explicit proxy handling.
// ===========================================================================
function proxyAuthHeader(proxy) {
  if (!proxy.username) return {};
  const auth = Buffer
    .from(`${decodeURIComponent(proxy.username)}:${decodeURIComponent(proxy.password || '')}`)
    .toString('base64');
  return { 'proxy-authorization': `Basic ${auth}` };
}

// Establish a CONNECT tunnel through `proxy` to `target` (https origin), then
// TLS over it. Calls cb(err) or cb(null, tlsSocket).
function connectViaProxy(target, proxy, cb, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const proxyPort = Number(proxy.port) || (proxy.protocol === 'https:' ? 443 : 80);
  const targetPort = Number(target.port) || 443;
  const socket = net.connect({ host: proxy.hostname, port: proxyPort });
  let settled = false;
  let timer = null;
  const clearTimer = () => { if (timer) { clearTimeout(timer); timer = null; } };
  const fail = (err) => {
    if (settled) return;
    settled = true;
    clearTimer();
    socket.destroy();
    cb(err);
  };
  // Own timeout covering TCP connect + CONNECT reply + TLS handshake. requestRaw's
  // timer can't reach this socket until createConnection returns, so without this a
  // proxy that TCP-connects but never answers CONNECT (or stalls the handshake)
  // would orphan the socket until process exit.
  timer = setTimeout(() => fail(new Error(`proxy CONNECT timeout after ${timeoutMs}ms`)), timeoutMs);
  socket.once('error', fail);
  socket.on('connect', () => {
    const lines = [
      `CONNECT ${target.hostname}:${targetPort} HTTP/1.1`,
      `Host: ${target.hostname}:${targetPort}`,
    ];
    const authHdr = proxyAuthHeader(proxy);
    if (authHdr['proxy-authorization']) lines.push(`Proxy-Authorization: ${authHdr['proxy-authorization']}`);
    socket.write(lines.join('\r\n') + '\r\n\r\n');
  });
  let buf = Buffer.alloc(0);
  const onData = (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    const headerEnd = buf.indexOf('\r\n\r\n');
    if (headerEnd === -1) return;
    socket.removeListener('data', onData);
    const statusLine = buf.subarray(0, buf.indexOf('\r\n')).toString('utf8');
    const m = statusLine.match(/^HTTP\/\d\.\d\s+(\d{3})/);
    if (!m || m[1] !== '200') {
      fail(new Error(`proxy CONNECT failed: ${statusLine}`));
      return;
    }
    socket.removeListener('error', fail);
    // Preserve any bytes the proxy pipelined after the CONNECT response header
    // (e.g. the start of the tunneled TLS handshake) — they belong to the tunnel.
    const leftover = buf.subarray(headerEnd + 4);
    if (leftover.length) socket.unshift(leftover);
    const tlsSocket = tls.connect({ socket, servername: target.hostname }, () => {
      clearTimer();
      settled = true;
      cb(null, tlsSocket);
    });
    tlsSocket.once('error', (e) => {
      if (!settled) {
        settled = true;
        clearTimer();
        cb(e);
      }
    });
  };
  socket.on('data', onData);
}

// Perform one HTTP request. Resolves { status, headers, body }.
function requestRaw(urlStr, { method = 'POST', headers = {}, body = null, timeoutMs = DEFAULT_TIMEOUT_MS, proxyUrl = null, maxBytes = MAX_RESPONSE_BYTES } = {}) {
  return new Promise((resolve, reject) => {
    const target = new URL(urlStr);
    const isHttps = target.protocol === 'https:';
    const outHeaders = { ...headers };
    if (body != null && outHeaders['content-length'] == null) {
      outHeaders['content-length'] = Buffer.byteLength(body);
    }

    let settled = false;
    let timer = null;
    let req = null;
    const finish = (err, res) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (err) reject(err);
      else resolve(res);
    };

    const onResponse = (res) => {
      const chunks = [];
      let received = 0;
      res.on('data', (c) => {
        received += c.length;
        if (received > maxBytes) {
          // Stop-loss: don't buffer an unbounded body. Abort the request/response.
          res.destroy();
          if (req) req.destroy();
          finish(new Error(`response body exceeded ${maxBytes} bytes — aborted`));
          return;
        }
        chunks.push(c);
      });
      res.on('end', () => finish(null, {
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
      res.on('error', (e) => finish(e));
    };

    try {
      if (proxyUrl && !isHttps) {
        // HTTP origin through proxy: absolute-form request-target.
        const proxy = new URL(proxyUrl);
        req = http.request({
          host: proxy.hostname,
          port: Number(proxy.port) || 80,
          method,
          path: urlStr,
          headers: { host: target.host, ...outHeaders, ...proxyAuthHeader(proxy) },
        }, onResponse);
      } else if (proxyUrl && isHttps) {
        // HTTPS origin through proxy: CONNECT tunnel.
        req = https.request(urlStr, {
          method,
          headers: outHeaders,
          createConnection: (_opts, cb) => connectViaProxy(target, new URL(proxyUrl), cb, timeoutMs),
        }, onResponse);
      } else {
        const mod = isHttps ? https : http;
        req = mod.request(urlStr, { method, headers: outHeaders }, onResponse);
      }
    } catch (e) {
      finish(e);
      return;
    }

    timer = setTimeout(() => {
      finish(new Error(`request timeout after ${timeoutMs}ms`));
      if (req) req.destroy();
    }, timeoutMs);

    req.on('error', (e) => finish(e));
    if (body != null) req.write(body);
    req.end();
  });
}

// ===========================================================================
// Chat completion (one model, single bounded attempt — within the "no retries
// beyond 1" ceiling; we deliberately do zero retries for deterministic behavior).
// ===========================================================================
async function chatComplete({ model, messages, temperature, maxTokens, resolved, timeoutMs, maxBytes, proxyResolver, redact }) {
  if (!resolved.hasKey) {
    throw new Error(`missing API key for provider "${resolved.provider}" (env ${resolved.keyEnv})`);
  }
  const url = `${resolved.baseUrl}/chat/completions`;
  const payload = JSON.stringify({
    model, messages, temperature, stream: false,
    ...(Number.isFinite(maxTokens) ? { max_tokens: maxTokens } : {}),
  });
  const headers = {
    'content-type': 'application/json',
    authorization: `Bearer ${resolved.key}`,
  };
  if (resolved.provider === 'openrouter') {
    headers['http-referer'] = 'https://github.com/loop-testing/loop-testing';
    headers['x-title'] = 'loop-testing MoA';
  }

  let res;
  try {
    res = await requestRaw(url, { method: 'POST', headers, body: payload, timeoutMs, maxBytes, proxyUrl: proxyResolver(url) });
  } catch (e) {
    throw new Error(redact(`network error calling ${model}: ${e.message}`));
  }
  if (res.status < 200 || res.status >= 300) {
    const excerpt = redact(res.body || '').slice(0, 500);
    throw new Error(`HTTP ${res.status} from ${model}: ${excerpt}`);
  }
  let data;
  try {
    data = JSON.parse(res.body);
  } catch {
    throw new Error(`malformed JSON from ${model}: ${redact(res.body).slice(0, 200)}`);
  }
  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== 'string' || !content.trim()) {
    throw new Error(`empty or malformed completion from ${model}`);
  }
  return content;
}

// ===========================================================================
// Prompts
// ===========================================================================
function referenceMessages(contextMd) {
  return [
    {
      role: 'system',
      content:
        '你是一位资深技术评审专家（软件架构、质量、安全）。阅读用户给出的决策上下文，' +
        '独立给出你的分析与明确推荐。仅输出文本，不调用任何工具，不要臆造事实；' +
        '若信息不足，明确指出需要补充什么。' +
        '输出必须精炼：总长不超过 400 字，结构为「推荐方案（1-2 句）/ 关键理由（≤3 条）/ 主要风险（≤2 条）」，' +
        '不要铺开背景复述，不要输出思考过程。',
    },
    { role: 'user', content: contextMd },
  ];
}

function aggregatorMessages(contextMd, opinions) {
  const opinionBlock = opinions.length
    ? opinions.map((o, i) => `### 参考意见 ${i + 1}（模型：${o.model}）\n${o.content}`).join('\n\n')
    : '（无可用参考模型意见——请仅基于原始上下文独立给出建议，并说明缺少第二视角的局限。）';
  return [
    {
      role: 'system',
      content:
        '你是聚合决策者。综合原始决策上下文与各参考模型意见，产出最终建议。' +
        '严格只输出一个 JSON 对象（不要代码围栏、不要额外文字），键为：' +
        'summary（问题摘要）、recommendation（聚合推荐方案）、rationale（理由）、risks（风险与分歧点）。' +
        '每个值为中文 Markdown 文本；在分歧处指出各参考意见的异同。' +
        '输出必须精炼：summary ≤80 字，recommendation ≤150 字，rationale ≤3 条要点，risks ≤3 条要点；' +
        '总长控制在 600 字以内，不要复述上下文原文。',
    },
    {
      role: 'user',
      content: `## 原始决策上下文\n${contextMd}\n\n## 各参考模型意见\n${opinionBlock}`,
    },
  ];
}

// Lenient extraction of a JSON object from model output.
function extractJsonObject(text) {
  const attempts = [];
  attempts.push(text);
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) attempts.push(fence[1]);
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start !== -1 && end > start) attempts.push(text.slice(start, end + 1));
  for (const a of attempts) {
    try {
      const parsed = JSON.parse(a);
      if (parsed && typeof parsed === 'object') return parsed;
    } catch { /* try next */ }
  }
  return null;
}

// ===========================================================================
// Decision document assembly
// ===========================================================================
function buildDecisionMarkdown({ opinions, failedRefs, aggModel, aggContent, degraded, defaultProviderName }) {
  const parsed = extractJsonObject(aggContent) || {};
  const summary = (typeof parsed.summary === 'string' && parsed.summary.trim())
    ? parsed.summary.trim()
    : '（聚合模型未返回结构化摘要，原始输出见"聚合推荐方案"。）';
  const recommendation = (typeof parsed.recommendation === 'string' && parsed.recommendation.trim())
    ? parsed.recommendation.trim()
    : aggContent.trim();
  const rationale = (typeof parsed.rationale === 'string' && parsed.rationale.trim())
    ? parsed.rationale.trim()
    : '（见"聚合推荐方案"。）';
  const risks = (typeof parsed.risks === 'string' && parsed.risks.trim())
    ? parsed.risks.trim()
    : '（见"聚合推荐方案"。）';

  const opinionSection = [];
  for (const o of opinions) {
    opinionSection.push(`### ${o.model}（provider: ${o.provider}）\n\n${o.content.trim()}`);
  }
  for (const f of failedRefs) {
    opinionSection.push(`### ${f.model}（provider: ${f.provider}）— 降级：调用失败\n\n> ${f.error}`);
  }
  const opinionText = opinionSection.length ? opinionSection.join('\n\n') : '（无参考模型意见）';

  const degradedText = degraded.length ? degraded.join(', ') : 'none';

  return [
    '# MoA 决策建议',
    '',
    '## 问题摘要',
    '',
    summary,
    '',
    '## 各参考模型意见',
    '',
    opinionText,
    '',
    '## 聚合推荐方案',
    '',
    recommendation,
    '',
    '## 理由',
    '',
    rationale,
    '',
    '## 风险与分歧点',
    '',
    risks,
    '',
    '## 元数据',
    '',
    `- reference_models_used: ${opinions.length ? opinions.map((o) => o.model).join(', ') : '(none)'}`,
    `- reference_models_failed: ${failedRefs.length ? failedRefs.map((f) => f.model).join(', ') : '(none)'}`,
    `- aggregator_model: ${aggModel}`,
    `- default_provider: ${defaultProviderName}`,
    `- degraded: ${degradedText}`,
    `- timestamp: ${new Date().toISOString()}`,
    '',
  ].join('\n');
}

// ===========================================================================
// Dry-run report (no network; no secret values)
// ===========================================================================
function dryRunReport(cfg, env) {
  const lines = [];
  lines.push('MoA dry-run — resolved configuration (no network calls made)');
  lines.push('');
  lines.push('reference_models:');
  for (const entry of cfg.reference_models) {
    const r = resolveModelProvider(entry, env);
    lines.push(`  - ${entry.model} (provider: ${r.provider}, key: ${r.hasKey ? 'set' : 'missing'})`);
  }
  const agg = resolveModelProvider(cfg.aggregator, env);
  lines.push(`aggregator: ${cfg.aggregator.model} (provider: ${agg.provider}, key: ${agg.hasKey ? 'set' : 'missing'})`);
  lines.push(`default_provider: ${defaultProvider(env)}`);
  lines.push(`reference_temperature: ${cfg.reference_temperature}`);
  lines.push(`aggregator_temperature: ${cfg.aggregator_temperature}`);
  const src = proxySourceName(env);
  lines.push(`proxy: ${proxyEnabled(env) ? `on (via ${src})` : 'off'}`);
  lines.push('keys:');
  lines.push(`  OPENAI_API_KEY: ${env.OPENAI_API_KEY && env.OPENAI_API_KEY.trim() ? 'set' : 'missing'}`);
  lines.push(`  OPENROUTER_API_KEY: ${env.OPENROUTER_API_KEY && env.OPENROUTER_API_KEY.trim() ? 'set' : 'missing'}`);
  return lines.join('\n');
}

// ===========================================================================
// Main
// ===========================================================================
const USAGE =
  'Usage: node moa.mjs --input <decision-context.md> [--output <file>] [--config <moa.config.json>] [--dry-run]';

async function main() {
  const env = process.env;
  const redact = makeRedactor(collectSecrets(env));

  // Argument-parse failures (unknown flag, missing value) are user errors, not
  // internal crashes — surface a clean message + usage, never a Node stack trace.
  let args;
  try {
    ({ values: args } = parseArgs({
      options: {
        input: { type: 'string' },
        output: { type: 'string' },
        config: { type: 'string' },
        'dry-run': { type: 'boolean', default: false },
        help: { type: 'boolean', default: false },
      },
      allowPositionals: false,
    }));
  } catch (e) {
    process.stderr.write(`error: ${redact(e.message)}\n${USAGE}\n`);
    return 1;
  }

  if (args.help) {
    process.stdout.write(`${USAGE}\n`);
    return 0;
  }

  // Config resolution failures (unreadable --config, malformed JSON, bad model
  // entry) are user errors too — same clean treatment.
  let cfg;
  try {
    cfg = await resolveConfig(args, env);
  } catch (e) {
    process.stderr.write(`error: ${redact(e.message)}\n`);
    return 1;
  }
  const timeoutMs = Number(env.LOOP_TESTING_MOA_TIMEOUT_MS) > 0
    ? Number(env.LOOP_TESTING_MOA_TIMEOUT_MS)
    : DEFAULT_TIMEOUT_MS;
  const maxBytes = Number(env.LOOP_TESTING_MOA_MAX_RESPONSE_BYTES) > 0
    ? Number(env.LOOP_TESTING_MOA_MAX_RESPONSE_BYTES)
    : MAX_RESPONSE_BYTES;

  // --dry-run: print resolved config, make no network call.
  if (args['dry-run']) {
    process.stdout.write(dryRunReport(cfg, env) + '\n');
    return 0;
  }

  if (!args.input) {
    process.stderr.write('error: --input <decision-context.md> is required (or use --dry-run)\n');
    return 1;
  }

  let contextMd;
  try {
    contextMd = await readFile(args.input, 'utf8');
  } catch (e) {
    process.stderr.write(`error: cannot read --input ${args.input}: ${redact(e.message)}\n`);
    return 1;
  }
  if (!contextMd.trim()) {
    process.stderr.write(`error: --input ${args.input} is empty\n`);
    return 1;
  }
  if (contextMd.length > MAX_CONTEXT_CHARS) {
    // Cost guard: an over-stuffed context is paid once per reference model plus
    // once for the aggregator. Truncate with an explicit marker so the models
    // (and the archived DEC file) know evidence was cut, not missing.
    process.stderr.write(
      `warn: decision context ${contextMd.length} chars > ${MAX_CONTEXT_CHARS}; truncating to control token cost — trim the context (excerpt evidence, don't paste full logs)\n`,
    );
    contextMd = `${contextMd.slice(0, MAX_CONTEXT_CHARS)}\n\n> [由 moa.mjs 截断：原文 ${contextMd.length} 字符，超出 ${MAX_CONTEXT_CHARS} 上限。请精炼决策上下文——摘录关键证据，勿粘贴全量日志。]`;
  }

  const proxyResolver = makeProxyResolver(env);

  // Fan out reference models in parallel.
  const refSettled = await Promise.allSettled(
    cfg.reference_models.map(async (entry) => {
      const resolved = resolveModelProvider(entry, env);
      const content = await chatComplete({
        model: entry.model,
        messages: referenceMessages(contextMd),
        temperature: cfg.reference_temperature,
        maxTokens: REFERENCE_MAX_TOKENS,
        resolved,
        timeoutMs,
        maxBytes,
        proxyResolver,
        redact,
      });
      return { model: entry.model, provider: resolved.provider, content };
    }),
  );

  const opinions = [];
  const failedRefs = [];
  cfg.reference_models.forEach((entry, i) => {
    const r = refSettled[i];
    if (r.status === 'fulfilled') {
      opinions.push(r.value);
    } else {
      const resolved = resolveModelProvider(entry, env);
      failedRefs.push({ model: entry.model, provider: resolved.provider, error: redact(r.reason?.message || String(r.reason)) });
    }
  });

  const degraded = [];
  if (failedRefs.length && opinions.length) {
    degraded.push(`partial-references (${failedRefs.length}/${cfg.reference_models.length} failed)`);
  }
  if (!opinions.length) {
    degraded.push('no-references');
  }

  // Aggregator (required). Failure or missing key -> exit 2 so the caller can
  // fall back to single-model reasoning.
  const aggResolved = resolveModelProvider(cfg.aggregator, env);
  let aggContent;
  try {
    aggContent = await chatComplete({
      model: cfg.aggregator.model,
      messages: aggregatorMessages(contextMd, opinions),
      temperature: cfg.aggregator_temperature,
      maxTokens: AGGREGATOR_MAX_TOKENS,
      resolved: aggResolved,
      timeoutMs,
      maxBytes,
      proxyResolver,
      redact,
    });
  } catch (e) {
    process.stderr.write(`error: aggregator model unavailable — MoA degraded, fall back to single-model. ${redact(e.message)}\n`);
    return 2;
  }

  // Redact the assembled doc before it leaves the process. The doc embeds raw model
  // output verbatim; a hostile/compromised or logging endpoint that reflects the
  // request can echo the Authorization header into its completion, which would
  // otherwise land the key in the archived DEC.md / stdout. Every error path is
  // already redacted; the success doc was the one uncovered channel (audit MO-1).
  const doc = redact(buildDecisionMarkdown({
    opinions,
    failedRefs,
    aggModel: cfg.aggregator.model,
    aggContent,
    degraded,
    defaultProviderName: defaultProvider(env),
  }));

  if (args.output) {
    try {
      await writeFile(args.output, doc, 'utf8');
    } catch (e) {
      // The reference + aggregator calls already ran (and were paid for). Do NOT
      // discard the decision on a write failure — emit it to stdout and report a
      // clean error so the caller can still capture the result.
      process.stdout.write(doc + '\n');
      process.stderr.write(`error: could not write --output ${args.output}: ${redact(e.message)} (decision emitted to stdout above)\n`);
      return 1;
    }
    process.stderr.write(`MoA decision written to ${args.output}${degraded.length ? ` (degraded: ${degraded.join(', ')})` : ''}\n`);
  } else {
    process.stdout.write(doc + '\n');
  }
  return 0;
}

main()
  .then((code) => process.exit(code ?? 0))
  .catch((e) => {
    // Redact defensively even on unexpected errors.
    const redact = makeRedactor(collectSecrets(process.env));
    process.stderr.write(`fatal: ${redact(e?.stack || e?.message || String(e))}\n`);
    process.exit(1);
  });
