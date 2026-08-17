import json
import os
import unittest
from urllib.error import HTTPError, URLError

import backend.heatcal_proxy as heatcal_proxy
from backend.heatcal_proxy import (
    AppConfig,
    ProviderError,
    analyze_photo,
    build_status_payload,
    create_error_response,
    map_provider_error,
    parse_provider_meal,
    validate_meal_payload,
)


class HeatCalAIProxyContractTests(unittest.TestCase):
    def test_default_vision_model_uses_current_dashscope_replacement(self):
        self.assertEqual(AppConfig().dashscope_vision_model, "qwen3.6-flash")

    def test_status_payload_exposes_provider_presence_without_secret_values(self):
        config = AppConfig(
            dashscope_api_key="dashscope-secret",
            deepseek_api_key="deepseek-secret",
            openai_api_key="",
        )

        payload = build_status_payload(config)
        serialized = json.dumps(payload, ensure_ascii=False)

        self.assertTrue(payload["providers"]["dashscope"]["configured"])
        self.assertTrue(payload["providers"]["deepseek"]["configured"])
        self.assertFalse(payload["providers"]["openai"]["configured"])
        self.assertNotIn("dashscope-secret", serialized)
        self.assertNotIn("deepseek-secret", serialized)

    def test_validate_meal_payload_accepts_structured_food_items(self):
        meal = {
            "date": "2026-06-19T12:20:00+08:00",
            "meal_type": "lunch",
            "source_description": "真实 AI 文字补记",
            "confidence": "一般",
            "estimated_range": {"lower": 520, "upper": 760},
            "items": [
                {
                    "name": "宫保鸡丁",
                    "quantity": {"amount": 1, "unit": "份", "grams": 260, "size": "中份"},
                    "nutrition": {"calories": 420, "protein": 28, "carbs": 24, "fat": 24},
                    "confidence": "一般",
                    "note": "用油量未知",
                }
            ],
        }

        validated = validate_meal_payload(meal)

        self.assertEqual(validated["meal_type"], "lunch")
        self.assertEqual(validated["items"][0]["quantity"]["unit"], "份")
        self.assertEqual(validated["items"][0]["nutrition"]["calories"], 420)

    def test_validate_meal_payload_rejects_missing_food_items(self):
        meal = {
            "date": "2026-06-19T12:20:00+08:00",
            "meal_type": "lunch",
            "source_description": "结构化异常",
            "confidence": "一般",
            "estimated_range": {"lower": 0, "upper": 0},
            "items": [],
        }

        with self.assertRaises(ProviderError) as error:
            validate_meal_payload(meal)

        self.assertEqual(error.exception.code, "invalid_response")

    def test_parse_provider_meal_strips_markdown_fence_and_validates_json(self):
        raw = """```json
        {
          "date": "2026-06-19T08:00:00+08:00",
          "meal_type": "breakfast",
          "source_description": "鸡蛋两个",
          "confidence": "较高",
          "estimated_range": {"lower": 120, "upper": 180},
          "items": [
            {
              "name": "鸡蛋",
              "quantity": {"amount": 2, "unit": "个", "grams": 100},
              "nutrition": {"calories": 140, "protein": 12, "carbs": 1, "fat": 10},
              "confidence": "较高"
            }
          ]
        }
        ```"""

        meal = parse_provider_meal(raw)

        self.assertEqual(meal["items"][0]["name"], "鸡蛋")

    def test_error_mapping_never_exposes_secret_bearing_provider_body(self):
        error = HTTPError(
            url="https://api.example.test",
            code=401,
            msg="Unauthorized",
            hdrs=None,
            fp=None,
        )

        mapped = map_provider_error(error)
        error.close()
        response = create_error_response(mapped)
        serialized = json.dumps(response, ensure_ascii=False)

        self.assertEqual(response["error"]["code"], "auth_failed")
        self.assertNotIn("Unauthorized", serialized)
        self.assertNotIn("s" + "k-", serialized)

    def test_timeout_and_network_errors_are_recoverable(self):
        mapped = map_provider_error(URLError("timed out"))

        self.assertEqual(mapped.code, "timeout")
        self.assertTrue(mapped.recoverable)
        self.assertTrue(mapped.fallback_allowed)

    def test_photo_analysis_retries_once_when_provider_returns_invalid_json(self):
        calls: list[str] = []
        valid_meal = json.dumps(
            {
                "date": "2026-06-19T08:00:00+08:00",
                "meal_type": "breakfast",
                "source_description": "真实照片",
                "confidence": "一般",
                "estimated_range": {"lower": 400, "upper": 600},
                "items": [
                    {
                        "name": "吐司",
                        "quantity": {"amount": 1, "unit": "片", "grams": 60},
                        "nutrition": {"calories": 180, "protein": 6, "carbs": 30, "fat": 4},
                        "confidence": "一般",
                    }
                ],
            },
            ensure_ascii=False,
        )

        original = heatcal_proxy.call_chat_completion

        def fake_call_chat_completion(**kwargs):
            user_text = kwargs["messages"][1]["content"][0]["text"]
            calls.append(user_text)
            return "{\"meal_type\":\"breakfast\"" if len(calls) == 1 else valid_meal

        heatcal_proxy.call_chat_completion = fake_call_chat_completion
        try:
            response = analyze_photo(
                {"image_base64": "abc", "image_mime_type": "image/png"},
                AppConfig(dashscope_api_key="dashscope-secret"),
            )
        finally:
            heatcal_proxy.call_chat_completion = original

        self.assertTrue(response["ok"])
        self.assertEqual(response["meal"]["items"][0]["name"], "吐司")
        self.assertEqual(len(calls), 2)
        self.assertIn("上一轮", calls[1])

    def test_photo_analysis_retries_once_when_provider_response_is_incomplete(self):
        calls = 0
        valid_meal = json.dumps(
            {
                "date": "2026-06-19T08:00:00+08:00",
                "meal_type": "breakfast",
                "source_description": "真实照片",
                "confidence": "一般",
                "estimated_range": {"lower": 400, "upper": 600},
                "items": [
                    {
                        "name": "蛋挞",
                        "quantity": {"amount": 1, "unit": "个", "grams": 70},
                        "nutrition": {"calories": 220, "protein": 5, "carbs": 24, "fat": 12},
                        "confidence": "一般",
                    }
                ],
            },
            ensure_ascii=False,
        )

        original = heatcal_proxy.call_chat_completion

        def fake_call_chat_completion(**kwargs):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise ProviderError("invalid_response", "Provider did not finish.", provider="dashscope")
            return valid_meal

        heatcal_proxy.call_chat_completion = fake_call_chat_completion
        try:
            response = analyze_photo(
                {"image_base64": "abc", "image_mime_type": "image/png"},
                AppConfig(dashscope_api_key="dashscope-secret"),
            )
        finally:
            heatcal_proxy.call_chat_completion = original

        self.assertTrue(response["ok"])
        self.assertEqual(response["meal"]["items"][0]["name"], "蛋挞")
        self.assertEqual(calls, 2)


if __name__ == "__main__":
    unittest.main()
