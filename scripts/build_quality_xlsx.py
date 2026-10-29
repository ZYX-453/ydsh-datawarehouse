# -*- coding: utf-8 -*-
"""
生成《数据质量预评估表.xlsx》—— 第 1 周交付物（提交清单第 5 项）

数据来源：docs/02_数据质量预评估表.md（数值已于 2026-10-28 在 Hive 中实测复核）
场景原型：统计型（五维度扫描 + 明细/汇总）
"""
import os
try:
    import openpyxl
except ImportError:
    import subprocess, sys
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "openpyxl>=3.1.0"])
    import openpyxl

from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
from openpyxl.formatting.rule import CellIsRule

# ---------------------------------------------------------------- 颜色 ----
def xl_color(css_hex: str) -> str:
    v = css_hex.removeprefix("#").upper()
    if len(v) != 6:
        raise ValueError(f"Expected #RRGGBB, got: {css_hex}")
    return "FF" + v

XL_HEAD   = xl_color("#4472C4")   # 表头底
XL_HEAD_F = xl_color("#FFFFFF")   # 表头字
XL_TITLE  = xl_color("#2F5597")   # 标题底
XL_SUB    = xl_color("#D9E2F3")   # 小节标题底
XL_BORDER = xl_color("#BFBFBF")
XL_RED_BG = xl_color("#FFC7CE"); XL_RED_FG = xl_color("#9C0006")
XL_GRN_BG = xl_color("#C6EFCE"); XL_GRN_FG = xl_color("#006100")
XL_YEL_BG = xl_color("#FFEB9C"); XL_YEL_FG = xl_color("#9C6500")

thin = Side(style="thin", color=XL_BORDER)
BORDER = Border(left=thin, right=thin, top=thin, bottom=thin)

FONT_NAME = "微软雅黑"
OUT_PATH = r"F:\企业项目实战\docs\数据质量预评估表.xlsx"

wb = Workbook()
wb.properties.title = "数据质量预评估表"


# ------------------------------------------------------------ 通用工具 ----
def title_row(ws, text, ncol):
    """第 1 行合并标题"""
    ws.merge_cells(start_row=1, start_column=1, end_row=1, end_column=ncol)
    c = ws.cell(row=1, column=1, value=text)
    c.font = Font(name=FONT_NAME, size=13, bold=True, color=XL_HEAD_F)
    c.fill = PatternFill("solid", fgColor=XL_TITLE)
    c.alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[1].height = 28


def sub_title(ws, row, text, ncol):
    """小节标题（区块分隔用）"""
    ws.merge_cells(start_row=row, start_column=1, end_row=row, end_column=ncol)
    c = ws.cell(row=row, column=1, value=text)
    c.font = Font(name=FONT_NAME, size=10.5, bold=True, color=XL_TITLE)
    c.fill = PatternFill("solid", fgColor=XL_SUB)
    c.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[row].height = 22


def header_row(ws, row, headers):
    for j, h in enumerate(headers, start=1):
        c = ws.cell(row=row, column=j, value=h)
        c.font = Font(name=FONT_NAME, size=10, bold=True, color=XL_HEAD_F)
        c.fill = PatternFill("solid", fgColor=XL_HEAD)
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        c.border = BORDER
    ws.row_dimensions[row].height = 26


def put_row(ws, row, values, fmts=None, aligns=None, bold=False, fill=None):
    for j, v in enumerate(values, start=1):
        c = ws.cell(row=row, column=j, value=v)
        c.font = Font(name=FONT_NAME, size=10, bold=bold)
        c.border = BORDER
        al = (aligns[j-1] if aligns and j-1 < len(aligns) else "center")
        c.alignment = Alignment(horizontal=al, vertical="center",
                                wrap_text=(al == "left"))
        if fmts and j-1 < len(fmts) and fmts[j-1]:
            c.number_format = fmts[j-1]
        if fill:
            c.fill = PatternFill("solid", fgColor=fill)


def set_widths(ws, widths):
    for i, w in enumerate(widths, start=1):
        ws.column_dimensions[get_column_letter(i)].width = w


PCT = "0.00%"
NUM = "#,##0"

# ============================================================ 1. 总览 ====
ws = wb.active
ws.title = "总览"
title_row(ws, "数据质量预评估表 · 总览（ODS 贴源层 6 张表）", 5)
header_row(ws, 2, ["序号", "表名", "行数", "主键", "主要问题"])

overview = [
    ("ods_user", 1000, "user_id", "4 字段缺失、年龄异常、性别与会员等级枚举混乱、日期与手机号格式不一致"),
    ("ods_product", 600, "product_id", "上架日期缺失、价格负值与异常高价、类目含尾空格"),
    ("ods_store", 60, "store_id", "无明显脏数据"),
    ("ods_order", 15600, "order_id", "主键重复 600 行、金额负值与超大值、状态/支付方式/渠道枚举混乱"),
    ("ods_order_item", 37549, "item_id", "数量 0/负数/超大、单价 0 与负值"),
    ("ods_user_behavior", 60000, "behavior_id", "行为类型中英文混用、时间格式混用"),
]
r = 3
for i, (tname, rows, pk, issue) in enumerate(overview, start=1):
    put_row(ws, r, [i, tname, rows, pk, issue],
            fmts=[None, None, NUM, None, None],
            aligns=["center", "left", "right", "center", "left"])
    ws.row_dimensions[r].height = 30
    r += 1

# 合计行（数据区 3~8，合计在第 9 行）
put_row(ws, r, ["合计", "6 张表", "=SUM(C3:C8)", "—", "—"],
        fmts=[None, None, NUM, None, None],
        aligns=["center", "center", "right", "center", "center"],
        bold=True, fill=XL_SUB)

set_widths(ws, [6, 22, 12, 14, 62])
ws.freeze_panes = "A3"

# ======================================================== 2. 完整性 ====
ws = wb.create_sheet("完整性")
title_row(ws, "完整性（Completeness）—— 字段空值率", 6)
header_row(ws, 2, ["表名", "字段", "空值数", "表总行数", "空值率", "处置策略"])

comp = [
    ("ods_user", "gender", 84, 1000, "填充为「未知」"),
    ("ods_user", "age", 51, 1000, "用业务有效区间（1~120）内中位数填充"),
    ("ods_user", "member_level", 14, 1000, "填充为「普通会员」"),
    ("ods_user", "email", 193, 1000, "保留空值，新增标记字段便于识别"),
    ("ods_product", "launch_date", 11, 600, "按类目同期上架日期补全，无法补全则置分区日期"),
    ("ods_order", "全字段", 0, 15600, "无需处理"),
    ("ods_order_item", "全字段", 0, 37549, "无需处理"),
    ("ods_user_behavior", "全字段", 0, 60000, "无需处理"),
]
r = 3
for tname, fld, nulls, total, strategy in comp:
    # 空值率 = 空值数 / 表总行数（分母空/0 保护）
    rate = f'=IF(OR(D{r}="",D{r}=0),"",C{r}/D{r})'
    put_row(ws, r, [tname, fld, nulls, total, rate, strategy],
            fmts=[None, None, NUM, NUM, PCT, None],
            aligns=["left", "center", "right", "right", "right", "left"])
    ws.row_dimensions[r].height = 26
    r += 1

set_widths(ws, [18, 14, 10, 12, 10, 56])
ws.freeze_panes = "A3"
ws.auto_filter.ref = f"A2:F{r-1}"

# 空值率 >5% 标黄提醒
ws.conditional_formatting.add(
    f"E3:E{r-1}",
    CellIsRule(operator="greaterThan", formula=["0.05"],
               fill=PatternFill("solid", bgColor=XL_YEL_BG),
               font=Font(color=XL_YEL_FG))
)

# ======================================================== 3. 唯一性 ====
ws = wb.create_sheet("唯一性")
title_row(ws, "唯一性（Uniqueness）—— 主键重复检测", 5)
header_row(ws, 2, ["表名", "总行数", "唯一主键数", "重复行数", "重复率"])

uniq = [
    ("ods_order", 15600, 15000),
    ("ods_user", 1000, 1000),
    ("ods_product", 600, 600),
    ("ods_store", 60, 60),
    ("ods_order_item", 37549, 37549),
    ("ods_user_behavior", 60000, 60000),
]
r = 3
for tname, total, distinct_pk in uniq:
    dup = f"=B{r}-C{r}"                                   # 重复行数 = 总行数 - 唯一主键数
    rate = f'=IF(OR(B{r}="",B{r}=0),"",D{r}/B{r})'        # 重复率（分母保护）
    put_row(ws, r, [tname, total, distinct_pk, dup, rate],
            fmts=[None, NUM, NUM, NUM, PCT],
            aligns=["left", "right", "right", "right", "right"])
    r += 1

# 合计行（数据区 3~8，合计第 9 行）
put_row(ws, 9, ["合计", "=SUM(B3:B8)", "=SUM(C3:C8)", "=SUM(D3:D8)", '=IF(OR(B9="",B9=0),"",D9/B9)'],
        fmts=[None, NUM, NUM, NUM, PCT],
        aligns=["center", "right", "right", "right", "right"],
        bold=True, fill=XL_SUB)

# 第二区块：重复值细分
sub_title(ws, 11, "ods_order 重复值细分（区分两类重复，处置策略不同）", 4)
header_row(ws, 12, ["类型", "组数", "说明", "处置"])
dup_detail = [
    ("整行完全重复", 388, "所有字段取值完全相同，属采集环节重复写入", "直接去重，保留 1 条"),
    ("主键重复但内容不同", 198, "同一 order_id 下字段有差异，需业务判断", "按 order_time 取最新一条"),
]
r = 13
for item in dup_detail:
    put_row(ws, r, list(item), fmts=[None, NUM, None, None],
            aligns=["left", "right", "left", "left"])
    ws.row_dimensions[r].height = 24
    r += 1
put_row(ws, 15, ["合计", "=SUM(B13:B14)", "重复组数应等于上表 586", "—"],
        fmts=[None, NUM, None, None],
        aligns=["center", "right", "left", "center"], bold=True, fill=XL_SUB)

set_widths(ws, [24, 12, 40, 30, 12])

# 重复行数 >0 标红
ws.conditional_formatting.add(
    "D3:D8",
    CellIsRule(operator="greaterThan", formula=["0"],
               fill=PatternFill("solid", bgColor=XL_RED_BG),
               font=Font(color=XL_RED_FG, bold=True))
)

# ======================================================== 4. 有效性 ====
ws = wb.create_sheet("有效性")
title_row(ws, "有效性（Validity）—— 枚举取值合法性扫描", 5)
header_row(ws, 2, ["字段", "取值", "出现次数", "合法性", "归并到"])

enum_rows = [
    # order_status
    ("ods_order.order_status", "已完成", 5498, "合法", "已完成"),
    ("ods_order.order_status", "已支付", 4102, "合法", "已支付"),
    ("ods_order.order_status", "待支付", 1990, "合法", "待支付"),
    ("ods_order.order_status", "已取消", 1800, "合法", "已取消"),
    ("ods_order.order_status", "退款中", 835, "合法", "退款中"),
    ("ods_order.order_status", "1", 211, "非法", "待支付"),
    ("ods_order.order_status", "2", 193, "非法", "已支付"),
    ("ods_order.order_status", "3", 202, "非法", "已完成"),
    ("ods_order.order_status", "4", 182, "非法", "已取消"),
    ("ods_order.order_status", "已付款", 197, "非法", "已支付"),
    ("ods_order.order_status", "完成", 192, "非法", "已完成"),
    ("ods_order.order_status", "cancelled", 198, "非法", "已取消"),
    # pay_type
    ("ods_order.pay_type", "支付宝", 3944, "合法", "支付宝"),
    ("ods_order.pay_type", "微信支付", 3711, "合法", "微信支付"),
    ("ods_order.pay_type", "货到付款", 3693, "合法", "货到付款"),
    ("ods_order.pay_type", "银行卡", 3601, "合法", "银行卡"),
    ("ods_order.pay_type", "wechat", 227, "非法", "微信支付"),
    ("ods_order.pay_type", "微信", 218, "非法", "微信支付"),
    ("ods_order.pay_type", "alipay", 206, "非法", "支付宝"),
    # channel
    ("ods_order.channel", "门店", 3862, "合法", "门店"),
    ("ods_order.channel", "APP", 3854, "合法", "APP"),
    ("ods_order.channel", "小程序", 3845, "合法", "小程序"),
    ("ods_order.channel", "PC官网", 3729, "合法", "PC官网"),
    ("ods_order.channel", "app", 170, "非法", "APP"),
    ("ods_order.channel", "pc", 140, "非法", "PC官网"),
    # gender
    ("ods_user.gender", "女", 212, "合法", "女"),
    ("ods_user.gender", "男", 182, "合法", "男"),
    ("ods_user.gender", "male", 110, "非法", "男"),
    ("ods_user.gender", "female", 108, "非法", "女"),
    ("ods_user.gender", "F", 109, "非法", "女"),
    ("ods_user.gender", "M", 87, "非法", "男"),
    ("ods_user.gender", "未知", 108, "合法", "未知"),
    ("ods_user.gender", "（空）", 84, "非法", "未知"),
    # member_level
    ("ods_user.member_level", "钻石会员", 232, "合法", "钻石会员"),
    ("ods_user.member_level", "金卡会员", 251, "合法", "金卡会员"),
    ("ods_user.member_level", "银卡会员", 201, "合法", "银卡会员"),
    ("ods_user.member_level", "普通会员", 208, "合法", "普通会员"),
    ("ods_user.member_level", "金卡", 12, "非法", "金卡会员"),
    ("ods_user.member_level", "银卡", 16, "非法", "银卡会员"),
    ("ods_user.member_level", "钻石", 21, "非法", "钻石会员"),
    ("ods_user.member_level", "普通", 11, "非法", "普通会员"),
    ("ods_user.member_level", "gold", 10, "非法", "金卡会员"),
    ("ods_user.member_level", "silver", 13, "非法", "银卡会员"),
    ("ods_user.member_level", "normal", 11, "非法", "普通会员"),
    ("ods_user.member_level", "（空）", 14, "非法", "普通会员"),
    # behavior_type
    ("ods_user_behavior.behavior_type", "pv", 32945, "合法", "pv（浏览）"),
    ("ods_user_behavior.behavior_type", "buy", 11393, "合法", "buy（购买）"),
    ("ods_user_behavior.behavior_type", "cart", 7021, "合法", "cart（加购）"),
    ("ods_user_behavior.behavior_type", "fav", 4969, "合法", "fav（收藏）"),
    ("ods_user_behavior.behavior_type", "Cart", 619, "非法", "cart"),
    ("ods_user_behavior.behavior_type", "浏览", 611, "非法", "pv"),
    ("ods_user_behavior.behavior_type", "PV", 604, "非法", "pv"),
    ("ods_user_behavior.behavior_type", "加购", 646, "非法", "cart"),
    ("ods_user_behavior.behavior_type", "收藏", 616, "非法", "fav"),
    ("ods_user_behavior.behavior_type", "购买", 576, "非法", "buy"),
]
r = 3
for fld, val, cnt, legal, target in enum_rows:
    put_row(ws, r, [fld, val, cnt, legal, target],
            fmts=[None, None, NUM, None, None],
            aligns=["left", "center", "right", "center", "center"])
    r += 1

# 第二区块：类目尾空格说明
sub_title(ws, r + 1, "ods_product.category —— 16 种取值（合法域 8 种）", 5)
note_row = r + 2
ws.merge_cells(start_row=note_row, start_column=1, end_row=note_row, end_column=5)
c = ws.cell(row=note_row, column=1,
            value="8 个一级类目（数码家电/服饰鞋包/食品生鲜/美妆个护/家居生活/母婴玩具/运动户外/图书文娱）"
                  "各存在「带尾空格」与「不带尾空格」两种形态，共 16 种。处置：TRIM(category) 统一去除首尾空格。")
c.font = Font(name=FONT_NAME, size=10)
c.alignment = Alignment(horizontal="left", vertical="center", wrap_text=True)
c.border = BORDER
ws.row_dimensions[note_row].height = 32

set_widths(ws, [30, 16, 12, 10, 16])
ws.freeze_panes = "A3"
ws.auto_filter.ref = f"A2:E{r-1}"

# 非法值标红
ws.conditional_formatting.add(
    f"D3:D{r-1}",
    CellIsRule(operator="equal", formula=['"非法"'],
               fill=PatternFill("solid", bgColor=XL_RED_BG),
               font=Font(color=XL_RED_FG, bold=True))
)

# ======================================================== 5. 一致性 ====
ws = wb.create_sheet("一致性")
title_row(ws, "一致性（Consistency）—— 格式统一性与跨表关联", 4)

sub_title(ws, 2, "5.1 日期格式分布", 4)
header_row(ws, 3, ["表名", "字段", "格式分布", "统一目标"])
date_rows = [
    ("ods_user", "register_date", "ISO 2023-11-25：875 条 ／ 斜杠 2023/11/25：100 条 ／ 纯数字 20231125：25 条", "yyyy-MM-dd"),
    ("ods_order", "order_date", "斜杠 2024/7/26：15,600 条（100%，且月日不补零）", "yyyy-MM-dd"),
    ("ods_user_behavior", "behavior_time", "2024-11-05 10:20:30：53,912 条 ／ 2024/11/05 10:20：6,088 条", "yyyy-MM-dd HH:mm:ss"),
]
r = 4
for item in date_rows:
    put_row(ws, r, list(item), aligns=["left", "center", "left", "center"])
    ws.row_dimensions[r].height = 30
    r += 1

sub_title(ws, 8, "5.2 手机号格式（ods_user.phone）", 4)
header_row(ws, 9, ["形态", "", "数量", "处置"])
phone_rows = [
    ("纯数字 11 位（13892127520）", "", 898, "保留"),
    ("带横杠（138-9212-7520）", "", 102, "去横杠统一为 11 位纯数字"),
]
r = 10
for item in phone_rows:
    put_row(ws, r, list(item), fmts=[None, None, NUM, None],
            aligns=["left", "center", "right", "left"])
    r += 1

sub_title(ws, 13, "5.3 跨表关联完整性（孤儿外键检查）", 4)
header_row(ws, 14, ["关联关系", "", "孤儿记录数", "结论"])
fk_rows = [
    ("order_item.order_id → order.order_id", "", 0, "完整"),
    ("order_item.product_id → product.product_id", "", 0, "完整"),
    ("order.user_id → user.user_id", "", 0, "完整"),
    ("order.store_id → store.store_id", "", 0, "完整"),
    ("behavior.user_id → user.user_id", "", 0, "完整"),
    ("behavior.product_id → product.product_id", "", 0, "完整"),
    ("无明细的订单", "", 0, "完整"),
]
r = 15
for item in fk_rows:
    put_row(ws, r, list(item), fmts=[None, None, NUM, None],
            aligns=["left", "center", "right", "center"])
    r += 1

concl_row = r + 1
ws.merge_cells(start_row=concl_row, start_column=1, end_row=concl_row, end_column=4)
c = ws.cell(row=concl_row, column=1,
            value="结论：外键关联 100% 完整，无孤儿记录、无孤立订单，可直接安全 JOIN。")
c.font = Font(name=FONT_NAME, size=10, bold=True, color=XL_GRN_FG)
c.fill = PatternFill("solid", fgColor=XL_GRN_BG)
c.alignment = Alignment(horizontal="left", vertical="center")
c.border = BORDER
ws.row_dimensions[concl_row].height = 24

set_widths(ws, [40, 4, 14, 22])

# ======================================================== 6. 准确性 ====
ws = wb.create_sheet("准确性")
title_row(ws, "准确性（Accuracy）—— 数值业务合理性", 6)
header_row(ws, 2, ["表名", "字段", "异常类型", "数量", "合理区间", "处置"])

acc = [
    ("ods_user", "age", "负值 / 0 / 超大（-3、0、150、200）", 27, "1～120", "视为缺失，用中位数填充"),
    ("ods_product", "price", "负数", 20, "> 0", "取绝对值或按成本价 × 毛利率重算"),
    ("ods_product", "price", "异常高价", 16, "≤ 100,000", "按类目均价修正"),
    ("ods_order", "pay_amount", "负数", 310, "≥ 0", "视订单状态处理（退款类保留、其余置 0）"),
    ("ods_order", "pay_amount", "百万级异常", 312, "≤ 100,000", "按明细汇总或类目均价修正"),
    ("ods_order_item", "quantity", "0 值", 386, "≥ 1", "过滤"),
    ("ods_order_item", "quantity", "负数", 332, "≥ 1", "过滤"),
    ("ods_order_item", "quantity", "超大值（最大 99）", 363, "≤ 50", "过滤或截断"),
    ("ods_order_item", "unit_price", "0 或负值", 798, "> 0", "用商品表 price 回填"),
    ("ods_order_item", "discount", "超出 [0,1]", 0, "0～1", "无需处理"),
    ("ods_store", "area", "—", 0, "50～5,000 ㎡", "无需处理"),
]
r = 3
for item in acc:
    put_row(ws, r, list(item), fmts=[None, None, None, NUM, None, None],
            aligns=["left", "center", "left", "right", "center", "left"])
    ws.row_dimensions[r].height = 24
    r += 1

set_widths(ws, [18, 14, 28, 10, 16, 38])
ws.freeze_panes = "A3"
ws.auto_filter.ref = f"A2:F{r-1}"

# 有异常的数量标红
ws.conditional_formatting.add(
    f"D3:D{r-1}",
    CellIsRule(operator="greaterThan", formula=["0"],
               fill=PatternFill("solid", bgColor=XL_RED_BG),
               font=Font(color=XL_RED_FG))
)

# ====================================================== 7. 问题汇总 ====
ws = wb.create_sheet("问题汇总")
title_row(ws, "问题汇总与优先级", 4)
header_row(ws, 2, ["优先级", "问题", "影响范围", "处理周期"])

issues = [
    ("P0", "ods_order 主键重复 600 行", "会影响所有订单量、GMV 统计", "第 1 周（子任务 7）"),
    ("P0", "缺失值：age 51、email 193、gender 84、member_level 14、launch_date 11", "影响用户画像与商品分析", "第 1 周（子任务 6）"),
    ("P1", "枚举取值混乱：order_status 1,375 行、pay_type/channel/gender/member_level/behavior_type", "影响所有分组维度统计", "第 1 周起，第 2 周完成"),
    ("P1", "异常值：负金额 310、超大金额 312、负年龄 27、单价 0/负 798、数量异常 718", "影响金额类与销量类指标", "第 2 周"),
    ("P2", "格式不一致：日期 3 种（register_date）、手机号 2 种、时间 2 种", "影响时间维度分析", "第 2 周"),
    ("P2", "类目尾空格（8 类变 16 种）", "影响品类维度统计", "第 2 周"),
]
r = 3
for item in issues:
    put_row(ws, r, list(item), aligns=["center", "left", "left", "center"])
    ws.row_dimensions[r].height = 30
    r += 1

set_widths(ws, [10, 58, 30, 24])
ws.freeze_panes = "A3"
ws.auto_filter.ref = f"A2:D{r-1}"

# P0 标红、P1 标黄
ws.conditional_formatting.add(
    "A3:A8",
    CellIsRule(operator="equal", formula=['"P0"'],
               fill=PatternFill("solid", bgColor=XL_RED_BG),
               font=Font(color=XL_RED_FG, bold=True))
)
ws.conditional_formatting.add(
    "A3:A8",
    CellIsRule(operator="equal", formula=['"P1"'],
               fill=PatternFill("solid", bgColor=XL_YEL_BG),
               font=Font(color=XL_YEL_FG, bold=True))
)

# ====================================================== 8. 清洗对比 ====
ws = wb.create_sheet("清洗对比")
title_row(ws, "清洗前后对比（第 1 周成果）", 5)

sub_title(ws, 2, "9.1 行数变化", 4)
header_row(ws, 3, ["对象", "ODS（清洗前）", "DWD（清洗后）", "变化"])
rows_cnt = [
    ("用户表", 1000, 1000, "行数不变，问题清零"),
    ("商品表", 600, 600, "行数不变，问题清零"),
    ("订单表", 15600, 15000, "去重删除 600 行"),
    ("门店表", 60, "—", "无脏数据，未入 DWD"),
    ("明细表", 37549, "—", "本周未处理"),
    ("行为表", 60000, "—", "本周未处理"),
]
r = 4
for item in rows_cnt:
    put_row(ws, r, list(item), fmts=[None, NUM, NUM, None],
            aligns=["left", "right", "right", "left"])
    r += 1

sub_title(ws, 11, "9.2 缺失值与重复值修复", 4)
header_row(ws, 12, ["问题类型", "清洗前", "清洗后", "处置方式"])
fix_rows = [
    ("年龄缺失/异常", 78, 0, "有效年龄中位数填充（78 = 空 51 + 异常 27）"),
    ("性别缺失", 84, 0, "填充为「未知」"),
    ("会员等级缺失", 14, 0, "填充为「普通会员」"),
    ("上架日期缺失", 11, 0, "按类目上架日期中位数补全"),
    ("订单主键重复", 600, 0, "ROW_NUMBER 去重"),
    ("邮箱缺失", 193, 193, "策略性保留，仅加 email_is_null 标记"),
]
r = 13
for item in fix_rows:
    put_row(ws, r, list(item), fmts=[None, NUM, NUM, None],
            aligns=["left", "right", "right", "left"])
    ws.row_dimensions[r].height = 24
    r += 1

# 修复率（不含邮箱，属策略性保留）
sub_title(ws, 20, "9.3 修复率（口径：不含邮箱，属策略性保留）", 4)
header_row(ws, 21, ["指标", "数值", "", ""])
r = 22
repair = [
    ("清洗前问题总数", "=B13+B14+B15+B16+B17", NUM, "用户表 176 + 商品表 11 + 订单表 600"),
    ("清洗后问题总数", "=C13+C14+C15+C16+C17", NUM, "P0 问题全部清零"),
]
for name, formula, fmt, note in repair:
    put_row(ws, r, [name, formula, note, ""], fmts=[None, fmt, None, None],
            aligns=["left", "right", "left", "center"])
    r += 1
# 修复率 = (前 - 后) / 前，分母保护
put_row(ws, 24, ["修复率", '=IF(OR(B22="",B22=0),"",(B22-B23)/B22)', "—", ""],
        fmts=[None, PCT, None, None],
        aligns=["left", "right", "center", "center"], bold=True, fill=XL_SUB)

# 9.4 重复订单细分
sub_title(ws, 26, "9.4 重复订单细分", 4)
header_row(ws, 27, ["指标", "数值", "", ""])
dup_metrics = [
    ("ODS 订单总行数", 15600),
    ("唯一订单数", 15000),
    ("重复行数", 600),
    ("重复率", None),          # 公式
    ("曾重复的订单组数", 586),
    ("单订单最大重复次数", 4),
    ("始终唯一的订单", 14414),
]
r = 28
for name, val in dup_metrics:
    if name == "重复率":
        f = '=IF(OR(B28="",B28=0),"",B30/B28)'
        put_row(ws, r, [name, f, "重复行数 / 总行数", ""], fmts=[None, PCT, None, None],
                aligns=["left", "right", "left", "center"])
    else:
        put_row(ws, r, [name, val, "", ""], fmts=[None, NUM, None, None],
                aligns=["left", "right", "center", "center"])
    r += 1

ws.merge_cells(start_row=36, start_column=1, end_row=36, end_column=4)
c = ws.cell(row=36, column=1, value="校验：586 + 14,414 = 15,000 ✅　（去重未误删任何有明细引用的订单，孤儿记录 0）")
c.font = Font(name=FONT_NAME, size=10, bold=True, color=XL_GRN_FG)
c.fill = PatternFill("solid", fgColor=XL_GRN_BG)
c.alignment = Alignment(horizontal="left", vertical="center")
c.border = BORDER
ws.row_dimensions[36].height = 24

set_widths(ws, [24, 16, 46, 20])

# ========================================================== 保存 ====
os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
wb.save(OUT_PATH)
print(f"已生成：{OUT_PATH}")
print(f"工作表：{wb.sheetnames}")
