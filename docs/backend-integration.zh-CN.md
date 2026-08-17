# 热量咔真实 AI Provider / 轻量后端接入说明

- 关联任务：`CAL-20260618-008`
- 状态：研发实现完成；真实 Provider 端到端验证已复跑通过，待项目管理部派发 QA 复验
- 边界：iOS App 不持有 Provider API Key；真实 Provider 调用只通过本机轻量代理。

## 1. 架构

本次接入采用最小本地代理：

`iOS App → HeatCalAIProxy → DashScope / DeepSeek`

运行地址按设备区分：

- iOS Simulator：默认 `http://127.0.0.1:8787`。
- iPhone 真机：在 App 设置页配置 `http://<Mac局域网IP>:8787`，Mac 代理使用 `HEATCAL_PROXY_HOST=0.0.0.0` 启动。

- DashScope/Qwen：图片食物识别与初步结构化估算。
- DeepSeek：文字补记、自然语言纠错、实际摄入调整语义解析。
- OpenAI：仅保留环境变量插口，不作为当前完成条件。
- mock：仅作为开发或 Provider 故障兜底，App 会显示 `FALLBACK` 和状态文案。
- iOS App 只保存代理 baseURL，不保存、读取或展示 Provider API Key。

## 2. 交付物

| 路径 | 说明 |
| --- | --- |
| `backend/heatcal_proxy.py` | Python 标准库实现的最小 HTTP 代理、Provider 调用、schema 校验和错误归一化 |
| `backend/README.md` | 启动方式、环境变量和 API 合约 |
| `tests/test_heatcal_ai_proxy.py` | 后端契约与安全回归测试 |
| `应用/HeatCalMockApp/HeatCalMockApp/MockAnalysisService.swift` | iOS 真实代理客户端与响应解码 |
| `应用/HeatCalMockApp/HeatCalMockApp/AppStore.swift` | 真实分析、真实纠错、mock 兜底状态管理 |
| `应用/HeatCalMockApp/HeatCalMockApp/Views.swift` | 真实图片/文字入口、真实/兜底状态展示 |
| `应用/HeatCalMockApp/HeatCalMockAppTests/HeatCalMockAppTests.swift` | iOS 代理响应解码与错误回归测试 |

## 3. 启动方式

在仓库根目录运行：

```bash
python3 -m backend.heatcal_proxy --env-file .env.local
```

真机联调时改为监听局域网地址：

```bash
HEATCAL_PROXY_HOST=0.0.0.0 python3 -m backend.heatcal_proxy --env-file .env.local
```

随后在 iPhone Safari 或 App 设置页健康检查：

```text
http://<Mac局域网IP>:8787/health
```

Mac 局域网 IP 不一定在 `en0`。推荐先用 `ifconfig | grep "inet "` 查看全部 IPv4 地址，以 `192.168.x.x`、`10.x.x.x` 或 `172.16.x.x–172.31.x.x` 为准；也可分别尝试 `ipconfig getifaddr en0` 和 `ipconfig getifaddr en1`。真机不要使用 `127.0.0.1`。

只检查非密钥配置状态：

```bash
python3 -m backend.heatcal_proxy --env-file .env.local --check-config
```

`.env.local` 仅用于本地环境变量注入，不纳入 Git，不写入文档，不在日志或测试输出中打印。

如果本机网络存在 HTTPS 中间证书或代理拦截，需要先把可信 CA 加入系统/Python 信任链，或通过 `SSL_CERT_FILE` 指向可信 CA bundle。代理不会关闭 TLS 证书校验。

## 4. 环境变量

| 变量 | 必需性 | 说明 |
| --- | --- | --- |
| `DASHSCOPE_API_KEY` | 图片链路必需 | DashScope/Qwen API Key |
| `DASHSCOPE_BASE_URL` | 可选 | 默认 `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| `DASHSCOPE_VISION_MODEL` | 可选 | 默认 `qwen-vl-plus` |
| `DEEPSEEK_API_KEY` | 文字/纠错链路必需 | DeepSeek API Key |
| `DEEPSEEK_BASE_URL` | 可选 | 默认 `https://api.deepseek.com` |
| `DEEPSEEK_TEXT_MODEL` | 可选 | 默认 `deepseek-v4-flash` |
| `OPENAI_API_KEY` | 可选 | 当前仅保留插口 |
| `HEATCAL_PROXY_HOST` | 可选 | 默认 `127.0.0.1`；真机联调使用 `0.0.0.0` 让同 Wi-Fi iPhone 访问 Mac 代理 |
| `HEATCAL_PROXY_PORT` | 可选 | 默认 `8787` |
| `HEATCAL_PROXY_TIMEOUT_SECONDS` | 可选 | 默认 `120`，图片链路可按网络情况继续调大 |

## 5. API 合约

### `GET /health` / `GET /v1/status`

返回服务状态、Provider 是否配置和模型名，不返回密钥。

### `POST /v1/analyze/photo`

请求：

```json
{
  "image_base64": "...",
  "image_mime_type": "image/jpeg",
  "description": "可选补充说明"
}
```

响应：

```json
{
  "ok": true,
  "mode": "real",
  "source": "dashscope",
  "model": "qwen-vl-plus",
  "meal": {
    "date": "2026-06-19T12:20:00+08:00",
    "meal_type": "lunch",
    "source_description": "相册饮食照片",
    "confidence": "一般",
    "estimated_range": {"lower": 520, "upper": 760},
    "items": [
      {
        "name": "宫保鸡丁",
        "quantity": {"amount": 1, "unit": "份", "grams": 260, "size": "中份"},
        "nutrition": {"calories": 420, "protein": 28, "carbs": 24, "fat": 24},
        "confidence": "一般",
        "note": "用油量未知"
      }
    ]
  },
  "warnings": []
}
```

### `POST /v1/analyze/text`

请求：

```json
{"text": "昨晚加餐吃了一个苹果"}
```

响应同 `meal` schema，`source` 为 `deepseek`。

### `POST /v1/corrections/parse`

请求：

```json
{
  "text": "宫保鸡丁吃了一半，米饭全部吃完",
  "items": [
    {"id": "uuid", "name": "宫保鸡丁", "amount": 1, "unit": "份", "grams": 260, "note": "照片上方"}
  ]
}
```

响应：

```json
{
  "ok": true,
  "mode": "real",
  "source": "deepseek",
  "correction": {
    "corrections": [
      {"food_name": "宫保鸡丁", "match": "exact", "ratio": 0.5, "unit": "份", "note": "用户说吃了一半"}
    ],
    "needs_clarification": false
  }
}
```

## 6. 错误处理

后端统一返回 `missing_key`、`auth_failed`、`quota_or_rate_limited`、`provider_unavailable`、`timeout`、`invalid_response`、`bad_request`。iOS 端收到错误后：

- 显示真实 AI 不可用的状态文案；
- 可回退到 mock 兜底，但记录行会标为 `FALLBACK`；
- 不把 mock 结果伪装成真实 Provider 结果。

## 7. 验证命令

```bash
python3 -m unittest tests/test_heatcal_ai_proxy.py
python3 -m backend.heatcal_proxy --env-file .env.local --check-config
xcodebuild build-for-testing -quiet -project '应用/HeatCalMockApp/HeatCalMockApp.xcodeproj' -scheme HeatCalMockApp -destination 'generic/platform=iOS Simulator' -derivedDataPath '应用/HeatCalMockApp/DerivedData' CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project '应用/HeatCalMockApp/HeatCalMockApp.xcodeproj' -scheme HeatCalMockApp -destination 'generic/platform=iOS' -derivedDataPath '应用/HeatCalMockApp/DerivedData' CODE_SIGNING_ALLOWED=NO
```

真实端到端验证需本机 `.env.local` 中存在有效 `DASHSCOPE_API_KEY` 和 `DEEPSEEK_API_KEY`，且当前环境允许访问 Provider 网络。

## 8. 本次验证结果

- `python3 -m unittest tests/test_heatcal_ai_proxy.py`：通过，8 个后端契约/安全/真实图片 JSON 重试回归测试通过。
- `python3 -m backend.heatcal_proxy --env-file .env.local --check-config`：通过；仅输出 Provider 是否配置与模型名，未输出 Key。
- XcodeBuildMCP `build_sim`（iPhone 17）：通过，模拟器构建成功，无诊断错误。
- XcodeBuildMCP `test_sim`（iPhone 17）：失败于 CoreSimulator 克隆设备卡住，未进入 XCTest 断言。
- XcodeBuildMCP `test_sim`（iPhone 17 Pro）：通过，13 个 XCTest 全部通过，0 失败。
- `xcodebuild build -quiet -project '应用/HeatCalMockApp/HeatCalMockApp.xcodeproj' -scheme HeatCalMockApp -destination 'generic/platform=iOS' -derivedDataPath '应用/HeatCalMockApp/DerivedData' CODE_SIGNING_ALLOWED=NO`：退出码 0。
- 真实 DeepSeek 文字链路：已使用 `.env.local` 注入配置并发起请求；返回 `ok=true`、`mode=real`、`source=deepseek`，识别项包含鸡蛋和米饭，未打印 Key。
- 真实 DeepSeek 纠错链路：返回 `ok=true`、`mode=real`、`source=deepseek`，解析出鸡蛋 1 个、米饭 0.5 碗，未打印 Key。
- 真实 DashScope 图片链路：使用已忽略的本地验收 fixture `测试/验收/fixtures/CAL-20260618-008-real-food-20260619.png`；返回 `ok=true`、`mode=real`、`source=dashscope`、`model=qwen-vl-plus`，识别项包含吐司、蛋挞、煮鸡蛋和酱肉，未打印 Key。
- 仓库敏感形态扫描：未发现 Provider Key 明文或常见密钥赋值形态。

## 9. 已知限制与后续清单

- 当前限制：iPhone 17 模拟器克隆仍可复现失败，但 iPhone 17 Pro 运行态测试已通过；真实照片 fixture 已通过 `.gitignore` 忽略，不得提交。
- 当前未接入 OpenAI；仅保留插口，符合本任务基线。
- mock fallback 仅作为开发/故障兜底，iOS 会在状态文案和记录标识中区分 `REAL AI` 与 `FALLBACK`。
