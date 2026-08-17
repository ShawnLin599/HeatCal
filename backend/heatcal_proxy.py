import argparse
import json
import os
import ssl
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


MEAL_TYPES = {"breakfast", "lunch", "dinner", "snack"}
CONFIDENCE_LEVELS = {"较高", "一般", "较低"}


@dataclass
class AppConfig:
    dashscope_api_key: str = ""
    dashscope_base_url: str = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    # qwen-vl-plus will be retired by DashScope. Keep the model configurable,
    # but default new deployments to the current low-latency vision model.
    dashscope_vision_model: str = "qwen3.6-flash"
    deepseek_api_key: str = ""
    deepseek_base_url: str = "https://api.deepseek.com"
    deepseek_text_model: str = "deepseek-v4-flash"
    openai_api_key: str = ""
    openai_base_url: str = "https://api.openai.com/v1"
    request_timeout_seconds: float = 120.0
    host: str = "127.0.0.1"
    port: int = 8787

    @classmethod
    def from_env(cls) -> "AppConfig":
        return cls(
            dashscope_api_key=os.getenv("DASHSCOPE_API_KEY", ""),
            dashscope_base_url=os.getenv("DASHSCOPE_BASE_URL", cls.dashscope_base_url).rstrip("/"),
            dashscope_vision_model=os.getenv("DASHSCOPE_VISION_MODEL", cls.dashscope_vision_model),
            deepseek_api_key=os.getenv("DEEPSEEK_API_KEY", ""),
            deepseek_base_url=os.getenv("DEEPSEEK_BASE_URL", cls.deepseek_base_url).rstrip("/"),
            deepseek_text_model=os.getenv("DEEPSEEK_TEXT_MODEL", cls.deepseek_text_model),
            openai_api_key=os.getenv("OPENAI_API_KEY", ""),
            openai_base_url=os.getenv("OPENAI_BASE_URL", cls.openai_base_url).rstrip("/"),
            request_timeout_seconds=float(os.getenv("HEATCAL_PROXY_TIMEOUT_SECONDS", "120")),
            host=os.getenv("HEATCAL_PROXY_HOST", cls.host),
            port=int(os.getenv("HEATCAL_PROXY_PORT", str(cls.port))),
        )


@dataclass
class ProviderError(Exception):
    code: str
    message: str
    status: int = 502
    recoverable: bool = True
    fallback_allowed: bool = True
    provider: str = "unknown"


def load_env_file(path: str) -> None:
    if not path or not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as env_file:
        for raw_line in env_file:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value


def build_status_payload(config: AppConfig) -> dict[str, Any]:
    return {
        "ok": True,
        "service": "HeatCalAIProxy",
        "mode": "real-provider-proxy",
        "providers": {
            "dashscope": {
                "configured": bool(config.dashscope_api_key),
                "model": config.dashscope_vision_model,
                "role": "photo_food_recognition",
            },
            "deepseek": {
                "configured": bool(config.deepseek_api_key),
                "model": config.deepseek_text_model,
                "role": "text_and_correction_structuring",
            },
            "openai": {
                "configured": bool(config.openai_api_key),
                "role": "reserved_adapter_only",
            },
        },
    }


def create_error_response(error: ProviderError) -> dict[str, Any]:
    return {
        "ok": False,
        "mode": "error",
        "error": {
            "code": error.code,
            "message": error.message,
            "recoverable": error.recoverable,
            "fallback_allowed": error.fallback_allowed,
            "provider": error.provider,
        },
    }


def map_provider_error(error: Exception, provider: str = "unknown") -> ProviderError:
    if isinstance(error, ProviderError):
        return error
    if isinstance(error, TimeoutError):
        return ProviderError("timeout", "Provider request timed out.", 504, provider=provider)
    if isinstance(error, HTTPError):
        if error.code in {401, 403}:
            return ProviderError("auth_failed", "Provider authentication failed.", 502, provider=provider)
        if error.code == 429:
            return ProviderError("quota_or_rate_limited", "Provider quota or rate limit was reached.", 502, provider=provider)
        if 500 <= error.code < 600:
            return ProviderError("provider_unavailable", "Provider service is unavailable.", 502, provider=provider)
        return ProviderError("provider_error", "Provider returned an error response.", 502, provider=provider)
    if isinstance(error, URLError):
        reason = str(error.reason).lower()
        if "timed out" in reason or "timeout" in reason:
            return ProviderError("timeout", "Provider request timed out.", 504, provider=provider)
        return ProviderError("provider_unavailable", "Provider network request failed.", 502, provider=provider)
    return ProviderError("provider_error", "Provider request failed.", 502, provider=provider)


def validate_meal_payload(payload: dict[str, Any]) -> dict[str, Any]:
    if "meal" in payload and isinstance(payload["meal"], dict):
        payload = payload["meal"]
    required = ["date", "meal_type", "source_description", "confidence", "estimated_range", "items"]
    for key in required:
        if key not in payload:
            raise ProviderError("invalid_response", f"Structured result missing field: {key}", 502)

    meal_type = str(payload["meal_type"])
    if meal_type not in MEAL_TYPES:
        raise ProviderError("invalid_response", "Structured result contains unsupported meal_type.", 502)

    try:
        datetime.fromisoformat(str(payload["date"]).replace("Z", "+00:00"))
    except ValueError as exc:
        raise ProviderError("invalid_response", "Structured result contains invalid date.", 502) from exc

    estimated_range = payload["estimated_range"]
    if not isinstance(estimated_range, dict):
        raise ProviderError("invalid_response", "Structured result contains invalid estimated_range.", 502)
    lower = _number(estimated_range.get("lower"), "estimated_range.lower", minimum=0, maximum=5000)
    upper = _number(estimated_range.get("upper"), "estimated_range.upper", minimum=lower, maximum=5000)

    items = payload["items"]
    if not isinstance(items, list) or not items:
        raise ProviderError("invalid_response", "Structured result must include at least one food item.", 502)
    if len(items) > 20:
        raise ProviderError("invalid_response", "Structured result includes too many food items.", 502)

    normalized_items = []
    for item in items:
        if not isinstance(item, dict):
            raise ProviderError("invalid_response", "Food item must be an object.", 502)
        quantity = item.get("quantity")
        nutrition = item.get("nutrition")
        if not isinstance(quantity, dict) or not isinstance(nutrition, dict):
            raise ProviderError("invalid_response", "Food item missing quantity or nutrition.", 502)
        name = str(item.get("name", "")).strip()
        unit = str(quantity.get("unit", "")).strip()
        if not name or not unit:
            raise ProviderError("invalid_response", "Food item missing name or unit.", 502)
        normalized_items.append(
            {
                "name": name,
                "quantity": {
                    "amount": _number(quantity.get("amount"), "quantity.amount", minimum=0, maximum=1000),
                    "unit": unit,
                    "grams": _number(quantity.get("grams"), "quantity.grams", minimum=0.1, maximum=5000),
                    "size": _optional_string(quantity.get("size")),
                },
                "nutrition": {
                    "calories": _number(nutrition.get("calories"), "nutrition.calories", minimum=0, maximum=5000),
                    "protein": _number(nutrition.get("protein"), "nutrition.protein", minimum=0, maximum=500),
                    "carbs": _number(nutrition.get("carbs"), "nutrition.carbs", minimum=0, maximum=1000),
                    "fat": _number(nutrition.get("fat"), "nutrition.fat", minimum=0, maximum=500),
                },
                "confidence": _confidence(item.get("confidence", payload["confidence"])),
                "note": _optional_string(item.get("note")),
            }
        )

    return {
        "date": str(payload["date"]),
        "meal_type": meal_type,
        "source_description": str(payload["source_description"]),
        "confidence": _confidence(payload["confidence"]),
        "estimated_range": {"lower": lower, "upper": upper},
        "items": normalized_items,
    }


def parse_provider_meal(content: str) -> dict[str, Any]:
    text = content.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        text = "\n".join(lines).strip()
    if not text.startswith("{"):
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            text = text[start : end + 1]
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ProviderError("invalid_response", "Provider returned non-JSON structured result.", 502) from exc
    if not isinstance(payload, dict):
        raise ProviderError("invalid_response", "Provider returned invalid structured result.", 502)
    return validate_meal_payload(payload)


def analyze_photo(payload: dict[str, Any], config: AppConfig) -> dict[str, Any]:
    image_base64 = str(payload.get("image_base64", "")).strip()
    if not image_base64:
        raise ProviderError("bad_request", "image_base64 is required.", 400, provider="dashscope")
    mime_type = str(payload.get("image_mime_type", "image/jpeg")).strip() or "image/jpeg"
    description = str(payload.get("description", "")).strip()
    prompt = _meal_prompt(
        "请根据照片识别食物、自然份量、估算营养，并只输出 JSON。",
        description,
    )
    messages = [
        {"role": "system", "content": _system_prompt()},
        {
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:{mime_type};base64,{image_base64}"}},
            ],
        },
    ]
    try:
        meal = _analyze_photo_once(messages, config)
    except ProviderError as error:
        if error.code != "invalid_response":
            raise
        retry_messages = [
            messages[0],
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": (
                            f"{prompt}\n上一轮输出不是合法 JSON 或未完整结束。请重新分析同一张图片，"
                            "只输出一个合法 JSON 对象，不要 Markdown，不要解释，不要省略逗号或引号。"
                        ),
                    },
                    {"type": "image_url", "image_url": {"url": f"data:{mime_type};base64,{image_base64}"}},
                ],
            },
        ]
        meal = _analyze_photo_once(retry_messages, config)
    return _success_response(meal, "dashscope", config.dashscope_vision_model)


def _analyze_photo_once(messages: list[dict[str, Any]], config: AppConfig) -> dict[str, Any]:
    return parse_provider_meal(_call_dashscope_photo(messages, config))


def _call_dashscope_photo(messages: list[dict[str, Any]], config: AppConfig) -> str:
    return call_chat_completion(
        provider="dashscope",
        base_url=config.dashscope_base_url,
        api_key=config.dashscope_api_key,
        model=config.dashscope_vision_model,
        messages=messages,
        timeout=config.request_timeout_seconds,
    )


def analyze_text(payload: dict[str, Any], config: AppConfig) -> dict[str, Any]:
    text = str(payload.get("text", "")).strip()
    if not text:
        raise ProviderError("bad_request", "text is required.", 400, provider="deepseek")
    prompt = _meal_prompt("请从用户文字中提取饮食记录，并只输出 JSON。", text)
    content = call_deepseek_json(prompt, config)
    return _success_response(parse_provider_meal(content), "deepseek", config.deepseek_text_model)


def parse_correction(payload: dict[str, Any], config: AppConfig) -> dict[str, Any]:
    text = str(payload.get("text", "")).strip()
    items = payload.get("items", [])
    if not text:
        raise ProviderError("bad_request", "text is required.", 400, provider="deepseek")
    if not isinstance(items, list) or not items:
        raise ProviderError("bad_request", "items are required.", 400, provider="deepseek")
    prompt = (
        "你是热量咔的实际摄入量语义解析器。只输出 JSON，不要解释。\n"
        "输出结构：{\"corrections\":[{\"food_name\":\"米饭\",\"match\":\"exact|ambiguous|not_found\","
        "\"amount\":1.0,\"ratio\":0.5,\"unit\":\"碗\",\"note\":\"...\"}],\"needs_clarification\":false}。\n"
        "规则：未提及的食物不要输出；同名或无法定位时 needs_clarification=true；不要编造不存在的食物。\n"
        f"当前食物项：{json.dumps(items, ensure_ascii=False)}\n"
        f"用户修正：{text}"
    )
    raw = call_deepseek_json(prompt, config)
    try:
        parsed = json.loads(_strip_json_fence(raw))
    except json.JSONDecodeError as exc:
        raise ProviderError("invalid_response", "Provider returned invalid correction JSON.", 502, provider="deepseek") from exc
    corrections = parsed.get("corrections")
    if not isinstance(corrections, list):
        raise ProviderError("invalid_response", "Correction result missing corrections.", 502, provider="deepseek")
    return {"ok": True, "mode": "real", "source": "deepseek", "correction": parsed}


def call_deepseek_json(prompt: str, config: AppConfig) -> str:
    return call_chat_completion(
        provider="deepseek",
        base_url=config.deepseek_base_url,
        api_key=config.deepseek_api_key,
        model=config.deepseek_text_model,
        messages=[
            {"role": "system", "content": _system_prompt()},
            {"role": "user", "content": prompt},
        ],
        timeout=config.request_timeout_seconds,
        extra_body={"thinking": {"type": "disabled"}},
    )


def call_chat_completion(
    provider: str,
    base_url: str,
    api_key: str,
    model: str,
    messages: list[dict[str, Any]],
    timeout: float,
    extra_body: dict[str, Any] | None = None,
) -> str:
    if not api_key:
        raise ProviderError("missing_key", f"{provider} API key is not configured.", 503, provider=provider)
    body: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "response_format": {"type": "json_object"},
        "max_tokens": 3000,
        "temperature": 0.2,
        "stream": False,
    }
    if extra_body:
        body.update(extra_body)
    request = Request(
        f"{base_url.rstrip('/')}/chat/completions",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=timeout, context=ssl.create_default_context()) as response:
            response_body = response.read().decode("utf-8")
    except Exception as exc:
        raise map_provider_error(exc, provider) from exc
    try:
        decoded = json.loads(response_body)
        choice = decoded["choices"][0]
        finish_reason = choice.get("finish_reason")
        if finish_reason not in {None, "stop"}:
            raise ProviderError("invalid_response", "Provider did not finish with a complete response.", 502, provider=provider)
        content = choice["message"]["content"]
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
        raise ProviderError("invalid_response", "Provider response shape is invalid.", 502, provider=provider) from exc
    if not isinstance(content, str) or not content.strip():
        raise ProviderError("invalid_response", "Provider returned empty content.", 502, provider=provider)
    return content


class ProxyHandler(BaseHTTPRequestHandler):
    config: AppConfig = AppConfig()

    def do_GET(self) -> None:
        if self.path in {"/health", "/v1/status"}:
            self._send_json(build_status_payload(self.config))
            return
        self._send_json(create_error_response(ProviderError("not_found", "Endpoint not found.", 404)), 404)

    def do_POST(self) -> None:
        try:
            payload = self._read_json()
            if self.path == "/v1/analyze/photo":
                self._send_json(analyze_photo(payload, self.config))
            elif self.path == "/v1/analyze/text":
                self._send_json(analyze_text(payload, self.config))
            elif self.path == "/v1/corrections/parse":
                self._send_json(parse_correction(payload, self.config))
            else:
                raise ProviderError("not_found", "Endpoint not found.", 404)
        except Exception as exc:
            error = map_provider_error(exc)
            self._send_json(create_error_response(error), error.status)

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write("%s - %s\n" % (self.log_date_time_string(), format % args))

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            raise ProviderError("bad_request", "JSON body is required.", 400)
        body = self.rfile.read(length).decode("utf-8")
        try:
            payload = json.loads(body)
        except json.JSONDecodeError as exc:
            raise ProviderError("bad_request", "Request body must be valid JSON.", 400) from exc
        if not isinstance(payload, dict):
            raise ProviderError("bad_request", "Request body must be a JSON object.", 400)
        return payload

    def _send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run_server(config: AppConfig) -> None:
    ProxyHandler.config = config
    server = ThreadingHTTPServer((config.host, config.port), ProxyHandler)
    print(f"HeatCalAIProxy listening on http://{config.host}:{config.port}", flush=True)
    server.serve_forever()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="HeatCal minimal AI provider proxy")
    parser.add_argument("--env-file", default="", help="Optional local env file path. Values are never printed.")
    parser.add_argument("--check-config", action="store_true", help="Print non-secret provider configuration status and exit.")
    args = parser.parse_args(argv)
    load_env_file(args.env_file)
    config = AppConfig.from_env()
    if args.check_config:
        print(json.dumps(build_status_payload(config), ensure_ascii=False, indent=2))
        return 0
    run_server(config)
    return 0


def _success_response(meal: dict[str, Any], source: str, model: str) -> dict[str, Any]:
    if meal["confidence"] == "较低":
        warnings = ["低可信度结果，请在保存前复核食物项和份量。"]
    else:
        warnings = []
    return {
        "ok": True,
        "mode": "real",
        "source": source,
        "model": model,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "meal": meal,
        "warnings": warnings,
    }


def _system_prompt() -> str:
    return (
        "你是热量咔 iOS MVP 的饮食结构化分析服务。"
        "营养数据是健康参考估算，不是医疗建议。"
        "必须输出可解析 JSON，不能输出 Markdown、解释或 API 密钥。"
    )


def _meal_prompt(task: str, user_input: str) -> str:
    return (
        f"{task}\n"
        "JSON schema：{\"date\":\"ISO-8601 时间\",\"meal_type\":\"breakfast|lunch|dinner|snack\","
        "\"source_description\":\"用户输入摘要\",\"confidence\":\"较高|一般|较低\","
        "\"estimated_range\":{\"lower\":数字,\"upper\":数字},"
        "\"items\":[{\"name\":\"食物名\",\"quantity\":{\"amount\":数字,\"unit\":\"自然单位\","
        "\"grams\":数字,\"size\":\"可选大小\"},\"nutrition\":{\"calories\":数字,\"protein\":数字,"
        "\"carbs\":数字,\"fat\":数字},\"confidence\":\"较高|一般|较低\",\"note\":\"误差来源或依据\"}]}。\n"
        "规则：只输出 JSON；items 至少 1 项；估算不确定时降低 confidence 并扩大 estimated_range；"
        "自然单位优先，grams 用于计算。\n"
        f"用户输入：{user_input}"
    )


def _strip_json_fence(content: str) -> str:
    text = content.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        return "\n".join(lines).strip()
    return text


def _number(value: Any, field: str, minimum: float, maximum: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ProviderError("invalid_response", f"Invalid numeric field: {field}", 502) from exc
    if number < minimum or number > maximum:
        raise ProviderError("invalid_response", f"Numeric field out of range: {field}", 502)
    return number


def _confidence(value: Any) -> str:
    confidence = str(value)
    if confidence not in CONFIDENCE_LEVELS:
        return "一般"
    return confidence


def _optional_string(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


if __name__ == "__main__":
    raise SystemExit(main())
