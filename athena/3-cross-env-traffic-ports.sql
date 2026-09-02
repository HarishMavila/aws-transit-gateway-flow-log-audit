-- ============================================================================
-- Cross-environment conversations including the service port.
--
-- The naive version of this query groups on BOTH ports, which produces one row
-- per ephemeral client port. In our data that turned a 2,400 row report into a
-- 735,000 row report carrying no extra information.
--
-- This version keeps only the service port, which collapses it back by roughly
-- 40x. Knowing a workload talks to port 5432 is useful. Knowing it did so from
-- client port 51125 is not.
--
-- Also reports a service_class so you can separate shared infrastructure
-- chatter from real application dependencies. Expect DNS and Active Directory
-- to dominate: in our reports port 53 alone was about half the rows, and DNS
-- plus AD together were about two thirds. That is a platform decision about
-- which shared services may span environments, not a finding for an app team.
-- ============================================================================

WITH settings AS (
  SELECT
    '777788889999'  AS hub_account_id,
    '10.10.'        AS hub_vpc_prefix,
    'prod'          AS source_environment,
    'nonprod'       AS destination_environment,
    -- Ports at or above this are assumed to be ephemeral client ports.
    -- Linux defaults to 32768-60999; adjust if your hosts differ.
    32768           AS ephemeral_port_floor
),

excluded_attachments AS (
  SELECT attachment_id FROM (VALUES
    ('tgw-attach-0aaaaaaaaaaaaaaaa'),  -- Direct Connect gateway
    ('tgw-attach-0bbbbbbbbbbbbbbbb'),  -- VPN
    ('tgw-attach-0ccccccccccccccc')    -- VPN
  ) AS t (attachment_id)
),

flows AS (
  SELECT
    src.account_name AS source_account,
    f.srcaddr        AS source_ip,
    dst.account_name AS destination_account,
    f.dstaddr        AS destination_ip,
    f.protocol,
    f.packets,
    f.bytes,

    -- Service-port heuristic: of the two ports, the listening side is almost
    -- always the lower one, because the other end is an ephemeral port from
    -- the high range. Falls back to the destination port when both look
    -- ephemeral (rare, but happens with some peer-to-peer protocols).
    CASE
      WHEN f.srcport < s.ephemeral_port_floor AND f.dstport < s.ephemeral_port_floor
        THEN least(f.srcport, f.dstport)
      WHEN f.srcport < s.ephemeral_port_floor THEN f.srcport
      WHEN f.dstport < s.ephemeral_port_floor THEN f.dstport
      ELSE f.dstport
    END AS service_port

  FROM tgw_flow_logs f
  CROSS JOIN settings s
  JOIN account_env src ON src.account_id = f.tgw_src_vpc_account_id
  JOIN account_env dst ON dst.account_id = f.tgw_dst_vpc_account_id

  WHERE f.log_status = 'OK'
    AND f.tgw_attachment_id NOT IN (SELECT attachment_id FROM excluded_attachments)
    AND src.environment = s.source_environment
    AND (f.tgw_src_vpc_account_id != s.hub_account_id
         OR f.srcaddr LIKE s.hub_vpc_prefix || '%')
    AND dst.environment = s.destination_environment
    AND (f.tgw_dst_vpc_account_id != s.hub_account_id
         OR f.dstaddr LIKE s.hub_vpc_prefix || '%')
    -- AND f.year = '2026' AND f.month = '09' AND f.day BETWEEN '01' AND '07'
)

SELECT
  source_account                      AS "Source Account",
  source_ip                           AS "Source IP",
  destination_account                 AS "Destination Account",
  destination_ip                      AS "Destination IP",
  service_port                        AS "Service Port",

  CASE
    WHEN service_port = 53                            THEN 'DNS'
    WHEN service_port IN (88, 389, 445, 464, 636,
                          3268, 3269, 137, 138, 139)  THEN 'Active Directory / SMB'
    WHEN service_port IN (80, 443, 8080, 8443)        THEN 'HTTP(S)'
    WHEN service_port IN (1433, 1521, 3306, 5432,
                          27017, 6379, 9042)          THEN 'Database / cache'
    WHEN service_port IN (22, 3389, 5985, 5986)       THEN 'Remote access'
    WHEN service_port IN (25, 465, 587)               THEN 'Mail'
    WHEN service_port IN (2049, 111)                  THEN 'NFS'
    ELSE 'Other'
  END                                 AS "Service Class",

  CASE protocol
    WHEN 6 THEN 'TCP' WHEN 17 THEN 'UDP' WHEN 1 THEN 'ICMP'
    ELSE cast(protocol AS varchar)
  END                                 AS "Protocol",

  count(*)                            AS "Flow Records",
  sum(packets)                        AS "Packets",
  round(sum(bytes) / 1048576.0, 2)    AS "MiB"

FROM flows
GROUP BY
  source_account, source_ip,
  destination_account, destination_ip,
  service_port, protocol
ORDER BY
  sum(bytes) DESC
