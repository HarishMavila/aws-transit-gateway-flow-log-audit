-- ============================================================================
-- Table definitions for auditing transit gateway flow logs.
--
-- Run once. The table definitions are permanent; the data underneath them is
-- ephemeral, since flow logs are enabled for a week at a time and expired by
-- an S3 lifecycle rule.
--
-- Replace:
--   example-tgw-flow-logs     your flow log bucket
--   example-athena-lookups    a bucket for the account/environment lookup
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Transit gateway flow logs
--
-- Maps the AWS DEFAULT record format positionally. The format is space
-- delimited, so the column NAMES are yours to choose but the ORDER is not.
-- If you use a custom log format, reorder these to match your format string.
--
-- Partition keys come from the hive-compatible S3 prefix. Enable
-- "Hive-compatible S3 prefix" on the flow log or MSCK REPAIR TABLE will
-- find nothing.
-- ----------------------------------------------------------------------------

CREATE EXTERNAL TABLE IF NOT EXISTS tgw_flow_logs (
  version int,
  resource_type string,
  account_id string,
  tgw_id string,
  tgw_attachment_id string,
  tgw_src_vpc_account_id string,
  tgw_dst_vpc_account_id string,
  tgw_src_vpc_id string,
  tgw_dst_vpc_id string,
  tgw_src_subnet_id string,
  tgw_dst_subnet_id string,
  tgw_src_eni string,
  tgw_dst_eni string,
  tgw_src_az_id string,
  tgw_dst_az_id string,
  tgw_pair_attachment_id string,
  srcaddr string,
  dstaddr string,
  srcport int,
  dstport int,
  protocol bigint,
  packets bigint,
  bytes bigint,
  start bigint,
  `end` bigint,
  log_status string,
  type string,
  packets_lost_no_route bigint,
  packets_lost_blackhole bigint,
  packets_lost_mtu_exceeded bigint,
  packets_lost_ttl_expired bigint,
  tcp_flags int,
  region string,
  flow_direction string,
  pkt_src_aws_service string,
  pkt_dst_aws_service string
) PARTITIONED BY (
  `aws-account-id` string,
  `aws-service` string,
  `aws-region` string,
  year string,
  month string,
  day string,
  hour string
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ' '
LOCATION 's3://example-tgw-flow-logs/AWSLogs/'
TBLPROPERTIES ('skip.header.line.count' = '1');


-- ----------------------------------------------------------------------------
-- 2. Account to environment lookup
--
-- Keeps the prod/nonprod/sandbox classification out of the queries. Generate
-- the CSV with scripts/build-account-env-csv.sh, review it, then upload it.
--
-- Expected CSV (no header row, since skip.header.line.count is not set):
--   111122223333,Checkout Prod,prod
--   444455556666,Checkout NonProd,nonprod
--   777788889999,Network Hub,prod
--
-- The "environment" column is the only value the queries branch on. Use
-- whatever labels you like as long as they are consistent.
-- ----------------------------------------------------------------------------

CREATE EXTERNAL TABLE IF NOT EXISTS account_env (
  account_id string,
  account_name string,
  environment string
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
LOCATION 's3://example-athena-lookups/account-env/';


-- ----------------------------------------------------------------------------
-- 3. Load partitions
--
-- Re-run after every capture window. Free: Athena does not charge for DDL or
-- partition management.
-- ----------------------------------------------------------------------------

-- MSCK REPAIR TABLE tgw_flow_logs;


-- ----------------------------------------------------------------------------
-- 4. Sanity checks
-- ----------------------------------------------------------------------------

-- Do the partitions look right, and is there data in them?
-- SELECT year, month, day, count(*) AS records
-- FROM tgw_flow_logs
-- GROUP BY year, month, day
-- ORDER BY year, month, day;

-- Does every account seen in the flow logs have an environment label?
-- Any rows returned here are accounts you need to add to account-env.csv.
-- SELECT DISTINCT f.tgw_src_vpc_account_id AS unmapped_account
-- FROM tgw_flow_logs f
-- LEFT JOIN account_env a ON a.account_id = f.tgw_src_vpc_account_id
-- WHERE a.account_id IS NULL;
