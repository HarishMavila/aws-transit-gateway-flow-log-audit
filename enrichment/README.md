# Resolving IPs to owners

A flow log report is a list of IP pairs. No application team can act on that, and no platform team can route it to an owner. Turning it into something actionable means answering, for every address: what resource is this, and whose is it?

## Usage

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

./enrich_report.py ../reports/cross-env-prod-to-nonprod.csv
```

The script adds four columns to each report, in place: `Source Type`, `Source Name`, `Destination Type`, `Destination Name`.

Useful flags:

| Flag | Effect |
|---|---|
| `--dry-run` | Count and sample the IPs that need resolving, then stop |
| `--cache-only` | Apply `ip-cache.json` with no API calls |

Every lookup is cached in `ip-cache.json` as it completes, so an interrupted run resumes for free and a second report covering overlapping addresses costs nothing. Misses are cached too, so unresolvable addresses are not retried on every run.

## Option 1: Wiz (what this script uses)

[Wiz](https://www.wiz.io/) is a cloud security platform that continuously inventories your cloud environment and builds a graph of resources and the relationships between them. Relevant here: it already knows which network interface held which address, and which workload that interface belonged to.

The lookup walks that graph:

```
NETWORK_ADDRESS  --owns(reverse)-->  NETWORK_INTERFACE  --contains(reverse)-->  CLOUD_RESOURCE
```

That middle hop is the important one, and it is why this works for Kubernetes.

## Option 2: AWS Config, if you don't have Wiz

Most of this is reproducible natively. With an organization-wide Config aggregator, one advanced query returns IP-to-resource across every account without needing a role in each one:

```sql
SELECT
  resourceId,
  resourceType,
  accountId,
  awsRegion,
  configuration.privateIpAddress,
  configuration.description
WHERE
  resourceType = 'AWS::EC2::NetworkInterface'
```

```bash
aws configservice select-aggregate-resource-config \
  --configuration-aggregator-name my-org-aggregator \
  --expression "SELECT resourceId, resourceType, accountId, configuration.privateIpAddress, configuration.description WHERE resourceType = 'AWS::EC2::NetworkInterface'" \
  --max-results 100
```

Without an aggregator, `aws ec2 describe-network-interfaces` per account gets you the same data and needs a role in each one:

```bash
aws ec2 describe-network-interfaces \
  --query 'NetworkInterfaces[].[PrivateIpAddress,InterfaceType,Description,Attachment.InstanceId]' \
  --output text
```

The `Description` field is more useful than it looks. AWS populates it with things like the load balancer name, the RDS instance, or the EKS cluster the interface belongs to, which is often enough to identify an owner.

Build a CSV of `ip,type,name` from either source and feed it in as a pre-populated `ip-cache.json`:

```json
{
  "10.20.4.11": { "name": "catalog-indexer-dev-3", "type": "VIRTUAL_MACHINE" },
  "10.40.11.132": { "name": "orders-db-primary", "type": "DATABASE" }
}
```

Then run with `--cache-only` and no Wiz credentials are needed.

## Where the native path runs out: Kubernetes

If your workloads run on EKS, this is the part that decides whether the whole audit is usable.

AWS Config inventories ENIs, not pods. It can tell you an address belongs to a node group in a particular cluster. It cannot tell you which pod was using it, and therefore cannot tell you which team owns the traffic. On a shared platform where many teams' workloads run on the same nodes, "some pod on this cluster talks to prod" is not a finding anybody can act on.

A resource graph that models pods closes that gap. This is the main reason we kept a third-party inventory in the pipeline rather than going fully native.

There is a prerequisite, though, and it sits upstream of any lookup tool.

### Pod IPs have to survive the transit gateway first

By default the AWS VPC CNI rewrites the source address of pod traffic to the node's primary IP when the destination is outside the VPC. Traffic across a transit gateway is outside the VPC. So with default settings, **every pod on a node appears in the flow log as the node**, and no lookup tool can recover what was lost before the record was written.

Check what your clusters do:

```bash
aws eks describe-addon \
  --cluster-name my-cluster \
  --addon-name vpc-cni \
  --query 'addon.configurationValues'
```

To preserve pod addresses end to end:

```json
{ "env": { "AWS_VPC_K8S_CNI_EXTERNALSNAT": "true" } }
```

Two caveats:

- Pods no longer borrow the node's route to the internet, so they need a path through a NAT gateway.
- This is a cluster-wide networking change. Treat it as one, and do it before the capture window rather than during it.

## What good coverage looks like

Expect 60% to 95% of addresses to resolve, varying by report. The gaps are usually legitimate: regional NAT gateways, interfaces deleted between the capture and the lookup, and on-prem addresses your cloud inventory has never seen.

Unresolved rows are still worth keeping. The account pair alone is often enough to start a conversation with a team, and account pairs are the stable unit over time. In our data only about 14% of IP-to-IP pairs persisted between capture windows two months apart, because pod and ENI addresses churn constantly, while the account pairs barely moved.
