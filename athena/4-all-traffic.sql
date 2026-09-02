-- ============================================================================
-- Every account-to-account conversation, including same-environment traffic.
--
-- Useful for two things:
--   1. A baseline. Cross-environment traffic is easier to argue about when you
--      can show it as a share of total traffic.
--   2. Finding accounts your lookup table does not know about. Anything with
--      an "unmapped" environment is an account that needs classifying.
--
-- Aggregated to the account pair rather than the IP pair, so it stays readable.
-- Account pairs are also the stable unit over time: in our data only about 14%
-- of IP-to-IP pairs persisted between capture windows two months apart, because
-- pod and ENI addresses churn, while the account pairs barely moved.
-- ============================================================================

WITH settings AS (
  SELECT
    '777788889999'  AS hub_account_id,
    '10.10.'        AS hub_vpc_prefix
),

excluded_attachments AS (
  SELECT attachment_id FROM (VALUES
    ('tgw-attach-0aaaaaaaaaaaaaaaa'),  -- Direct Connect gateway
    ('tgw-attach-0bbbbbbbbbbbbbbbb'),  -- VPN
    ('tgw-attach-0ccccccccccccccc')    -- VPN
  ) AS t (attachment_id)
)

SELECT
  coalesce(src.account_name, f.tgw_src_vpc_account_id)  AS "Source Account",
  coalesce(src.environment, 'unmapped')                 AS "Source Env",
  coalesce(dst.account_name, f.tgw_dst_vpc_account_id)  AS "Destination Account",
  coalesce(dst.environment, 'unmapped')                 AS "Destination Env",

  CASE
    WHEN src.environment IS NULL OR dst.environment IS NULL THEN 'unknown'
    WHEN src.environment = dst.environment                  THEN 'same-env'
    ELSE 'CROSS-ENV'
  END                                                   AS "Boundary",

  count(*)                                              AS "Flow Records",
  count(DISTINCT f.srcaddr || '>' || f.dstaddr)          AS "Distinct IP Pairs",
  round(sum(f.bytes) / 1073741824.0, 3)                  AS "GiB"

FROM tgw_flow_logs f
CROSS JOIN settings s
LEFT JOIN account_env src ON src.account_id = f.tgw_src_vpc_account_id
LEFT JOIN account_env dst ON dst.account_id = f.tgw_dst_vpc_account_id

WHERE f.log_status = 'OK'
  AND f.tgw_attachment_id NOT IN (SELECT attachment_id FROM excluded_attachments)
  -- Exclude on-prem traffic transiting the hub account.
  AND (f.tgw_src_vpc_account_id != s.hub_account_id
       OR f.srcaddr LIKE s.hub_vpc_prefix || '%')
  AND (f.tgw_dst_vpc_account_id != s.hub_account_id
       OR f.dstaddr LIKE s.hub_vpc_prefix || '%')
  -- AND f.year = '2026' AND f.month = '09' AND f.day BETWEEN '01' AND '07'

GROUP BY
  coalesce(src.account_name, f.tgw_src_vpc_account_id),
  coalesce(src.environment, 'unmapped'),
  coalesce(dst.account_name, f.tgw_dst_vpc_account_id),
  coalesce(dst.environment, 'unmapped'),
  CASE
    WHEN src.environment IS NULL OR dst.environment IS NULL THEN 'unknown'
    WHEN src.environment = dst.environment                  THEN 'same-env'
    ELSE 'CROSS-ENV'
  END

ORDER BY
  sum(f.bytes) DESC
