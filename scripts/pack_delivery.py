"""把交付目录打成单层 zip，并做完整性校验。

为什么单层：解压后直接看到「第3周_张宇翔/」里的文件，不多套一层 root，
收件人双击就能看到内容，不用再点一次。

为什么带校验：被打包的内容里有真实业务数字，传输出错（截断、覆盖旧文件）
不会报错，只会悄悄给出上一版。所以打完必须把 zip 里每个文件的 MD5
和源文件逐个比对，不一致就判定失败。

安全：强制排除 .env / *.key / *.pem —— 密钥绝不能跟着交付包走。
即使源目录里误放了，这里也会拦掉并在输出里告警。

用法：
    python scripts/pack_delivery.py 第3周_张宇翔
"""
from __future__ import annotations

import hashlib
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 这些文件名一律不打包（含密钥类）
EXCLUDE_NAMES = {".env", ".env.local", "__pycache__", ".DS_Store", "Thumbs.db"}
EXCLUDE_SUFFIX = {".pyc", ".pyo", ".key", ".pem"}


def md5(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect(src: Path) -> tuple[list[Path], list[Path]]:
    """返回 (要打包的文件, 因安全规则被排除的文件)。"""
    keep, blocked = [], []
    for p in sorted(src.rglob("*")):
        if not p.is_file():
            continue
        if p.name in EXCLUDE_NAMES or p.suffix.lower() in EXCLUDE_SUFFIX:
            # .env.example 是模板，允许；其它 .env 一律拦
            if p.name == ".env.example":
                keep.append(p)
            else:
                blocked.append(p)
            continue
        keep.append(p)
    return keep, blocked


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: python scripts/pack_delivery.py <交付目录名>")
        return 2

    src = ROOT / sys.argv[1]
    if not src.is_dir():
        print(f"[ERROR] 目录不存在: {src}")
        return 1

    files, blocked = collect(src)
    if blocked:
        print("[WARN] 以下文件因安全规则被排除（确认里面没有密钥）:")
        for p in blocked:
            print(f"        {p.relative_to(src)}")

    out = ROOT / f"{src.name}.zip"
    if out.exists():
        out.unlink()

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in files:
            # 统一用 / 分隔，Windows 上 zipfile 默认写 \ 会让部分解压工具路径错乱
            arc = p.relative_to(ROOT).as_posix()
            z.write(p, arc)

    # ---------------- 校验 ----------------
    src_map = {p.relative_to(ROOT).as_posix(): p for p in files}
    ok_cnt = bad_cnt = 0
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
        for name in names:
            if name not in src_map:
                print(f"[FAIL] zip 里有源目录不存在的条目: {name}")
                bad_cnt += 1
                continue
            data = z.read(name)
            if hashlib.md5(data).hexdigest() == md5(src_map[name]):
                ok_cnt += 1
            else:
                print(f"[FAIL] MD5 不一致: {name}")
                bad_cnt += 1
        missing = set(src_map) - set(names)
        for name in missing:
            print(f"[FAIL] 源文件未进 zip: {name}")
            bad_cnt += 1

    # 顶层必须是单一目录
    tops = {n.split("/")[0] for n in names}
    size_mb = out.stat().st_size / 1024 / 1024

    print(f"\n源文件 {len(files)} 个 → zip 条目 {len(names)} 个")
    print(f"MD5 校验通过 {ok_cnt} 个，失败 {bad_cnt} 个")
    print(f"顶层目录: {sorted(tops)}" + ("" if len(tops) == 1 else "  ← 异常，应为单层"))
    print(f"输出: {out}（{size_mb:.2f} MB）")

    if bad_cnt or len(tops) != 1:
        print("[RESULT] 失败")
        return 1
    print("[RESULT] 成功，可交付")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
