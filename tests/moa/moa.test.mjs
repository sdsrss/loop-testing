// Black-box component tests for the MoA decision engine (skills/loop-testing/scripts/moa.mjs).
//
// Constraints honored here:
//   - NO real network, NO real API keys. Every endpoint is a local node:http stub.
//   - moa.mjs is exercised as a subprocess (real CLI contract), with a fully
//     controlled env so the host machine's real proxy / keys never leak in.
//   - Proxy behavior is verified by pointing the OpenAI base URL at an UNROUTABLE
//     host and setting *_PROXY at a local stub proxy: success is only possible if
//     traffic actually goes through the proxy.
//
// Run: node --test tests/moa/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const MOA_PATH = join(HERE, '..', '..', 'skills', 'loop-testing', 'scripts', 'moa.mjs');

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Start a local HTTP stub. `handler(req, res, body)` is called after the full
// body is buffered. Every request is recorded in `requests`.
function startServer(handler) {
  return new Promise((resolve) => {
    const requests = [];
    const server = http.createServer((req, res) => {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        requests.push({ method: req.method, url: req.url, headers: req.headers, body });
        try {
          handler(req, res, body, requests);
        } catch (e) {
          res.statusCode = 500;
          res.end(String(e));
        }
      });
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        server,
        port,
        url: `http://127.0.0.1:${port}`,
        requests,
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

// A chat-completions handler that routes by the request's `model` field:
//   - model in failModels  -> HTTP 500 (echoing the Authorization header so
//                             redaction of error excerpts can be asserted).
//   - model === aggModel   -> structured JSON aggregator response.
//   - otherwise            -> a reference opinion `opinion-from-<model>`.
function chatHandler({ aggModel, failModels = [] }) {
  return (req, res, body) => {
    let model = '';
    try { model = JSON.parse(body).model; } catch { /* ignore */ }
    res.setHeader('content-type', 'application/json');
    if (failModels.includes(model)) {
      res.statusCode = 500;
      res.end(JSON.stringify({ error: 'boom', seen_auth: req.headers.authorization || '' }));
      return;
    }
    let content;
    if (model === aggModel) {
      content = JSON.stringify({
        summary: 'S-summary', recommendation: 'R-reco',
        rationale: 'RA-rationale', risks: 'RK-risks',
      });
    } else {
      content = `opinion-from-${model}`;
    }
    res.statusCode = 200;
    res.end(JSON.stringify({ choices: [{ message: { content } }] }));
  };
}

// A success-path handler that echoes the Authorization header INTO the completion
// content (both reference opinions and the aggregator's structured fields). Models
// a hostile/compromised or logging endpoint that reflects the request — the exact
// threat the redactor is defense-in-depth against. Used to prove the assembled
// decision doc is redacted before it is written/emitted (MO-1).
function echoAuthHandler({ aggModel }) {
  return (req, res, body) => {
    let model = '';
    try { model = JSON.parse(body).model; } catch { /* ignore */ }
    const auth = req.headers.authorization || '';
    res.setHeader('content-type', 'application/json');
    let content;
    if (model === aggModel) {
      content = JSON.stringify({
        summary: `S ${auth}`, recommendation: `R ${auth}`,
        rationale: `RA ${auth}`, risks: 'RK',
      });
    } else {
      content = `opinion echoing ${auth}`;
    }
    res.statusCode = 200;
    res.end(JSON.stringify({ choices: [{ message: { content } }] }));
  };
}

// Run moa.mjs as a subprocess with a *clean* env (only what we pass, plus PATH).
function runMoa(args, env = {}, cwd) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [MOA_PATH, ...args], {
      cwd: cwd || HERE,
      env: { PATH: process.env.PATH, HOME: process.env.HOME, ...env },
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

async function withWorkspace(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'moa-test-'));
  try {
    return await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

async function writeInput(dir, text = '# 决策上下文\n\n现象：X。候选方案：A 或 B。') {
  const p = join(dir, 'ctx.md');
  await writeFile(p, text, 'utf8');
  return p;
}

async function writeConfig(dir, cfg) {
  const p = join(dir, 'moa.config.json');
  await writeFile(p, JSON.stringify(cfg), 'utf8');
  return p;
}

const TWO_REF_CONFIG = {
  reference_models: [
    { model: 'ref-model-a', provider: 'openai' },
    { model: 'ref-model-b', provider: 'openai' },
  ],
  aggregator: { model: 'agg-model', provider: 'openai' },
};

// --- CONNECT-proxy tunnel helpers (for the https-origin CONNECT+TLS path) -----

function hasOpenssl() {
  try { execFileSync('openssl', ['version'], { stdio: 'ignore' }); return true; } catch { return false; }
}

// Generate an ephemeral self-signed cert (CN=api.openai.com) into `dir`.
async function genCert(dir) {
  const key = join(dir, 'key.pem');
  const cert = join(dir, 'cert.pem');
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-keyout', key, '-out', cert,
    '-days', '1', '-nodes', '-subj', '/CN=api.openai.com',
  ], { stdio: 'ignore' });
  return { key: await readFile(key, 'utf8'), cert: await readFile(cert, 'utf8') };
}

// A minimal HTTPS chat responder used behind the CONNECT tunnel.
function tlsChatHandler({ aggModel }) {
  return (req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      let model = '';
      try { model = JSON.parse(Buffer.concat(chunks).toString('utf8')).model; } catch { /* ignore */ }
      res.setHeader('content-type', 'application/json');
      const content = model === aggModel
        ? JSON.stringify({ summary: 'S', recommendation: 'R-reco', rationale: 'RA', risks: 'RK' })
        : `opinion-from-${model}`;
      res.statusCode = 200;
      res.end(JSON.stringify({ choices: [{ message: { content } }] }));
    });
  };
}

// A CONNECT proxy stub. On CONNECT it either: hangs (never replies), returns a
// non-200 status, or returns 200 and hands the socket to an in-process HTTPS
// server (TLS terminated here) — capturing the CONNECT lines and the SNI names.
function startConnectProxy({ key, cert, chatHandler: ch, status = '200 Connection established', hang = false } = {}) {
  const connects = [];
  const sni = [];
  const headers = [];   // full CONNECT header blocks (for Proxy-Authorization asserts, R51)
  let httpsServer = null;
  if (key && cert && ch) {
    httpsServer = https.createServer(
      { key, cert, SNICallback: (servername, cb) => { sni.push(servername); cb(null); } },
      ch,
    );
    httpsServer.on('clientError', () => {});
  }
  return new Promise((resolve) => {
    const server = net.createServer((sock) => {
      sock.on('error', () => {});
      sock.once('data', (chunk) => {
        const text = chunk.toString('utf8');
        connects.push(text.split('\r\n')[0]);
        headers.push(text.split('\r\n\r\n')[0]);
        if (hang) return;                          // never reply -> exercise the own timeout
        if (!status.startsWith('200')) {
          sock.write(`HTTP/1.1 ${status}\r\n\r\n`); sock.end(); return;
        }
        sock.write('HTTP/1.1 200 Connection established\r\n\r\n');
        if (httpsServer) httpsServer.emit('connection', sock);   // TLS + HTTP over the tunnel
      });
    });
    server.listen(0, '127.0.0.1', () => {
      resolve({
        port: server.address().port,
        url: `http://127.0.0.1:${server.address().port}`,
        connects, sni, headers,
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

const ONE_REF_HTTPS = {
  reference_models: [{ model: 'ref-a', provider: 'openai' }],
  aggregator: { model: 'agg-model', provider: 'openai' },
};

// Responds with a body larger than the size cap, to exercise the transport stop-loss.
function bigBodyHandler(bytes = 2000) {
  return (_req, res) => {
    res.setHeader('content-type', 'application/json');
    res.statusCode = 200;
    res.end('x'.repeat(bytes));
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test('happy path: 2 references + aggregator produce all sections and both opinions', async () => {
  await withWorkspace(async (dir) => {
    const stub = await startServer(chatHandler({ aggModel: 'agg-model' }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, TWO_REF_CONFIG);
      const out = join(dir, 'DEC.md');
      const { code, stderr } = await runMoa(
        ['--input', input, '--config', config, '--output', out],
        { OPENAI_API_KEY: 'sk-fake', OPENAI_BASE_URL: `${stub.url}/v1` },
      );
      assert.equal(code, 0, `stderr: ${stderr}`);
      const doc = await readFile(out, 'utf8');
      for (const section of ['问题摘要', '各参考模型意见', '聚合推荐方案', '理由', '风险与分歧点', '元数据']) {
        assert.ok(doc.includes(section), `missing section: ${section}`);
      }
      assert.ok(doc.includes('opinion-from-ref-model-a'), 'missing ref-a opinion');
      assert.ok(doc.includes('opinion-from-ref-model-b'), 'missing ref-b opinion');
      assert.ok(doc.includes('R-reco'), 'missing aggregator recommendation');
      assert.ok(doc.includes('RK-risks'), 'missing aggregator risks');
    } finally {
      await stub.close();
    }
  });
});

test('provider selection: dry-run reflects openrouter-only vs openai-only default', async () => {
  await withWorkspace(async (dir) => {
    const input = await writeInput(dir);
    const routerOnly = await runMoa(
      ['--input', input, '--dry-run'],
      { OPENROUTER_API_KEY: 'sk-or' }, dir,
    );
    assert.equal(routerOnly.code, 0, routerOnly.stderr);
    assert.match(routerOnly.stdout, /default_provider:\s*openrouter/);

    const openaiOnly = await runMoa(
      ['--input', input, '--dry-run'],
      { OPENAI_API_KEY: 'sk-oa' }, dir,
    );
    assert.equal(openaiOnly.code, 0, openaiOnly.stderr);
    assert.match(openaiOnly.stdout, /default_provider:\s*openai/);
  });
});

test('provider selection: real OpenRouter wire path via OPENROUTER_BASE_URL', async () => {
  await withWorkspace(async (dir) => {
    const stub = await startServer(chatHandler({ aggModel: 'agg-model' }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, {
        reference_models: [{ model: 'ref-model-a', provider: 'openrouter' }],
        aggregator: { model: 'agg-model', provider: 'openrouter' },
      });
      const out = join(dir, 'DEC.md');
      const { code, stderr } = await runMoa(
        ['--input', input, '--config', config, '--output', out],
        { OPENROUTER_API_KEY: 'sk-or-fake', OPENROUTER_BASE_URL: `${stub.url}/api/v1` },
      );
      assert.equal(code, 0, `stderr: ${stderr}`);
      const authHeaders = stub.requests.map((r) => r.headers.authorization);
      assert.ok(authHeaders.every((a) => a === 'Bearer sk-or-fake'), 'openrouter auth not applied');
    } finally {
      await stub.close();
    }
  });
});

test('proxy: traffic routes through *_PROXY (base host is unroutable)', async () => {
  await withWorkspace(async (dir) => {
    // The proxy stub doubles as responder: it records the absolute-form URL and
    // answers directly. The OpenAI base points at an unroutable host, so a
    // successful run PROVES the request went through the proxy.
    const proxy = await startServer(chatHandler({ aggModel: 'agg-model' }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, TWO_REF_CONFIG);
      const out = join(dir, 'DEC.md');
      const { code, stderr } = await runMoa(
        ['--input', input, '--config', config, '--output', out],
        {
          OPENAI_API_KEY: 'sk-fake',
          OPENAI_BASE_URL: 'http://10.255.255.1/v1', // unroutable (TEST-NET-ish blackhole)
          HTTPS_PROXY: proxy.url,
        },
      );
      assert.equal(code, 0, `stderr: ${stderr}`);
      assert.ok(proxy.requests.length >= 3, `expected >=3 proxied calls, got ${proxy.requests.length}`);
      // Absolute-form request-target is the hallmark of forward-proxying an http origin.
      assert.ok(
        proxy.requests.every((r) => r.url.startsWith('http://10.255.255.1/v1/')),
        `proxy did not receive absolute-form targets: ${proxy.requests.map((r) => r.url).join(', ')}`,
      );
    } finally {
      await proxy.close();
    }
  });
});

test('degradation: one reference 500s -> still succeeds with a metadata note', async () => {
  await withWorkspace(async (dir) => {
    const stub = await startServer(chatHandler({ aggModel: 'agg-model', failModels: ['ref-model-b'] }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, TWO_REF_CONFIG);
      const out = join(dir, 'DEC.md');
      const { code, stderr } = await runMoa(
        ['--input', input, '--config', config, '--output', out],
        { OPENAI_API_KEY: 'sk-fake', OPENAI_BASE_URL: `${stub.url}/v1` },
      );
      assert.equal(code, 0, `stderr: ${stderr}`);
      const doc = await readFile(out, 'utf8');
      assert.ok(doc.includes('opinion-from-ref-model-a'), 'surviving reference missing');
      assert.ok(doc.includes('ref-model-b'), 'failed reference not noted');
      assert.match(doc, /degraded/i);
    } finally {
      await stub.close();
    }
  });
});

test('degradation: all references fail -> aggregator-only + degraded no-references', async () => {
  await withWorkspace(async (dir) => {
    const stub = await startServer(chatHandler({
      aggModel: 'agg-model', failModels: ['ref-model-a', 'ref-model-b'],
    }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, TWO_REF_CONFIG);
      const out = join(dir, 'DEC.md');
      const { code, stderr } = await runMoa(
        ['--input', input, '--config', config, '--output', out],
        { OPENAI_API_KEY: 'sk-fake', OPENAI_BASE_URL: `${stub.url}/v1` },
      );
      assert.equal(code, 0, `stderr: ${stderr}`);
      const doc = await readFile(out, 'utf8');
      assert.match(doc, /no-references/);
      assert.ok(doc.includes('R-reco'), 'aggregator output missing in aggregator-only mode');
    } finally {
      await stub.close();
    }
  });
});

test('degradation: aggregator fails -> exit code 2', async () => {
  await withWorkspace(async (dir) => {
    const stub = await startServer(chatHandler({ aggModel: 'agg-model', failModels: ['agg-model'] }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, TWO_REF_CONFIG);
      const { code, stderr } = await runMoa(
        ['--input', input, '--config', config],
        { OPENAI_API_KEY: 'sk-fake', OPENAI_BASE_URL: `${stub.url}/v1` },
      );
      assert.equal(code, 2, `expected exit 2, stderr: ${stderr}`);
      assert.match(stderr, /aggregat/i);
    } finally {
      await stub.close();
    }
  });
});

test('degradation: no keys at all -> exit code 2 with clear message', async () => {
  await withWorkspace(async (dir) => {
    const input = await writeInput(dir);
    const config = await writeConfig(dir, TWO_REF_CONFIG);
    const { code, stdout, stderr } = await runMoa(
      ['--input', input, '--config', config],
      { /* no keys */ }, dir,
    );
    assert.equal(code, 2, `expected exit 2, stderr: ${stderr}`);
    assert.match(stderr, /key/i);
    assert.ok(!stdout.includes('Bearer'), 'no key material should appear in stdout');
  });
});

test('config: empty reference_models array is a clean error, not silent aggregator-only (MO-2)', async () => {
  await withWorkspace(async (dir) => {
    const input = await writeInput(dir);
    const config = await writeConfig(dir, { reference_models: [] });
    const { code, stdout, stderr } = await runMoa(
      ['--input', input, '--config', config, '--dry-run'],
      { OPENAI_API_KEY: 'sk-oa' }, dir,
    );
    assert.equal(code, 1, `expected exit 1, stderr: ${stderr}`);
    assert.match(stderr, /reference_models/);
    assert.doesNotMatch(stderr, /^\s+at /m, 'must be a clean error, not a stack trace');
    assert.ok(!stdout.includes('default_provider'), 'must not proceed to a dry-run report');
  });
});

test('config: non-array reference_models is a clean error, not a silent DEFAULT fallback (MO-3)', async () => {
  await withWorkspace(async (dir) => {
    const input = await writeInput(dir);
    const config = await writeConfig(dir, { reference_models: 'gpt-5.6-sol' });
    const { code, stderr } = await runMoa(
      ['--input', input, '--config', config, '--dry-run'],
      { OPENAI_API_KEY: 'sk-oa' }, dir,
    );
    assert.equal(code, 1, `expected exit 1, stderr: ${stderr}`);
    assert.match(stderr, /reference_models/);
    assert.doesNotMatch(stderr, /^\s+at /m, 'must be a clean error, not a stack trace');
  });
});

test('redaction: fake key never appears in stdout / output file (success path)', async () => {
  await withWorkspace(async (dir) => {
    const SECRET = 'sk-SECRET-abc123XYZ';
    const stub = await startServer(chatHandler({ aggModel: 'agg-model' }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, TWO_REF_CONFIG);
      const out = join(dir, 'DEC.md');
      const { code, stdout, stderr } = await runMoa(
        ['--input', input, '--config', config, '--output', out],
        { OPENAI_API_KEY: SECRET, OPENAI_BASE_URL: `${stub.url}/v1` },
      );
      assert.equal(code, 0, `stderr: ${stderr}`);
      const doc = await readFile(out, 'utf8');
      assert.ok(!stdout.includes(SECRET), 'secret leaked to stdout');
      assert.ok(!stderr.includes(SECRET), 'secret leaked to stderr');
      assert.ok(!doc.includes(SECRET), 'secret leaked to output file');
    } finally {
      await stub.close();
    }
  });
});

test('redaction: an endpoint that echoes the auth header into the SUCCESS content cannot land the key in DEC.md / stdout (MO-1)', async () => {
  await withWorkspace(async (dir) => {
    const SECRET = 'sk-SECRETKEY-xyz789';
    const stub = await startServer(echoAuthHandler({ aggModel: 'agg-model' }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, TWO_REF_CONFIG);
      const out = join(dir, 'DEC.md');
      const { code, stdout, stderr } = await runMoa(
        ['--input', input, '--config', config, '--output', out],
        { OPENAI_API_KEY: SECRET, OPENAI_BASE_URL: `${stub.url}/v1` },
      );
      assert.equal(code, 0, `stderr: ${stderr}`);
      const doc = await readFile(out, 'utf8');
      // The reflected key rides in on the model output, which is embedded verbatim
      // into the decision doc — it must be scrubbed before write/emit.
      assert.ok(!doc.includes(SECRET), 'reflected key leaked into DEC.md');
      assert.ok(!stdout.includes(SECRET), 'reflected key leaked into stdout');
      assert.ok(!stderr.includes(SECRET), 'reflected key leaked into stderr');
    } finally {
      await stub.close();
    }
  });
});

test('redaction: key is scrubbed from HTTP error excerpts on stderr', async () => {
  await withWorkspace(async (dir) => {
    const SECRET = 'sk-SECRET-err789';
    // Aggregator 500s AND the stub echoes the Authorization header into the body;
    // moa surfaces an error excerpt, which must be redacted.
    const stub = await startServer(chatHandler({ aggModel: 'agg-model', failModels: ['agg-model'] }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, TWO_REF_CONFIG);
      const { code, stderr } = await runMoa(
        ['--input', input, '--config', config],
        { OPENAI_API_KEY: SECRET, OPENAI_BASE_URL: `${stub.url}/v1` },
      );
      assert.equal(code, 2);
      assert.ok(!stderr.includes(SECRET), `secret leaked in error excerpt: ${stderr}`);
    } finally {
      await stub.close();
    }
  });
});

test('config override: --config changes models (visible in dry-run)', async () => {
  await withWorkspace(async (dir) => {
    const input = await writeInput(dir);
    const config = await writeConfig(dir, {
      reference_models: ['cfg-a', 'cfg-b'],
      aggregator: 'cfg-agg',
    });
    const { code, stdout, stderr } = await runMoa(
      ['--input', input, '--config', config, '--dry-run'],
      { OPENAI_API_KEY: 'sk-fake' }, dir,
    );
    assert.equal(code, 0, stderr);
    for (const m of ['cfg-a', 'cfg-b', 'cfg-agg']) {
      assert.ok(stdout.includes(m), `dry-run missing model ${m}`);
    }
  });
});

test('config override: env LOOP_TESTING_MOA_* wins over config file', async () => {
  await withWorkspace(async (dir) => {
    const input = await writeInput(dir);
    const config = await writeConfig(dir, {
      reference_models: ['cfg-a', 'cfg-b'],
      aggregator: 'cfg-agg',
    });
    const { code, stdout, stderr } = await runMoa(
      ['--input', input, '--config', config, '--dry-run'],
      {
        OPENAI_API_KEY: 'sk-fake',
        LOOP_TESTING_MOA_MODELS: 'env-x,env-y',
        LOOP_TESTING_MOA_AGGREGATOR: 'env-agg',
      }, dir,
    );
    assert.equal(code, 0, stderr);
    for (const m of ['env-x', 'env-y', 'env-agg']) {
      assert.ok(stdout.includes(m), `dry-run missing env model ${m}`);
    }
    assert.ok(!stdout.includes('cfg-a'), 'env override should replace config reference models');
  });
});

test('fan-out guard: repeated reference_models are PRESERVED, not collapsed (MO-7)', async () => {
  await withWorkspace(async (dir) => {
    // reference_temperature defaults to 0.6, so re-listing a model is a valid
    // self-consistency sample (N stochastic calls -> N opinions), not a redundant
    // identical call. Under the cap it must pass through untouched, no "collapsed" note.
    const input = await writeInput(dir);
    const config = await writeConfig(dir, {
      reference_models: ['dup-a', 'dup-a', 'dup-b', 'dup-a'],
    });
    const { code, stdout, stderr } = await runMoa(
      ['--input', input, '--config', config, '--dry-run'],
      { OPENAI_API_KEY: 'sk-fake' }, dir,
    );
    assert.equal(code, 0, stderr);
    assert.doesNotMatch(stderr, /collapsed/, 'must not silently collapse repeated models');
    const occurrences = stdout.split('dup-a').length - 1;
    assert.equal(occurrences, 3, `dup-a should appear 3× in the dry-run (all kept), saw ${occurrences}`);
  });
});

test('fan-out guard: more than 8 reference_models -> clean error exit 1 (MO-7)', async () => {
  await withWorkspace(async (dir) => {
    const input = await writeInput(dir);
    const config = await writeConfig(dir, {
      reference_models: Array.from({ length: 9 }, (_, i) => `wide-${i}`),
    });
    const res = await runMoa(
      ['--input', input, '--config', config, '--dry-run'],
      { OPENAI_API_KEY: 'sk-fake' }, dir,
    );
    assertCleanUserError(res);
    assert.match(res.stderr, /capped at 8 parallel paid calls/);
  });
});

test('fan-out guard: duplicates count toward the cap (9 copies of one model -> exit 1) (MO-7)', async () => {
  await withWorkspace(async (dir) => {
    const input = await writeInput(dir);
    const config = await writeConfig(dir, {
      reference_models: Array.from({ length: 9 }, () => 'same-model'),
    });
    const res = await runMoa(
      ['--input', input, '--config', config, '--dry-run'],
      { OPENAI_API_KEY: 'sk-fake' }, dir,
    );
    assertCleanUserError(res);
    assert.match(res.stderr, /capped at 8 parallel paid calls/);
  });
});

// A user error (bad flag / bad config) must read as a clean one-line message,
// never a leaked Node stack trace — the engine is invoked by the driver/skill
// and stack noise pollutes decision archives and logs.
function assertCleanUserError({ code, stderr }) {
  assert.equal(code, 1, `expected exit 1, stderr: ${stderr}`);
  assert.match(stderr, /^error: /m);
  // Real V8 stack frames begin a line with indentation + "at " (e.g. "    at main (file:…)").
  // Guard against that shape specifically — not the word "at" appearing inline in a message.
  assert.ok(!/^\s+at /m.test(stderr), `stack trace leaked: ${stderr}`);
  assert.ok(!stderr.includes('fatal:'), `crashed instead of clean error: ${stderr}`);
}

test('user error: unknown flag -> clean message + usage, no stack trace', async () => {
  await withWorkspace(async (dir) => {
    const res = await runMoa(['--frobnicate'], { OPENAI_API_KEY: 'sk-fake' }, dir);
    assertCleanUserError(res);
    assert.match(res.stderr, /--frobnicate/);
    assert.match(res.stderr, /Usage:/);
  });
});

test('user error: explicit --config missing -> clean message, no stack trace', async () => {
  await withWorkspace(async (dir) => {
    const res = await runMoa(
      ['--dry-run', '--config', join(dir, 'does-not-exist.json')],
      { OPENAI_API_KEY: 'sk-fake' }, dir,
    );
    assertCleanUserError(res);
    assert.match(res.stderr, /config file not readable/);
  });
});

test('user error: malformed config JSON -> clean message, no stack trace', async () => {
  await withWorkspace(async (dir) => {
    const badPath = join(dir, 'moa.config.json');
    await writeFile(badPath, '{bad json', 'utf8');
    const res = await runMoa(
      ['--dry-run', '--config', badPath],
      { OPENAI_API_KEY: 'sk-fake' }, dir,
    );
    assertCleanUserError(res);
    assert.match(res.stderr, /not valid JSON/);
  });
});

test('user error: invalid model entry in config -> clean message, no stack trace', async () => {
  await withWorkspace(async (dir) => {
    const badPath = join(dir, 'moa.config.json');
    await writeFile(badPath, JSON.stringify({ reference_models: [123] }), 'utf8');
    const res = await runMoa(
      ['--dry-run', '--config', badPath],
      { OPENAI_API_KEY: 'sk-fake' }, dir,
    );
    assertCleanUserError(res);
    assert.match(res.stderr, /invalid model entry/);
  });
});

test('user error: unknown provider in config -> clean message, no stack trace', async () => {
  await withWorkspace(async (dir) => {
    const badPath = join(dir, 'moa.config.json');
    await writeFile(badPath, JSON.stringify({ reference_models: [{ model: 'x', provider: 'opusrouter' }] }), 'utf8');
    const res = await runMoa(
      ['--dry-run', '--config', badPath],
      { OPENAI_API_KEY: 'sk-fake' }, dir,
    );
    assertCleanUserError(res);
    assert.match(res.stderr, /unknown provider/);
  });
});

test('user error: unknown provider on aggregator -> clean message, no stack trace', async () => {
  await withWorkspace(async (dir) => {
    const badPath = join(dir, 'moa.config.json');
    await writeFile(badPath, JSON.stringify({ aggregator: { model: 'a', provider: 'nope' } }), 'utf8');
    const res = await runMoa(
      ['--dry-run', '--config', badPath],
      { OPENAI_API_KEY: 'sk-fake' }, dir,
    );
    assertCleanUserError(res);
    assert.match(res.stderr, /unknown provider/);
  });
});

test('user error: empty aggregator model -> clean message, not a 400 (audit C12)', async () => {
  await withWorkspace(async (dir) => {
    const badPath = join(dir, 'moa.config.json');
    await writeFile(badPath, JSON.stringify({ aggregator: '' }), 'utf8');
    const res = await runMoa(['--dry-run', '--config', badPath], { OPENAI_API_KEY: 'sk-fake' }, dir);
    assertCleanUserError(res);
    assert.match(res.stderr, /empty model/);
  });
});

test('proxy credentials: password, username, and the base64 auth blob never appear in output (audit C12)', async () => {
  await withWorkspace(async (dir) => {
    const input = await writeInput(dir);
    const proxyUser = 'PROXYUSER';
    const proxyPass = 'SUPERSECRETPW';
    // The base64 `user:pass` blob is what proxyAuthHeader() puts on the wire, so
    // it is itself a credential and must be redacted as a whole, not just its parts.
    const authBlob = Buffer.from(`${proxyUser}:${proxyPass}`).toString('base64');
    const { stdout, code } = await runMoa(
      ['--input', input, '--dry-run'],
      { OPENAI_API_KEY: 'sk-fake', HTTPS_PROXY: `http://${proxyUser}:${proxyPass}@127.0.0.1:9` }, dir,
    );
    assert.equal(code, 0);
    assert.ok(!stdout.includes(proxyPass), 'proxy password leaked to output');
    assert.ok(!stdout.includes(proxyUser), 'proxy username leaked to output');
    assert.ok(!stdout.includes(authBlob), 'proxy base64 auth blob leaked to output');
    assert.match(stdout, /proxy:\s*on/i);
  });
});

test('dry-run: makes zero network calls', async () => {
  await withWorkspace(async (dir) => {
    const stub = await startServer(chatHandler({ aggModel: 'agg-model' }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, TWO_REF_CONFIG);
      const { code, stdout, stderr } = await runMoa(
        ['--input', input, '--config', config, '--dry-run'],
        { OPENAI_API_KEY: 'sk-fake', OPENAI_BASE_URL: `${stub.url}/v1` },
      );
      assert.equal(code, 0, stderr);
      assert.match(stdout, /dry-run/i);
      assert.equal(stub.requests.length, 0, 'dry-run must not hit the network');
    } finally {
      await stub.close();
    }
  });
});

test('dry-run: reports proxy on/off and key presence as booleans (no values)', async () => {
  await withWorkspace(async (dir) => {
    const input = await writeInput(dir);
    const { stdout, code } = await runMoa(
      ['--input', input, '--dry-run'],
      { OPENAI_API_KEY: 'sk-should-not-print', HTTPS_PROXY: 'http://127.0.0.1:9' }, dir,
    );
    assert.equal(code, 0);
    assert.match(stdout, /proxy:\s*on/i);
    assert.match(stdout, /OPENAI_API_KEY:\s*set/);
    assert.match(stdout, /OPENROUTER_API_KEY:\s*missing/);
    assert.ok(!stdout.includes('sk-should-not-print'), 'dry-run leaked key value');
  });
});

// The https-origin CONNECT+TLS tunnel — the path every real proxied run takes,
// previously untested (audit A2). Full end-to-end: CONNECT -> TLS handshake ->
// tunneled HTTP, asserting the CONNECT target and SNI.
test('proxy CONNECT tunnel: https origin routes through CONNECT+TLS; CONNECT target + SNI correct',
  { skip: hasOpenssl() ? false : 'openssl unavailable (cannot mint a test cert)' },
  async () => {
    await withWorkspace(async (dir) => {
      const { key, cert } = await genCert(dir);
      const proxy = await startConnectProxy({ key, cert, chatHandler: tlsChatHandler({ aggModel: 'agg-model' }) });
      try {
        const input = await writeInput(dir);
        const config = await writeConfig(dir, ONE_REF_HTTPS);
        const out = join(dir, 'DEC.md');
        const { code, stderr } = await runMoa(
          ['--input', input, '--config', config, '--output', out],
          {
            OPENAI_API_KEY: 'sk-fake',
            OPENAI_BASE_URL: 'https://api.openai.com/v1',   // https origin -> CONNECT branch
            HTTPS_PROXY: proxy.url,
            NODE_TLS_REJECT_UNAUTHORIZED: '0',              // accept the self-signed test cert
          },
        );
        assert.equal(code, 0, `stderr: ${stderr}`);
        const doc = await readFile(out, 'utf8');
        assert.ok(doc.includes('R-reco'), 'aggregator reply did not come back through the tunnel');
        assert.ok(
          proxy.connects.some((l) => l === 'CONNECT api.openai.com:443 HTTP/1.1'),
          `CONNECT line wrong: ${proxy.connects.join(' | ')}`,
        );
        assert.ok(proxy.sni.includes('api.openai.com'), `SNI not observed: [${proxy.sni.join(',')}]`);
      } finally {
        await proxy.close();
      }
    });
  });

test('proxy CONNECT tunnel: URL credentials are sent as Proxy-Authorization on the CONNECT (R51)', async () => {
  await withWorkspace(async (dir) => {
    // A 403 proxy is enough: we assert the CONNECT *request* carried the header
    // (percent-decoded, base64-encoded), not that the tunnel succeeds.
    const proxy = await startConnectProxy({ status: '403 Forbidden' });
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, ONE_REF_HTTPS);
      const blob = Buffer.from('tunneluser:tunnelpw!').toString('base64');
      const { code } = await runMoa(
        ['--input', input, '--config', config],
        {
          OPENAI_API_KEY: 'sk-fake',
          OPENAI_BASE_URL: 'https://api.openai.com/v1',    // https origin -> CONNECT branch
          HTTPS_PROXY: `http://tunneluser:tunnelpw%21@127.0.0.1:${proxy.port}`,
        }, dir,
      );
      assert.equal(code, 2, 'refused CONNECT -> aggregator unavailable (exit 2)');
      const hdrBlock = proxy.headers.join('\n');
      assert.ok(
        hdrBlock.includes(`Proxy-Authorization: Basic ${blob}`),
        `CONNECT request lacked the expected Proxy-Authorization header:\n${hdrBlock}`,
      );
    } finally {
      await proxy.close();
    }
  });
});

test('proxy CONNECT tunnel: a non-200 CONNECT reply fails cleanly (exit 2, no stack)', async () => {
  await withWorkspace(async (dir) => {
    const proxy = await startConnectProxy({ status: '403 Forbidden' });
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, ONE_REF_HTTPS);
      const { code, stderr } = await runMoa(
        ['--input', input, '--config', config],
        { OPENAI_API_KEY: 'sk-fake', OPENAI_BASE_URL: 'https://api.openai.com/v1', HTTPS_PROXY: proxy.url },
      );
      assert.equal(code, 2, `expected exit 2, stderr: ${stderr}`);
      assert.ok(!/^\s+at /m.test(stderr), `stack leaked: ${stderr}`);
      assert.ok(proxy.connects.length >= 1, 'proxy never saw a CONNECT');
    } finally {
      await proxy.close();
    }
  });
});

test('proxy CONNECT tunnel: a proxy that never answers CONNECT times out cleanly, no hang', async () => {
  await withWorkspace(async (dir) => {
    const proxy = await startConnectProxy({ hang: true });
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, ONE_REF_HTTPS);
      const { code, stderr } = await runMoa(
        ['--input', input, '--config', config],
        {
          OPENAI_API_KEY: 'sk-fake',
          OPENAI_BASE_URL: 'https://api.openai.com/v1',
          HTTPS_PROXY: proxy.url,
          LOOP_TESTING_MOA_TIMEOUT_MS: '800',   // bound the wait so the test is fast
        },
      );
      assert.equal(code, 2, `expected exit 2 (aggregator unreachable), stderr: ${stderr}`);
      assert.ok(!/^\s+at /m.test(stderr), `stack leaked: ${stderr}`);
    } finally {
      await proxy.close();
    }
  });
});

test('response size cap: an oversized body is aborted, not buffered (exit 2, clean)', async () => {
  await withWorkspace(async (dir) => {
    const stub = await startServer(bigBodyHandler(2000));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, ONE_REF_HTTPS);
      const { code, stderr } = await runMoa(
        ['--input', input, '--config', config],
        { OPENAI_API_KEY: 'sk-fake', OPENAI_BASE_URL: `${stub.url}/v1`, LOOP_TESTING_MOA_MAX_RESPONSE_BYTES: '500' },
      );
      assert.equal(code, 2, `expected exit 2, stderr: ${stderr}`);
      assert.match(stderr, /exceeded 500 bytes/);
    } finally {
      await stub.close();
    }
  });
});

test('output write failure: decision goes to stdout + clean error (exit 1), not discarded', async () => {
  await withWorkspace(async (dir) => {
    const stub = await startServer(chatHandler({ aggModel: 'agg-model' }));
    try {
      const input = await writeInput(dir);
      const config = await writeConfig(dir, TWO_REF_CONFIG);
      const badOut = join(dir, 'no-such-dir', 'DEC.md');   // parent dir missing -> ENOENT
      const { code, stdout, stderr } = await runMoa(
        ['--input', input, '--config', config, '--output', badOut],
        { OPENAI_API_KEY: 'sk-fake', OPENAI_BASE_URL: `${stub.url}/v1` },
      );
      assert.equal(code, 1, `expected exit 1, stderr: ${stderr}`);
      assert.match(stderr, /could not write/);
      assert.ok(stdout.includes('R-reco'), 'decision not emitted to stdout on write failure');
    } finally {
      await stub.close();
    }
  });
});
