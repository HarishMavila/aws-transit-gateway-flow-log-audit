-- ============================================================================
-- Cross-environment conversations, by account and IP address.
--
-- One row per (source account, source IP, destination account, destination IP)
-- with traffic volume. This is the report you hand to application teams, once
-- the IPs have been resolved to named resources.
--
-- EDIT THE SETTINGS BLOCK BELOW before running.
--
-- To flip the direction, swap 'prod' and 'nonprod' in the two environment
-- predicates. Be aware that the two directions largely describe the SAME
-- conversations seen from either end, because a transit gateway logs both
-- directions of a flow. See 5-who-initiated.sql if you need to know which
-- side opened the connection.
-- ============================================================================

WITH settings AS (
  SELECT
    -- The account that owns the transit gateway. It usually also owns the
    -- Direct Connect gateway and the VPNs, so on-prem traffic arrives tagged
    -- with this account as its source.
    '777788889999'  AS hub_account_id,
    -- The hub account's own VPC CIDR prefix. Traffic from the hub account is
    -- only treated as belonging to an environment when it comes from here;
    -- anything else from that account is on-prem passing through.
    '10.10.'        AS hub_vpc_prefix,
    'prod'          AS source_environment,
    'nonprod'       AS destination_environment
),

-- Attachments that carry on-prem traffic rather than VPC-to-VPC traffic.
-- Find yours with:
--   aws ec2 describe-transit-gateway-attachments \
--     --query 'TransitGatewayAttachments[?ResourceType!=`vpc`].[TransitGatewayAttachmentId,ResourceType]'
excluded_attachments AS (
  SELECT attachment_id FROM (VALUES
    ('tgw-attach-0aaaaaaaaaaaaaaaa'),  -- Direct Connect gateway
    ('tgw-attach-0bbbbbbbbbbbbbbbb'),  -- VPN
    ('tgw-attach-0ccccccccccccccc')    -- VPN
  ) AS t (attachment_id)
)

SELECT
  src.account_name                        AS "Source Account",
  f.srcaddr                               AS "Source IP",
  dst.account_name                        AS "Destination Account",
  f.dstaddr                               AS "Destination IP",
  count(*)                                AS "Flow Records",
  sum(f.packets)                          AS "Packets",
  sum(f.bytes)                            AS "Bytes",
  -- Volume is what separates a once-a-day health check from a continuous
  -- replication stream. Without it every row looks equally urgent.
  round(sum(f.bytes) / 1048576.0, 2)      AS "MiB",
  min(from_unixtime(f.start))             AS "First Seen",
  max(from_unixtime(f."end"))             AS "Last Seen"

FROM tgw_flow_logs f
CROSS JOIN settings s
JOIN account_env src ON src.account_id = f.tgw_src_vpc_account_id
JOIN account_env dst ON dst.account_id = f.tgw_dst_vpc_account_id

WHERE
  -- Only successfully captured records.
  f.log_status = 'OK'

  -- Drop on-prem traffic arriving over Direct Connect or VPN.
  AND f.tgw_attachment_id NOT IN (SELECT attachment_id FROM excluded_attachments)

  -- Source is in the environment we care about. The hub account only counts
  -- when the packet actually originated inside the hub VPC.
  AND src.environment = s.source_environment
  AND (
    f.tgw_src_vpc_account_id != s.hub_account_id
    OR f.srcaddr LIKE s.hub_vpc_prefix || '%'
  )

  -- Destination is in a different environment.
  AND dst.environment = s.destination_environment
  AND (
    f.tgw_dst_vpc_account_id != s.hub_account_id
    OR f.dstaddr LIKE s.hub_vpc_prefix || '%'
  )

  -- If you leave flow logs running continuously rather than capturing a week
  -- at a time, uncomment this. It is the single biggest lever on scan cost.
  -- AND f.year = '2026' AND f.month = '09' AND f.day BETWEEN '01' AND '07'

GROUP BY
  src.account_name, f.srcaddr,
  dst.account_name, f.dstaddr

ORDER BY
  sum(f.bytes) DESC
