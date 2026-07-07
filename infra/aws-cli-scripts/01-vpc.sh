#!/usr/bin/env bash
# Session 07 — VPC networking: 2 public + 2 private subnets across 2 AZs, IGW, single NAT
# Gateway (private subnets share it — cheaper than one per AZ, accepted tradeoff for this
# project's scale), route tables.
#
# Idempotent: every resource is looked up by its Name tag first; only created if missing. Safe
# to re-run after a partial failure (e.g. NAT Gateway still provisioning).
#
# Cost note: the NAT Gateway is the one billable-while-idle resource here (~$0.045/hr +
# data processing). See docs/sessions/07-aws-networking-ecr.md for the cost discussion.
#
# Requires: `default` AWS CLI profile (see infra/aws-cli-scripts/README.md for why there's no
# separate named profile, and the stray-env-var warning this script guards against below).

set -euo pipefail

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

PROJECT_NAME="chatapp"
AWS_PROFILE="default"
AWS_REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
PUBLIC_A_CIDR="10.0.0.0/24"
PUBLIC_B_CIDR="10.0.1.0/24"
PRIVATE_A_CIDR="10.0.10.0/24"
PRIVATE_B_CIDR="10.0.11.0/24"

export AWS_PROFILE AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.aws"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

echo "== AZs =="
AZ_A="$(aws ec2 describe-availability-zones --filters "Name=state,Values=available" \
  --query "AvailabilityZones[0].ZoneName" --output text)"
AZ_B="$(aws ec2 describe-availability-zones --filters "Name=state,Values=available" \
  --query "AvailabilityZones[1].ZoneName" --output text)"
echo "AZ_A=$AZ_A AZ_B=$AZ_B"

get_by_tag() {
  # get_by_tag <describe-command...> <query>
  local query="$1"; shift
  "$@" --query "$query" --output text 2>/dev/null | grep -v '^None$' || true
}

# --- VPC -----------------------------------------------------------------------------------

echo
echo "== VPC =="
VPC_ID="$(get_by_tag "Vpcs[0].VpcId" aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" "Name=state,Values=available")"
if [ -z "${VPC_ID:-}" ]; then
  VPC_ID="$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc}]" \
    --query "Vpc.VpcId" --output text)"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}"
  echo "Created VPC $VPC_ID"
else
  echo "VPC already exists: $VPC_ID"
fi

# --- Internet Gateway ------------------------------------------------------------------------

echo
echo "== Internet Gateway =="
IGW_ID="$(get_by_tag "InternetGateways[0].InternetGatewayId" aws ec2 describe-internet-gateways \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-igw")"
if [ -z "${IGW_ID:-}" ]; then
  IGW_ID="$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw}]" \
    --query "InternetGateway.InternetGatewayId" --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  echo "Created + attached IGW $IGW_ID"
else
  echo "IGW already exists: $IGW_ID"
fi

# --- Subnets ---------------------------------------------------------------------------------

create_subnet() {
  local name="$1" cidr="$2" az="$3" public="$4"
  local id
  id="$(get_by_tag "Subnets[0].SubnetId" aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=$name" "Name=vpc-id,Values=$VPC_ID")"
  if [ -z "${id:-}" ]; then
    id="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name}]" \
      --query "Subnet.SubnetId" --output text)"
    if [ "$public" = "true" ]; then
      aws ec2 modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch
    fi
    echo "Created subnet $name: $id" >&2
  else
    echo "Subnet $name already exists: $id" >&2
  fi
  echo "$id"
}

echo
echo "== Subnets =="
PUBLIC_SUBNET_A_ID="$(create_subnet "${PROJECT_NAME}-public-a" "$PUBLIC_A_CIDR" "$AZ_A" true)"
PUBLIC_SUBNET_B_ID="$(create_subnet "${PROJECT_NAME}-public-b" "$PUBLIC_B_CIDR" "$AZ_B" true)"
PRIVATE_SUBNET_A_ID="$(create_subnet "${PROJECT_NAME}-private-a" "$PRIVATE_A_CIDR" "$AZ_A" false)"
PRIVATE_SUBNET_B_ID="$(create_subnet "${PROJECT_NAME}-private-b" "$PRIVATE_B_CIDR" "$AZ_B" false)"

# --- Public route table ------------------------------------------------------------------------

echo
echo "== Public route table =="
PUBLIC_RTB_ID="$(get_by_tag "RouteTables[0].RouteTableId" aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-public-rtb" "Name=vpc-id,Values=$VPC_ID")"
if [ -z "${PUBLIC_RTB_ID:-}" ]; then
  PUBLIC_RTB_ID="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-rtb}]" \
    --query "RouteTable.RouteTableId" --output text)"
  aws ec2 create-route --route-table-id "$PUBLIC_RTB_ID" --destination-cidr-block "0.0.0.0/0" \
    --gateway-id "$IGW_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$PUBLIC_RTB_ID" --subnet-id "$PUBLIC_SUBNET_A_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$PUBLIC_RTB_ID" --subnet-id "$PUBLIC_SUBNET_B_ID" >/dev/null
  echo "Created public route table $PUBLIC_RTB_ID (0.0.0.0/0 -> IGW), associated both public subnets."
else
  echo "Public route table already exists: $PUBLIC_RTB_ID"
fi

# --- NAT Gateway (billable) ---------------------------------------------------------------------

echo
echo "== NAT Gateway (billable while it exists) =="
NAT_GATEWAY_ID="$(get_by_tag "NatGateways[0].NatGatewayId" aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=${PROJECT_NAME}-nat" "Name=state,Values=pending,available")"
if [ -z "${NAT_GATEWAY_ID:-}" ]; then
  NAT_EIP_ALLOC_ID="$(get_by_tag "Addresses[0].AllocationId" aws ec2 describe-addresses \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-nat-eip")"
  if [ -z "${NAT_EIP_ALLOC_ID:-}" ]; then
    NAT_EIP_ALLOC_ID="$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat-eip}]" \
      --query "AllocationId" --output text)"
    echo "Allocated EIP $NAT_EIP_ALLOC_ID"
  fi
  NAT_GATEWAY_ID="$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET_A_ID" \
    --allocation-id "$NAT_EIP_ALLOC_ID" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat}]" \
    --query "NatGateway.NatGatewayId" --output text)"
  echo "Created NAT Gateway $NAT_GATEWAY_ID, waiting for it to become available (~1-3 min)..."
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GATEWAY_ID"
  echo "NAT Gateway available."
else
  echo "NAT Gateway already exists: $NAT_GATEWAY_ID"
  NAT_EIP_ALLOC_ID="$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_GATEWAY_ID" \
    --query "NatGateways[0].NatGatewayAddresses[0].AllocationId" --output text)"
fi

# --- Private route table ------------------------------------------------------------------------

echo
echo "== Private route table =="
PRIVATE_RTB_ID="$(get_by_tag "RouteTables[0].RouteTableId" aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-private-rtb" "Name=vpc-id,Values=$VPC_ID")"
if [ -z "${PRIVATE_RTB_ID:-}" ]; then
  PRIVATE_RTB_ID="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-rtb}]" \
    --query "RouteTable.RouteTableId" --output text)"
  aws ec2 create-route --route-table-id "$PRIVATE_RTB_ID" --destination-cidr-block "0.0.0.0/0" \
    --nat-gateway-id "$NAT_GATEWAY_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$PRIVATE_RTB_ID" --subnet-id "$PRIVATE_SUBNET_A_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$PRIVATE_RTB_ID" --subnet-id "$PRIVATE_SUBNET_B_ID" >/dev/null
  echo "Created private route table $PRIVATE_RTB_ID (0.0.0.0/0 -> NAT), associated both private subnets."
else
  echo "Private route table already exists: $PRIVATE_RTB_ID"
fi

# --- Persist -------------------------------------------------------------------------------

{
  grep -v -E "^(VPC_ID|IGW_ID|AZ_A|AZ_B|PUBLIC_SUBNET_A_ID|PUBLIC_SUBNET_B_ID|PRIVATE_SUBNET_A_ID|PRIVATE_SUBNET_B_ID|PUBLIC_RTB_ID|PRIVATE_RTB_ID|NAT_GATEWAY_ID|NAT_EIP_ALLOC_ID)=" "$ENV_FILE" 2>/dev/null || true
  cat <<EOF
VPC_ID=$VPC_ID
IGW_ID=$IGW_ID
AZ_A=$AZ_A
AZ_B=$AZ_B
PUBLIC_SUBNET_A_ID=$PUBLIC_SUBNET_A_ID
PUBLIC_SUBNET_B_ID=$PUBLIC_SUBNET_B_ID
PRIVATE_SUBNET_A_ID=$PRIVATE_SUBNET_A_ID
PRIVATE_SUBNET_B_ID=$PRIVATE_SUBNET_B_ID
PUBLIC_RTB_ID=$PUBLIC_RTB_ID
PRIVATE_RTB_ID=$PRIVATE_RTB_ID
NAT_GATEWAY_ID=$NAT_GATEWAY_ID
NAT_EIP_ALLOC_ID=$NAT_EIP_ALLOC_ID
EOF
} > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
echo
echo "Wrote $ENV_FILE"
echo "== Done. =="
