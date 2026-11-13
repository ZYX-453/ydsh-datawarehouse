-- =============================================================================
-- 文件   : sql/ads/05_load_ads_user_value.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— ADS 用户价值分层（RFM）
-- -----------------------------------------------------------------------------
-- 上游：dws_user_agg（RFM 原始值：r_value / f_value / m_value）
-- 打分规则（业务阈值，不用 ntile 分位）：
--   为什么不用 ntile(5)：分位数打分是「相对的」，用户规模一变，同一个人就被换层，
--   跨月对比会失真；业务阈值是「绝对的」，可解释、可对业务方承诺。
--   阈值取自本项目实测分位（见 docs/09 第 4 节）：
--     M：P20=16,917  P50=23,668  P80=32,886   → 取整 17000 / 24000 / 33000
--     F：P20=6.7     P50=9.2     P80=12.2     → 取整 7 / 9 / 12
--     R：P50=24 天   P80=55 天                → 取整 14 / 25 / 40 / 60
--   R：末单距 2024-12-31 天数   <=14→5  <=25→4  <=40→3  <=60→2  else 1
--   F：成交订单数               >=12→5  >=10→4  >=8→3   >=6→2    else 1
--   M：累计消费金额             >=33000→5 >=24000→4 >=17000→3 >=10000→2 else 1
-- 分层命名：沿用 RFM 八分层（重要价值 / 重要保持 / 重要发展 / 重要挽留 /
--   一般价值 / 一般保持 / 一般发展 / 一般挽留）。
--   打分均 >=4 记「高」，<=2 记「低」，3 分（中间）归入「一般」侧。
-- =============================================================================

DROP TABLE IF EXISTS stg_user_rfm;
CREATE TABLE stg_user_rfm STORED AS ORC AS
SELECT
    user_id, member_level, order_cnt, total_gmv, r_value,
    CASE WHEN r_value <= 14  THEN 5
         WHEN r_value <= 25  THEN 4
         WHEN r_value <= 40  THEN 3
         WHEN r_value <= 60  THEN 2
         ELSE 1 END                                   AS r_score,
    CASE WHEN f_value >= 12 THEN 5
         WHEN f_value >= 10 THEN 4
         WHEN f_value >= 8  THEN 3
         WHEN f_value >= 6  THEN 2
         ELSE 1 END                                   AS f_score,
    CASE WHEN m_value >= 33000 THEN 5
         WHEN m_value >= 24000 THEN 4
         WHEN m_value >= 17000 THEN 3
         WHEN m_value >= 10000 THEN 2
         ELSE 1 END                                   AS m_score
FROM ydsh_dws.dws_user_agg;

INSERT OVERWRITE TABLE ydsh_ads.ads_user_value
SELECT
    segment,
    count(*)                                              AS user_cnt,
    count(*) / tot.total_users                             AS user_share,
    sum(total_gmv)                                         AS gmv,
    sum(total_gmv) / tot.gmv_all                           AS gmv_share,
    sum(total_gmv) / count(*)                              AS avg_gmv,
    sum(order_cnt) / count(*)                              AS avg_orders,
    avg(r_value)                                           AS avg_recency
FROM (
    SELECT
        s.*,
        CASE
            WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN '重要价值客户'
            WHEN r_score <= 2 AND f_score >= 4 AND m_score >= 4 THEN '重要保持客户'
            WHEN r_score >= 4 AND f_score <= 2 AND m_score >= 4 THEN '重要发展客户'
            WHEN r_score <= 2 AND f_score <= 2 AND m_score >= 4 THEN '重要挽留客户'
            WHEN r_score >= 4 AND m_score <= 2                  THEN '一般发展客户'
            WHEN r_score <= 2 AND m_score <= 2                  THEN '一般挽留客户'
            WHEN f_score >= 4                                   THEN '一般保持客户'
            ELSE '一般价值客户'
        END AS segment
    FROM stg_user_rfm s
) t
CROSS JOIN (
    SELECT count(*) AS total_users, sum(total_gmv) AS gmv_all FROM ydsh_dws.dws_user_agg
) tot
GROUP BY segment, tot.total_users, tot.gmv_all;

DROP TABLE IF EXISTS stg_user_rfm;
