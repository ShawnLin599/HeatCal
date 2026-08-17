# HeatCalAIProxy

热量咔使用的最小 AI Provider 代理。它负责把 iOS App 的图片与文字请求转发给 Provider，同时避免把 API Key 放进客户端。

## 快速启动

在仓库根目录运行：

```bash
cp backend/.env.example .env.local
python3 -m backend.heatcal_proxy --env-file .env.local
```

真机联调时，可以让代理监听局域网：

```bash
HEATCAL_PROXY_HOST=0.0.0.0 python3 -m backend.heatcal_proxy --env-file .env.local
```

检查配置状态（不会输出 Key）：

```bash
python3 -m backend.heatcal_proxy --env-file .env.local --check-config
```

## API

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| `GET` | `/health`、`/v1/status` | 服务状态和 Provider 配置状态 |
| `POST` | `/v1/analyze/photo` | 图片食物识别与营养估算 |
| `POST` | `/v1/analyze/text` | 自然语言饮食补记 |
| `POST` | `/v1/corrections/parse` | 实际摄入量语义修正 |

错误响应统一包含稳定的错误码、可恢复状态和 fallback 标记，不回传 Provider 原始敏感响应。

## 安全说明

- 不要提交 `.env.local` 或任何真实 Key。
- 状态接口只暴露「是否已配置」，不会返回密钥内容。
- 公开部署时应在代理前增加访问控制、限流和日志脱敏。
