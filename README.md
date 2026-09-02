# AWS Transit Gateway Flow Log Audit

Find out which AWS accounts are talking across an environment boundary, before you enforce that boundary in the network.

This is the tooling behind the article [Who's Talking to Prod?](#) — auditing cross-environment traffic on a flat multi-account network with transit gateway flow logs, Athena, and a resource-inventory lookup, then segmenting with transit gateway route tables.

Everything here is sanitized. Account IDs, bucket names, gateway IDs and CIDRs are placeholders. Replace them with your own.

## The problem it solves

If every VPC in your organization attaches to one central transit gateway, any workload can reach any other workload regardless of environment. Transit gateway route tables can enforce environment isolation, but flipping them on a network that has been flat for years breaks dependencies nobody has written down.

So: measure first. Enumerate every cross-environment conversation, attribute each one to a named resource and an owning team, get the teams to remove what shouldn't be there, then segment one account at a time.

## Approach

A central transit gateway is a single choke point. One flow log observes every attached VPC in the organization at once, and the records already carry `tgw-src-vpc-account-id` and `tgw-dst-vpc-account-id`. If one account maps to one environment, those two fields alone tell you whether a flow crossed the boundary.

Flow logs run for **one week**, then get turned off. A lifecycle rule expires the data. This is a sampling exercise, not a monitoring one, and a week catches daily and weekly jobs. It also keeps a detailed map of internal network dependencies from sitting in S3 indefinitely.

## Layout

```
athena/
  1-create-tables.sql              flow log table + account/environment lookup table
  2-cross-env-traffic.sql          cross-environment conversations, by account and IP
  3-cross-env-traffic-ports.sql    same, with the service port (ephemeral side collapsed)
  4-all-traffic.sql                every conversation, including same-environment
  5-who-initiated.sql              TCP SYN heuristic for connection direction
enrichment/
  enrich_report.py                 resolve each IP to a named resource and owner
  requirements.txt
scripts/
  build-account-env-csv.sh         generate the lookup table from AWS Organizations
```

## Setup

### 1. Enable flow logs on the transit gateway

Settings that matter:

| Setting | Value | Why |
|---|---|---|
| Log record format | AWS default format | The DDL here maps to it positionally |
| Log file format | Text | Gzipped; Athena reads compressed bytes, which is what you pay for |
| Hive-compatible S3 prefix | **On** | `MSCK REPAIR TABLE` depends on it |
| Partition logs by time | Every 1 hour | Finer partition pruning if you leave logs running |
| Destination | S3 | |

Put a lifecycle rule on the bucket so the data expires on its own:

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket example-tgw-flow-logs \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-flow-logs",
      "Status": "Enabled",
      "Filter": {},
      "Expiration": {"Days": 30},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    }]
  }'
```

### 2. Build the account-to-environment lookup

Rather than hardcoding account IDs into every query, keep the mapping in a table:

```bash
./scripts/build-account-env-csv.sh > account-env.csv
aws s3 cp account-env.csv s3://example-athena-lookups/account-env/account-env.csv
```

Review the output before uploading. The script reads an `Environment` tag from each account and falls back to a name heuristic, which will not be right for every account.

### 3. Create the Athena tables

Run `athena/1-create-tables.sql`, then load partitions:

```sql
MSCK REPAIR TABLE tgw_flow_logs;
```

Re-run that after every capture window.

### 4. Query

Run the queries in `athena/`. Each has a small block of settings at the top to edit: your hub account ID, hub VPC CIDR, and the attachment IDs of your Direct Connect and VPN attachments.

### 5. Enrich

Download the results as CSV, then resolve the IPs to real resources:

```bash
cd enrichment
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
./enrich_report.py ../reports/*.csv
```

See [enrichment/README.md](enrichment/README.md) for the resource-inventory options, including one that needs no third-party tooling.

## Five things that will skew your results

Learned the hard way. All five are handled in the queries here.

**The account hosting the transit gateway is not a normal participant.** It usually also owns the Direct Connect gateway and the VPNs, so on-prem traffic enters the flow logs tagged with the hub account as its source. Treat the hub as an environment member only when the address is inside the hub VPC's own CIDR.

**Direct Connect and VPN attachments smuggle on-prem traffic into a VPC-to-VPC report.** Exclude them by attachment ID. Note that `tgw_attachment_id` is one side of the flow and `tgw_pair_attachment_id` is the other, so filtering one field only catches one direction. Keep the CIDR guard as well.

**Direction in the log is not who initiated.** A transit gateway logs both directions of a conversation, so a "prod to nonprod" report and a "nonprod to prod" report describe largely the same sessions viewed from either end. In our data about 95% of pairs in one appeared reversed in the other. If you need initiation direction, use `5-who-initiated.sql`.

**Ephemeral ports inflate results by roughly 40x.** Grouping on both ports produces one row per client port. `3-cross-env-traffic-ports.sql` collapses the ephemeral side. Expect most of what remains to be DNS and Active Directory chatter, which is a platform decision about shared services rather than a finding for an application team.

**Filter `log_status = 'OK'`** to drop `NODATA` and `SKIPDATA` records.

## If your workloads run on EKS

By default the AWS VPC CNI rewrites the source address of pod traffic to the node's primary IP when the destination is outside the VPC. Traffic across a transit gateway is outside the VPC, so **every pod on a node appears in the flow log as the node**. On a shared platform that hosts many teams' workloads on the same nodes, that makes the report unattributable.

To preserve pod IPs end to end, disable source NAT in the VPC CNI:

```json
{ "env": { "AWS_VPC_K8S_CNI_EXTERNALSNAT": "true" } }
```

Two caveats. Pods no longer borrow the node's path to the internet, so they need a route through a NAT gateway. And this is a cluster-wide networking change, so treat it as one.

## Cost

Athena charges per TB of data read from S3, and flow logs are gzipped, so you pay for the compressed size. In our case four full-table scans across roughly a billion records cost under $0.50 in total. DDL and partition management are free.

The larger line item is flow log delivery, billed per GB of log data delivered at vended-log rates. Price that against your own traffic volume before committing.

## Segmenting, once the traffic is gone

Transit gateway segmentation rests on two knobs that are easy to conflate:

- **Association** decides which route table governs traffic *leaving* an attachment. One per attachment.
- **Propagation** decides which route tables *learn* an attachment's routes. Many per attachment.

Create the environment route tables and propagate routes into them well before associating anything. With the destination table already populated, moving an account is one call:

```bash
aws ec2 replace-transit-gateway-route-table-association \
  --transit-gateway-attachment-id tgw-attach-0dddddddddddddddd \
  --transit-gateway-route-table-id tgw-rtb-0eeeeeeeeeeeeeeee
```

Blast radius of one account, reversible in seconds.

Useful asymmetry: association only governs egress, but breaking one direction breaks the conversation. A prod VPC still in the flat table can forward a packet to a migrated nonprod VPC, but the reply is governed by the nonprod route table, which has no route back. The session never establishes. Moving one side is enough, which means you can make progress without touching prod.

Two constraints worth knowing before you start. Expect to need a short, explicit exception list for shared services that every environment genuinely depends on. And route tables act on attachments, which belong to VPCs, so if several environments share a VPC no amount of route table work will separate them.

## License

MIT. See [LICENSE](LICENSE).
