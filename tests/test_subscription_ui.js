const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

async function main() {
  const source = fs.readFileSync(path.join(__dirname, '../scripts/subscription.sh'), 'utf8');
  const script = source.match(/<script>([\s\S]*?)<\/script>/)[1].replace('${token}', 'unit-test-subscription');
  const elements = new Map();
  const copied = [];
  const requests = [];
  const context = vm.createContext({
    URLSearchParams,
    location: { origin: 'https://subscription.example' },
    localStorage: { getItem: () => null, setItem: () => {} },
    navigator: { clipboard: { writeText: async value => copied.push(value) } },
    document: { getElementById: id => {
      if (!elements.has(id)) elements.set(id, { value: '', dataset: {}, addEventListener: () => {} });
      return elements.get(id);
    } },
    fetch: async (url, options) => {
      requests.push({ url, options });
      const data = url.includes('/refresh-public-links')
        ? { success: true, count: 2, cached: false }
        : { success: true, count: 2, path: '/subconfig-api/s/fixture-id.yaml' };
      return { ok: true, json: async () => data, text: async () => JSON.stringify(data) };
    },
  });
  vm.runInContext(script, context);
  await new Promise(setImmediate);
  const primary = elements.get('sourceLink').textContent;
  assert.equal(primary, 'https://subscription.example/subconfig-api/clash.yaml?token=unit-test-subscription');
  assert.equal(elements.get('openSource').href, primary);
  await context.copySource();
  assert.equal(copied.pop(), primary);
  assert.equal(elements.get('result').textContent, 'https://subscription.example/subconfig-api/s/fixture-id.yaml');
  await context.copyResult();
  assert.equal(copied.pop(), 'https://subscription.example/subconfig-api/s/fixture-id.yaml');
  const shorten = requests.find(request => request.url.includes('/shorten'));
  const payload = JSON.parse(shorten.options.body);
  assert.equal(payload.managed, true);
  assert.match(payload.source, /\/subscriptions\/unit-test-subscription\.b64$/);
  // Other converters must consume the original node list, not our YAML endpoint.
  elements.get('target').value = 'singbox';
  const converted = new URL(await context.build());
  assert.equal(converted.searchParams.get('url'), 'https://subscription.example/subscriptions/unit-test-subscription.b64');
  console.log('Subscription UI: YAML copy/open, initial short link and legacy converters passed');
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
