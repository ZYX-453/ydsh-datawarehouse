"""06 — 大模型 API 连通性自检（最小化调用）。

目的不是「能聊两句」，而是验证四件工程事：
    1. 密钥从环境变量读取，代码里没有硬编码
    2. 端点、模型名、鉴权是否可用
    3. 返回结构与耗时（用于后面 NL2SQL 的超时预算）
    4. 结构化输出能力（要求模型返回严格 JSON，验证它是否听话）

无密钥时不报错退出，只给出配置指引——避免 CI 里因为没配密钥就红。
用法：
    python 06_llm_ping.py
"""
from __future__ import annotations

import json
import os
import sys
import time

from common import BASE_DIR, load_env

load_env()

KEY = os.environ.get("LLM_API_KEY", "").strip()
BASE_URL = os.environ.get("LLM_BASE_URL", "https://api.deepseek.com")
MODEL = os.environ.get("LLM_MODEL", "deepseek-chat")


def main() -> int:
    print(f"配置文件: {BASE_DIR / '.env'}（存在: {(BASE_DIR / '.env').exists()}）")
    print(f"端  点  : {BASE_URL}")
    print(f"模  型  : {MODEL}")
    print(f"密  钥  : {'已读取（长度 %d，前 4 位 %s***）' % (len(KEY), KEY[:4]) if KEY else '未配置'}")

    if not KEY:
        print("\n[SKIP] 未配置 LLM_API_KEY。")
        print("       1) cp .env.example .env")
        print("       2) 编辑 .env，填入 LLM_API_KEY=sk-xxxx")
        print("       3) 重新执行本脚本")
        print("       当前 NL2SQL 会运行在「离线兜底模式」，功能可用但不是大模型生成。")
        return 2

    from openai import OpenAI

    client = OpenAI(api_key=KEY, base_url=BASE_URL)

    # --- 调用 1：连通性 ---
    t0 = time.time()
    try:
        resp = client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "user", "content": "用一句话回答：Hive 是什么？"}],
            temperature=0,
            max_tokens=100,
        )
    except Exception as e:
        print(f"\n[FAIL] 调用失败: {type(e).__name__}: {e}")
        return 1
    cost = time.time() - t0
    text = (resp.choices[0].message.content or "").strip()
    print(f"\n[OK] 连通性调用成功，耗时 {cost:.2f}s")
    print(f"回复: {text[:120]}")
    if getattr(resp, "usage", None):
        u = resp.usage
        print(f"Token: prompt={u.prompt_tokens} completion={u.completion_tokens} total={u.total_tokens}")

    # --- 调用 2：结构化输出（NL2SQL 依赖模型稳定产出纯 SQL/JSON）---
    t0 = time.time()
    try:
        resp2 = client.chat.completions.create(
            model=MODEL,
            messages=[
                {"role": "system", "content": "你只输出严格 JSON，不要 markdown 围栏，不要解释。"},
                {"role": "user", "content": '返回形如 {"status":"ok","tables":3} 的 JSON，tables 填 3。'},
            ],
            temperature=0,
            max_tokens=80,
        )
        raw = (resp2.choices[0].message.content or "").strip()
        raw = raw.replace("```json", "").replace("```", "").strip()
        parsed = json.loads(raw)
        print(f"[OK] 结构化输出可解析，耗时 {time.time()-t0:.2f}s -> {parsed}")
    except Exception as e:
        print(f"[WARN] 结构化输出不稳定（不影响 NL2SQL，但有概率需要重试）: {type(e).__name__}: {e}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
