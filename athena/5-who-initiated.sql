-- ============================================================================
-- Which side actually opened the connection.
--
-- WHY YOU NEED THIS
-- A transit gateway logs both directions of a conversation. So a report of
-- "prod to nonprod" traffic and a report of "nonprod to prod" traffic describe
-- largely the SAME sessions, seen from either end. In our data about 95% of the
-- source-destination pairs in one appeared reversed in the other.
--
-- That matters because it changes who owns the fix. If nonprod opens a
-- connection to a prod database, the nonprod team has a dependency to remove.
-- If prod opens a connection to nonprod, that is a much more serious finding.
-- Grouping by srcaddr alone cannot tell them apart: a prod DNS server answering
-- nonprod queries appears as "prod to nonprod" traffic all day long.
--
-- HOW IT WORKS
-- The tcp_flags field is a bitmask. Per the AWS flow log documentation:
--     FIN = 1, SYN = 2, RST = 4, SYN-ACK = 18
-- ACK and PSH on their own are not recorded. Flags are OR-ed together over the
-- aggregation interval, so a short connection can appear as 3 (SYN + FIN) or
-- 19 (SYN-ACK + FIN).
--
-- Note that 18 (SYN-ACK) also has the SYN bit set, because 18 = 16 + 2. So a
-- naive "tcp_flags & 2" test matches the responder too. The initiator is the
-- side that sent SYN *without* the ACK bit:
--     initiator : tcp_flags & 2 = 2  AND  tcp_flags & 16 = 0     (2, 3)
--     responder : tcp_flags & 16 = 16                            (18, 19)
--
-- LIMITATIONS
--   * TCP only. UDP has no handshake, so nothing can be inferred for DNS,
--     NTP, syslog and similar. Those rows are reported as 'udp-no-handshake'.
--   * Long-lived connections whose handshake happened before the capture
--     window began have no SYN record and show as 'established-before-capture'.
--   * Records with tcp_flags = 0 carry no usable signal.
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
),

cross_env AS (
  SELECT
    src.account_name  AS source_account,
    src.environment   AS source_env,
    f.srcaddr         AS source_ip,
    dst.account_name  AS destination_account,
    dst.environment   AS destination_env,
    f.dstaddr         AS destination_ip,
    f.dstport         AS destination_port,
    f.protocol,
    f.tcp_flags,
    f.packets,
    f.bytes
  FROM tgw_flow_logs f
  CROSS JOIN settings s
  JOIN account_env src ON src.account_id = f.tgw_src_vpc_account_id
  JOIN account_env dst ON dst.account_id = f.tgw_dst_vpc_account_id
  WHERE f.log_status = 'OK'
    AND f.tgw_attachment_id NOT IN (SELECT attachment_id FROM excluded_attachments)
    AND src.environment != dst.environment
    AND (f.tgw_src_vpc_account_id != s.hub_account_id
         OR f.srcaddr LIKE s.hub_vpc_prefix || '%')
    AND (f.tgw_dst_vpc_account_id != s.hub_account_id
         OR f.dstaddr LIKE s.hub_vpc_prefix || '%')
    -- AND f.year = '2026' AND f.month = '09' AND f.day BETWEEN '01' AND '07'
)

SELECT
  CASE
    WHEN protocol != 6                              THEN 'udp-no-handshake'
    WHEN tcp_flags IS NULL OR tcp_flags = 0         THEN 'established-before-capture'
    WHEN bitwise_and(tcp_flags, 16) = 16            THEN 'responder'
    WHEN bitwise_and(tcp_flags, 2)  = 2             THEN 'INITIATOR'
    ELSE 'established-before-capture'
  END                                   AS "Role Of Source",

  source_env                            AS "Source Env",
  source_account                        AS "Source Account",
  source_ip                             AS "Source IP",
  destination_env                       AS "Destination Env",
  destination_account                   AS "Destination Account",
  destination_ip                        AS "Destination IP",
  destination_port                      AS "Destination Port",

  count(*)                              AS "Flow Records",
  round(sum(bytes) / 1048576.0, 2)      AS "MiB"

FROM cross_env

-- Keep only the rows where the source is the side that opened the connection.
-- Comment this out to see the full picture including responders.
WHERE protocol = 6
  AND bitwise_and(tcp_flags, 2) = 2
  AND bitwise_and(tcp_flags, 16) = 0

GROUP BY
  CASE
    WHEN protocol != 6                              THEN 'udp-no-handshake'
    WHEN tcp_flags IS NULL OR tcp_flags = 0         THEN 'established-before-capture'
    WHEN bitwise_and(tcp_flags, 16) = 16            THEN 'responder'
    WHEN bitwise_and(tcp_flags, 2)  = 2             THEN 'INITIATOR'
    ELSE 'established-before-capture'
  END,
  source_env, source_account, source_ip,
  destination_env, destination_account, destination_ip, destination_port

ORDER BY
  sum(bytes) DESC


-- ----------------------------------------------------------------------------
-- Summary: which direction is actually opening cross-environment connections?
-- Run this first. It is usually the more revealing of the two.
-- ----------------------------------------------------------------------------
--
-- SELECT
--   source_env      AS "Initiating Env",
--   destination_env AS "Receiving Env",
--   count(*)                                    AS "Flow Records",
--   count(DISTINCT source_ip)                   AS "Distinct Initiators",
--   count(DISTINCT destination_ip)              AS "Distinct Targets",
--   round(sum(bytes) / 1073741824.0, 3)         AS "GiB"
-- FROM cross_env
-- WHERE protocol = 6
--   AND bitwise_and(tcp_flags, 2) = 2
--   AND bitwise_and(tcp_flags, 16) = 0
-- GROUP BY source_env, destination_env
-- ORDER BY count(*) DESC
