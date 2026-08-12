#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

SERVER_ADDR="${SERVER_ADDR:-your-server}"
DOMAIN_NAMES="${DOMAIN_NAMES:-}"
XUI_CONTAINER="${XUI_CONTAINER:-3xui}"
PANEL_PORT="${PANEL_PORT:-2053}"
WEB_BASE_PATH="${WEB_BASE_PATH:-panel}"
SITE_HTTP_PORT="${SITE_HTTP_PORT:-80}"
SITE_HTTPS_PORT="${SITE_HTTPS_PORT:-443}"
HTTPS_SITE_ENABLE="${HTTPS_SITE_ENABLE:-0}"
SUBSCRIPTION_TOKEN="${SUBSCRIPTION_TOKEN:-}"
ENABLE_SUB_CONFIG_EDITOR="${ENABLE_SUB_CONFIG_EDITOR:-1}"
SUB_CONFIG_ADMIN_TOKEN="${SUB_CONFIG_ADMIN_TOKEN:-}"
SERVER_ALIASES="${SERVER_ALIASES:-}"
SUBSCRIPTION_EXPAND_ALIASES="${SUBSCRIPTION_EXPAND_ALIASES:-1}"
XUI_API_BASE="${XUI_API_BASE:-}"
XUI_API_TOKEN="${XUI_API_TOKEN:-}"

set_env_var() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if [ -f .env ]; then
    awk -v k="$key" -v v="$value" '
      BEGIN { done = 0 }
      $0 ~ "^" k "=" { print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' .env > "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
  fi
  mv "$tmp" .env
  chmod 600 .env
}

new_token() {
  openssl rand -hex 16
}

normalize_aliases() {
  local values="$1"
  printf '%s' "$values" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++ { printf "%s%s", sep, $0; sep="," }'
}

ensure_xui_api_env() {
  local aliases token out
  XUI_API_BASE="http://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH#/}"
  set_env_var XUI_API_BASE "$XUI_API_BASE"

  if [ -z "$SERVER_ALIASES" ]; then
    aliases="$(normalize_aliases "${DOMAIN_NAMES:-$SERVER_ADDR}")"
    SERVER_ALIASES="${aliases:-$SERVER_ADDR}"
  fi
  set_env_var SERVER_ALIASES "$SERVER_ALIASES"
  set_env_var SUBSCRIPTION_EXPAND_ALIASES "$SUBSCRIPTION_EXPAND_ALIASES"

  if [ -z "$XUI_API_TOKEN" ] && docker inspect "$XUI_CONTAINER" >/dev/null 2>&1; then
    out="$(docker exec "$XUI_CONTAINER" /app/x-ui setting -getApiToken true 2>/dev/null || true)"
    token="$(printf '%s\n' "$out" | awk '/apiToken:/ {print $2}' | tail -n1)"
    if [ -n "$token" ]; then
      XUI_API_TOKEN="$token"
      set_env_var XUI_API_TOKEN "$XUI_API_TOKEN"
    fi
  elif [ -n "$XUI_API_TOKEN" ]; then
    set_env_var XUI_API_TOKEN "$XUI_API_TOKEN"
  fi
}

public_origin_hint() {
  if [ "$HTTPS_SITE_ENABLE" = "1" ]; then
    if [ "$SITE_HTTPS_PORT" = "443" ]; then
      printf 'https://%s' "$SERVER_ADDR"
    else
      printf 'https://%s:%s' "$SERVER_ADDR" "$SITE_HTTPS_PORT"
    fi
  else
    if [ "$SITE_HTTP_PORT" = "80" ]; then
      printf 'http://%s' "$SERVER_ADDR"
    else
      printf 'http://%s:%s' "$SERVER_ADDR" "$SITE_HTTP_PORT"
    fi
  fi
}

write_subscription_files() {
  mkdir -p site/sub/config site/subscriptions runtime
  chmod 700 runtime

  if [ -z "$SUBSCRIPTION_TOKEN" ]; then
    SUBSCRIPTION_TOKEN="$(new_token)"
    set_env_var SUBSCRIPTION_TOKEN "$SUBSCRIPTION_TOKEN"
  fi
  if [ -z "$SUB_CONFIG_ADMIN_TOKEN" ]; then
    SUB_CONFIG_ADMIN_TOKEN="$(new_token)"
    set_env_var SUB_CONFIG_ADMIN_TOKEN "$SUB_CONFIG_ADMIN_TOKEN"
  fi

  if [ ! -s site/sub/config/3.5.yaml ]; then
    cat > site/sub/config/3.5.yaml <<'EOF'
port: 7890
socks-port: 7891
allow-lan: true
mode: Rule
log-level: info
external-controller: 127.0.0.1:9090
proxies:
  - {name: 测试3ip, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
  - {name: 测试4域名, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
  - {name: 测试5V6, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
  - {name: 测试6域名, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
  - {name: 测试10域名, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies:
      - 测试3ip
      - 测试4域名
      - 测试5V6
      - 测试6域名
      - 测试10域名
      - DIRECT
rules:
  - MATCH,🚀 节点选择
EOF
  fi

  local links_source=""
  if [ -s runtime/panel-all-links.txt ]; then
    links_source="runtime/panel-all-links.txt"
  elif [ -s runtime/client-links.txt ]; then
    links_source="runtime/client-links.txt"
  fi

  if [ -n "$links_source" ]; then
    awk '/^(vless|vmess|trojan|ss|hysteria2):\/\// { print }' "$links_source" > "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt"
    if command -v base64 >/dev/null 2>&1 && base64 --help 2>&1 | grep -q -- '-w'; then
      base64 -w0 "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" > "site/subscriptions/${SUBSCRIPTION_TOKEN}.b64"
    else
      openssl base64 -A -in "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" -out "site/subscriptions/${SUBSCRIPTION_TOKEN}.b64"
    fi
    printf '\n' >> "site/subscriptions/${SUBSCRIPTION_TOKEN}.b64"
  else
    cat > "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" <<'EOF'
# No node links generated yet.
# Run: cd /opt/3xui-selfhost-kit && ./scripts/manage.sh apply-presets
EOF
    cp "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" "site/subscriptions/${SUBSCRIPTION_TOKEN}.b64"
  fi
  chmod 644 "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" 2>/dev/null || true
  chmod 644 "site/subscriptions/${SUBSCRIPTION_TOKEN}.b64" 2>/dev/null || true
}

write_web_ui() {
  local token="$SUBSCRIPTION_TOKEN"
  cat > site/sub/index.html <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <title>节点订阅</title>
  <style>
    :root { color-scheme: light dark; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; min-height: 100vh; background: #f5f7fb; color: #172033; display: grid; place-items: center; }
    main { width: min(880px, calc(100vw - 32px)); background: rgba(255,255,255,.9); border: 1px solid #d9e2ef; padding: 28px; box-shadow: 0 18px 60px rgba(15,23,42,.12); }
    h1 { margin: 0 0 8px; font-size: 30px; letter-spacing: 0; }
    p { color: #5b6473; line-height: 1.6; }
    label { display: block; margin: 18px 0 8px; font-weight: 700; }
    input, select, textarea { width: 100%; box-sizing: border-box; border: 1px solid #bdc8d8; border-radius: 6px; padding: 12px; font: inherit; background: #fff; color: #111827; }
    textarea { min-height: 86px; resize: vertical; }
    button, a.button { display: inline-flex; align-items: center; justify-content: center; border: 0; border-radius: 6px; padding: 11px 16px; margin: 14px 10px 0 0; background: #2563eb; color: #fff; font-weight: 700; text-decoration: none; cursor: pointer; }
    button.secondary { background: #334155; }
    code { word-break: break-all; display: block; background: #eef2f7; padding: 12px; border-radius: 6px; }
    .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
    .primary { margin: 24px 0; padding: 18px; border: 1px solid #d9e2ef; border-radius: 10px; background: rgba(248,250,252,.9); }
    .primary label:first-child { margin-top: 0; }
    details { margin-top: 26px; border-top: 1px solid #d9e2ef; padding-top: 18px; }
    summary { cursor: pointer; font-weight: 700; }
    .editor { margin-top: 32px; padding-top: 24px; border-top: 1px solid #d9e2ef; }
    #configEditor { min-height: 420px; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 13px; line-height: 1.5; }
    #editStatus { margin-top: 12px; white-space: pre-wrap; }
    @media (max-width: 760px) { .grid { grid-template-columns: 1fr; } main { padding: 20px; } }
    @media (prefers-color-scheme: dark) {
      body { background: #0f172a; color: #e5e7eb; }
      main { background: rgba(15,23,42,.92); border-color: #334155; }
      p { color: #b6c2d1; }
      input, select, textarea { background: #111827; color: #e5e7eb; border-color: #475569; }
      code { background: #111827; }
      .primary { background: rgba(15,23,42,.55); border-color: #334155; }
      details { border-color: #334155; }
      .editor { border-color: #334155; }
    }
  </style>
</head>
<body>
  <main>
    <h1>节点订阅</h1>
    <p>默认自动同步服务器当前入站并生成 Clash 3.5 短订阅。无需粘贴节点、填写 Token 或手动保存默认项。</p>
    <section class="primary">
      <label>当前节点订阅</label>
      <code id="sourceLink"></code>
      <button onclick="copySource()">复制订阅</button>
      <a id="openSource" class="button" target="_blank" rel="noreferrer">打开订阅</a>
      <button class="secondary" onclick="refreshLinks()">刷新并重新生成</button>
      <label>Clash 3.5 短订阅</label>
      <code id="result">正在同步服务器节点…</code>
      <button class="secondary" onclick="copyResult()">复制短订阅</button>
      <code id="allLinksStatus">首次打开会自动检查当前服务器节点。</code>
    </section>
    <details>
      <summary>高级转换与规则管理</summary>
      <p>仅在导入外部节点、切换客户端格式或编辑 3.5.yaml 规则时使用。</p>
      <label for="url">自定义节点 / 远程订阅</label>
      <textarea id="url" placeholder="留空时使用上方当前节点订阅；也可粘贴 vless://、trojan://、ss:// 或远程订阅 URL"></textarea>
      <div class="grid">
      <div>
        <label for="target">目标格式</label>
        <select id="target">
          <option value="clash-35">Clash 3.5.yaml</option>
          <option value="clash">Clash subconverter</option>
          <option value="singbox">sing-box</option>
          <option value="v2ray">V2Ray</option>
          <option value="surge&ver=4">Surge 4</option>
          <option value="quanx">Quantumult X</option>
          <option value="mixed">Mixed</option>
        </select>
      </div>
      <div>
        <label for="config">远程配置 / 规则模板</label>
        <input id="config">
      </div>
      </div>
      <button onclick="build()">按高级选项生成</button>
      <button onclick="openResult()">打开生成链接</button>
      <a class="button" href="/sub/config/3.5.yaml" target="_blank" rel="noreferrer">查看 3.5.yaml</a>
      <section class="editor">
      <h1>3.5.yaml 规则</h1>
      <p>转换链接默认使用这份规则配置。保存时请保留节点名称，分流组会按这些名称匹配。</p>
      <label for="adminToken">规则编辑 Token</label>
      <input id="adminToken" type="password" autocomplete="off">
      <label for="ruleFile">上传 YAML 规则文件</label>
      <input id="ruleFile" type="file" accept=".yaml,.yml,text/yaml,application/yaml,text/plain">
      <button onclick="uploadRules()">上传并保存为服务器规则</button>
      <button class="secondary" onclick="validateRules()">验证 YAML 语法</button>
      <button class="secondary" onclick="loadRules()">读取规则</button>
      <button onclick="saveRules()">保存规则</button>
      <label for="configEditor">规则内容</label>
      <textarea id="configEditor" spellcheck="false"></textarea>
      <code id="editStatus"></code>
      </section>
    </details>
  </main>
  <script>
    const token = "${token}";
    const defaultConfig = location.origin + "/sub/config/3.5.yaml";
    const localSub = location.origin + "/subscriptions/" + token + ".b64";
    const urlEl = document.getElementById("url");
    const targetEl = document.getElementById("target");
    const configEl = document.getElementById("config");
    const resultEl = document.getElementById("result");
    const sourceLinkEl = document.getElementById("sourceLink");
    const openSourceEl = document.getElementById("openSource");
    const adminTokenEl = document.getElementById("adminToken");
    const ruleFileEl = document.getElementById("ruleFile");
    const configEditorEl = document.getElementById("configEditor");
    const editStatusEl = document.getElementById("editStatus");
    sourceLinkEl.textContent = localSub;
    openSourceEl.href = localSub;
    urlEl.value = "";
    targetEl.value = "clash-35";
    configEl.value = defaultConfig;
    adminTokenEl.value = localStorage.getItem("xuiSubConfigAdminToken") || "";
    urlEl.addEventListener("input", () => { resultEl.dataset.url = ""; });
    configEl.addEventListener("input", () => { resultEl.dataset.url = ""; });
    targetEl.addEventListener("change", () => { resultEl.dataset.url = ""; });
    async function buildClash35Link() {
      const customSource = urlEl.value.trim();
      const source = customSource || localSub;
      const config = configEl.value.trim();
      if (!source) throw new Error("请先粘贴至少一条节点连接");
      const response = await fetch(location.origin + "/subconfig-api/shorten?token=" + encodeURIComponent(token), {
        method: "POST",
        headers: {"Content-Type": "application/json; charset=utf-8"},
        body: JSON.stringify({source, managed: !customSource, config: config && config !== defaultConfig ? config : ""})
      });
      const raw = await response.text();
      let data;
      try {
        data = raw ? JSON.parse(raw) : {};
      } catch (_) {
        throw new Error("服务器返回了空或无效响应");
      }
      if (!response.ok || !data.success) throw new Error(data.error || response.statusText);
      return {url: location.origin + data.path, count: data.count};
    }
    async function build() {
      const targetValue = targetEl.value;
      const config = configEl.value.trim();
      const source = urlEl.value.trim() || localSub;
      localStorage.setItem("xuiSubSource", source);
      localStorage.setItem("xuiSubTarget", targetValue);
      localStorage.setItem("xuiSubConfig", config || defaultConfig);
      if (targetValue === "clash-35") {
        try {
          resultEl.textContent = "正在生成短链接...";
          const result = await buildClash35Link();
          resultEl.textContent = result.url;
          resultEl.title = "已保存 " + result.count + " 个节点";
          resultEl.dataset.url = result.url;
          return result.url;
        } catch (error) {
          resultEl.textContent = "生成失败: " + error.message;
          resultEl.dataset.url = "";
          return "";
        }
      }
      const params = new URLSearchParams();
      for (const [index, part] of targetValue.split("&").entries()) {
        const [k, v] = part.split("=");
        if (index === 0) {
          params.set("target", k);
        } else {
          params.set(k, v || "");
        }
      }
      params.set("url", source);
      if (config) params.set("config", config);
      const result = location.origin + "/subconverter/sub?" + params.toString();
      resultEl.textContent = result;
      resultEl.dataset.url = result;
      return result;
    }
    async function openResult() {
      const targetWindow = window.open("about:blank", "_blank");
      const result = resultEl.dataset.url || await build();
      if (result && targetWindow) targetWindow.location.href = result;
      else if (targetWindow) targetWindow.close();
    }
    async function copyResult() {
      const result = resultEl.dataset.url || await build();
      if (result) await navigator.clipboard.writeText(result);
    }
    async function refreshLinks() {
      try {
        const response = await fetch(location.origin + "/subconfig-api/refresh-public-links", {method: "POST"});
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.error || response.statusText);
        const result = await buildClash35Link();
        document.getElementById("allLinksStatus").textContent =
          (data.cached ? "已使用最近同步" : "已同步") + " " + data.count + " 条当前节点。";
      } catch (error) {
        document.getElementById("allLinksStatus").textContent = "同步失败，已保留当前订阅: " + error.message;
        await build();
      }
    }
    async function copySource() {
      await navigator.clipboard.writeText(localSub);
      document.getElementById("allLinksStatus").textContent = "当前节点订阅已复制。";
    }
    async function configApi(method, body, path = "/config") {
      const headers = {"X-Admin-Token": adminTokenEl.value.trim()};
      if (body !== undefined) headers["Content-Type"] = "text/yaml; charset=utf-8";
      const response = await fetch(location.origin + "/subconfig-api" + path, {method, headers, body});
      const text = await response.text();
      if (!response.ok) {
        let message = text || response.statusText;
        try {
          const data = JSON.parse(text);
          message = data.error || data.message || message;
        } catch (_) {}
        throw new Error(message);
      }
      return text;
    }
    async function loadRules() {
      try {
        editStatusEl.textContent = "正在读取...";
        localStorage.setItem("xuiSubConfigAdminToken", adminTokenEl.value.trim());
        configEditorEl.value = await configApi("GET");
        editStatusEl.textContent = "已读取服务器上的 3.5.yaml。";
      } catch (error) {
        editStatusEl.textContent = "读取失败: " + error.message;
      }
    }
    async function saveRules() {
      try {
        editStatusEl.textContent = "正在验证 YAML 语法...";
        localStorage.setItem("xuiSubConfigAdminToken", adminTokenEl.value.trim());
        await configApi("POST", configEditorEl.value, "/validate");
        editStatusEl.textContent = "语法正确，正在保存...";
        await configApi("PUT", configEditorEl.value);
        configEl.value = defaultConfig;
        await build();
        editStatusEl.textContent = "YAML 语法正确并已保存。现在可以生成转换链接。";
      } catch (error) {
        editStatusEl.textContent = "保存失败: " + error.message;
      }
    }
    async function validateRules() {
      try {
        editStatusEl.textContent = "正在验证 YAML 语法...";
        localStorage.setItem("xuiSubConfigAdminToken", adminTokenEl.value.trim());
        await configApi("POST", configEditorEl.value, "/validate");
        editStatusEl.textContent = "YAML 语法正确，可以保存。";
      } catch (error) {
        editStatusEl.textContent = "语法错误，未保存: " + error.message;
      }
    }
    async function uploadRules() {
      try {
        const file = ruleFileEl.files && ruleFileEl.files[0];
        if (!file) throw new Error("请先选择 .yaml 或 .yml 文件");
        editStatusEl.textContent = "正在读取并上传 " + file.name + "...";
        configEditorEl.value = await file.text();
        await saveRules();
      } catch (error) {
        editStatusEl.textContent = "上传失败: " + error.message;
      }
    }
    refreshLinks();
  </script>
</body>
</html>
EOF
}

start_subscription_services() {
  if [ "${ENABLE_SUBCONVERTER:-1}" != "1" ]; then
    return
  fi
  docker compose pull subconverter
  docker compose up -d subconverter
  if [ "${ENABLE_SUB_CONFIG_EDITOR:-1}" = "1" ]; then
    docker compose build --pull subconfig-api
    docker compose up -d --force-recreate subconfig-api
  fi
}

refresh_links_from_api() {
  [ "${ENABLE_SUB_CONFIG_EDITOR:-1}" = "1" ] || return 0
  [ -n "${SUB_CONFIG_ADMIN_TOKEN:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local i response
  for i in $(seq 1 20); do
    response="$(curl -fsS --connect-timeout 2 --max-time 10 \
      -X POST \
      -H "X-Admin-Token: ${SUB_CONFIG_ADMIN_TOKEN}" \
      "http://127.0.0.1:${SUB_CONFIG_PORT:-27880}/refresh-links" 2>/dev/null || true)"
    if printf '%s' "$response" | grep -Eq '"success"[[:space:]]*:[[:space:]]*true'; then
      if [ -s "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" ]; then
        {
          echo "Domain all-nodes subscription links"
          awk '/^(vless|vmess|trojan|ss|hysteria2):\/\// { print }' "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt"
          echo
        } > runtime/client-links.txt
        chmod 600 runtime/client-links.txt 2>/dev/null || true
      fi
      echo "Subscription links refreshed from all-nodes clients."
      return 0
    fi
    sleep 1
  done
  echo "Subscription API refresh did not complete yet; use the Web UI refresh button or run manage.sh refresh-links later." >&2
}

main() {
  ensure_xui_api_env
  write_subscription_files
  write_web_ui
  start_subscription_services
  refresh_links_from_api
  echo "Subscription web UI:"
  echo "  $(public_origin_hint)/sub/"
  echo "Forward web UI:"
  echo "  $(public_origin_hint)/forward/"
  echo "Tokenized local node subscription:"
  echo "  $(public_origin_hint)/subscriptions/${SUBSCRIPTION_TOKEN}.txt"
  echo "Default conversion config:"
  echo "  $(public_origin_hint)/sub/config/3.5.yaml"
  echo "Rules editor token:"
  echo "  ${SUB_CONFIG_ADMIN_TOKEN}"
}

main "$@"
