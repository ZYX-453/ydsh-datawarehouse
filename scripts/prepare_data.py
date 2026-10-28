#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
云购生活数据仓库项目 —— 原始数据预处理脚本

文件    : scripts/prepare_data.py
用途    : 把 模拟数据/ 下的原始 CSV 处理成可直接被 Hive 导入的干净文件，输出到 data/

为什么需要这一步（三个必须预处理的理由）：

  1. 【CRLF → LF】原始文件是 Windows CRLF 换行。Hive 的 LINES TERMINATED BY
     只支持单字符 '\\n'（HIVE-5999，至今未修复），无法用 '\\r\\n' 解决。
     若不转换就直接导入，每行最后一个字段会带上 '\\r'，例如 channel 变成 'APP\\r'，
     导致所有按枚举分组的统计全部错位 —— 而 COUNT(*) 完全正常，极难发现。

  2. 【去除 UTF-8 BOM】原始文件带 BOM（EF BB BF），位于表头行首。
     虽然 skip.header.line.count=1 能顺带跳过，但显式去掉更保险，
     避免某些 Hive 版本或后续用 Python/pandas 读取时首字段变成 '\\ufeffuser_id'。

  3. 【行内一致性校验】顺便校验每个文件的数据行数、每行字段数是否与表头一致，
     把数据问题在上游暴露，而不是等到 Hive 里出现字段错位再回头排查。

用法：
    python scripts/prepare_data.py                    # 默认 模拟数据/ → data/
    python scripts/prepare_data.py --src 目录 --dst 目录
    python scripts/prepare_data.py --check-only       # 只校验不写文件
"""

import argparse
import os
import sys
from collections import Counter

# 期望的数据行数（不含表头），来自《项目总说明与模拟数据字典》
EXPECTED_ROWS = {
    'ods_user.csv':          1000,
    'ods_product.csv':        600,
    'ods_store.csv':           60,
    'ods_order.csv':        15600,
    'ods_order_item.csv':   37549,
    'ods_user_behavior.csv': 60000,
}

BOM = b'\xef\xbb\xbf'


def process_file(src_path, dst_path, expected_rows, check_only=False):
    """处理单个 CSV：去 BOM、CRLF→LF、校验一致性，写入目标文件。"""
    name = os.path.basename(src_path)

    with open(src_path, 'rb') as fh:
        raw = fh.read()

    had_bom = raw.startswith(BOM)
    if had_bom:
        raw = raw[len(BOM):]

    # 统一换行：先把 CRLF 变 LF，再把可能残留的孤立 CR 变 LF
    had_crlf = b'\r\n' in raw
    data = raw.replace(b'\r\n', b'\n').replace(b'\r', b'\n')

    if not data.endswith(b'\n'):
        data += b'\n'

    lines = data.split(b'\n')
    while lines and lines[-1] == b'':
        lines.pop()

    if not lines:
        return {'file': name, 'error': '文件为空', 'ok': False}

    header = lines[0]
    body = lines[1:]
    header_cols = header.count(b',') + 1

    # 逐行校验字段数，记录异常行（给出前几个行号便于排查）
    bad_rows = []
    for idx, line in enumerate(body, start=2):   # 行号从 2 开始（1 是表头）
        if line.count(b',') + 1 != header_cols:
            bad_rows.append(idx)
            if len(bad_rows) >= 5:
                break

    # 行尾逗号统计：这不是错误，而是「最后一个字段为空」的合法表示。
    # 例：ods_user 最后一列是 email，193 条缺失就表现为 193 行以逗号结尾；
    #     ods_product 最后一列是 launch_date，11 条缺失对应 11 行以逗号结尾。
    # 这里只做统计输出，供与《数据质量预评估表》的缺失值数量交叉印证，不计为异常。
    trailing_comma = sum(1 for l in body if l.endswith(b','))

    rows = len(body)
    ok = True
    notes = []
    if expected_rows is not None and rows != expected_rows:
        ok = False
        notes.append(f'行数不符（期望 {expected_rows}，实际 {rows}）')
    if bad_rows:
        ok = False
        notes.append(f'字段数异常行：{bad_rows}')
    if trailing_comma:
        notes.append(f'末字段为空 {trailing_comma} 行（合法，对应缺失值）')

    if not check_only:
        with open(dst_path, 'wb') as fh:
            fh.write(data)

    return {
        'file': name,
        'rows': rows,
        'cols': header_cols,
        'bom': had_bom,
        'crlf': had_crlf,
        'bad_rows': len(bad_rows),
        'trailing_comma': trailing_comma,
        'ok': ok,
        'notes': notes,
        'written': None if check_only else dst_path,
    }


def main():
    ap = argparse.ArgumentParser(description='预处理 CSV：去 BOM、CRLF→LF、校验一致性')
    ap.add_argument('--src', default='模拟数据', help='原始数据目录（默认 模拟数据）')
    ap.add_argument('--dst', default='data',     help='输出目录（默认 data）')
    ap.add_argument('--check-only', action='store_true', help='只校验，不写文件')
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src_dir = args.src if os.path.isabs(args.src) else os.path.join(root, args.src)
    dst_dir = args.dst if os.path.isabs(args.dst) else os.path.join(root, args.dst)

    if not os.path.isdir(src_dir):
        print(f'[错误] 源目录不存在：{src_dir}')
        return 1
    if not args.check_only:
        os.makedirs(dst_dir, exist_ok=True)

    files = sorted(f for f in os.listdir(src_dir) if f.lower().endswith('.csv'))
    if not files:
        print(f'[错误] {src_dir} 下没有 CSV 文件')
        return 1

    print('=' * 78)
    print(f'源目录：{src_dir}')
    print(f'输出  ：{"（仅校验，不写出）" if args.check_only else dst_dir}')
    print('=' * 78)
    print(f'{"文件":24s} {"行数":>7s} {"列":>3s} {"BOM":>5s} {"CRLF":>6s}  结果')
    print('-' * 78)

    results = []
    total_rows = 0
    all_ok = True

    for f in files:
        src = os.path.join(src_dir, f)
        dst = os.path.join(dst_dir, f)
        r = process_file(src, dst, EXPECTED_ROWS.get(f), args.check_only)
        results.append(r)

        if 'error' in r:
            print(f'{f:24s} {"-":>7s} {"-":>3s} {"-":>5s} {"-":>6s}  错误：{r["error"]}')
            all_ok = False
            continue

        total_rows += r['rows']
        status = 'OK' if r['ok'] else '异常'
        print(f'{f:24s} {r["rows"]:7d} {r["cols"]:3d} '
              f'{"是" if r["bom"] else "否":>5s} {"是" if r["crlf"] else "否":>6s}  {status}')
        for n in r['notes']:
            print(f'{"":24s} {"":7s} {"":3s} {"":5s} {"":6s}  └─ {n}')
        if not r['ok']:
            all_ok = False

    print('-' * 78)
    exp_total = sum(EXPECTED_ROWS.get(f, 0) for f in files)
    print(f'合计数据行：{total_rows}  （期望 {exp_total}）'
          f'{"  ✅ 一致" if total_rows == exp_total else "  ❌ 不一致"}')

    # 统计换行符与 BOM 情况，便于确认转换效果
    crlf_cnt = sum(1 for r in results if r.get('crlf'))
    bom_cnt = sum(1 for r in results if r.get('bom'))
    print(f'原始换行：{crlf_cnt}/{len(files)} 个文件为 CRLF'
          f'{"（已全部转为 LF）" if (crlf_cnt and not args.check_only) else ""}')
    print(f'原始 BOM ：{bom_cnt}/{len(files)} 个文件带 BOM'
          f'{"（已全部去除）" if (bom_cnt and not args.check_only) else ""}')

    # 写出后再复核一次：确认输出文件确实是纯 LF、无 BOM
    if not args.check_only and all_ok:
        print('-' * 78)
        print('输出文件复核：')
        recheck_ok = True
        for r in results:
            with open(r['written'], 'rb') as fh:
                b = fh.read()
            out_bom = b.startswith(BOM)
            out_crlf = b'\r' in b
            flag = 'OK' if (not out_bom and not out_crlf) else '❌ 仍残留'
            if out_bom or out_crlf:
                recheck_ok = False
            print(f'  {r["file"]:24s} BOM={"有" if out_bom else "无"}  CR={"有" if out_crlf else "无"}  {flag}')
        all_ok = all_ok and recheck_ok

    print('=' * 78)
    if all_ok:
        print('✅ 预处理完成，data/ 下文件可直接被 Hive 导入')
        print('   建表使用 LINES TERMINATED BY \'\\n\'（默认值），无需其他处理')
        return 0
    print('❌ 存在异常，请根据上面的提示排查后再导入')
    return 1


if __name__ == '__main__':
    sys.exit(main())
