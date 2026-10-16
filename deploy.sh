#!/usr/bin/env bash
#
# Deploy a Palo Alto Networks VM-Series Active/Passive HA pair into a new AWS
# VPC in us-east-2, plus (deploy_branch = true) a branch VPC with a third
# firewall and an IPsec tunnel to the pair, then configure and verify it all.
#
#   ./deploy.sh              plan, confirm, apply, configure, verify
#   ./deploy.sh --plan-only  show the plan and stop
#   ./deploy.sh --yes        skip the confirmation prompt
#   ./deploy.sh --verify     re-run the post-deploy checks only
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

TFVARS="terraform.tfvars"
PLAN_ONLY=0
AUTO_APPROVE=0
VERIFY_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --plan-only) PLAN_ONLY=1 ;;
    --yes|-y)    AUTO_APPROVE=1 ;;
    --verify)    VERIFY_ONLY=1 ;;
    -h|--help)   sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
die()   { red "ERROR: $*"; exit 1; }

###############################################################################
bold "==> Checking prerequisites"
###############################################################################
for tool in terraform aws python3 curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done
printf '  terraform %s\n' "$(terraform version -json | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])')"
printf '  aws-cli   %s\n' "$(aws --version 2>&1 | cut -d' ' -f1)"
printf '  python3   %s\n' "$(python3 -c 'import platform;print(platform.python_version())')"

# The sha512-crypt implementation produces the PAN-OS admin password hash;
# a silent bug there would lock you out of the firewalls.
python3 scripts/sha512_crypt.py --selftest >/dev/null \
  || die "sha512-crypt self-test failed - refusing to build a bootstrap config"
green "  password hashing self-test passed"

# Optional: only needed for an interactive shell on the test workloads
# ('aws ssm start-session'). Everything else, including the failover test,
# works without it -- 'aws ssm send-command' is a plain API call.
if ! command -v session-manager-plugin >/dev/null 2>&1; then
  yellow "  session-manager-plugin not installed (optional)"
  yellow "    Needed only for: aws ssm start-session --target <workload-id>"
  yellow "    Install with:    brew install --cask session-manager-plugin"
  yellow "    See DEPLOYMENT-GUIDE.md for the no-plugin alternative."
fi

###############################################################################
bold "==> Checking AWS access"
###############################################################################
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || die "No usable AWS credentials. Run 'aws configure' or 'aws sso login'."
ACCOUNT=$(echo "$CALLER" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Account"])')
ARN=$(echo "$CALLER" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Arn"])')
printf '  account %s\n  identity %s\n' "$ACCOUNT" "$ARN"

REGION=$(python3 - <<'PY'
import os, re
region = "us-east-2"
try:
    for line in open("terraform.tfvars"):
        m = re.match(r'\s*region\s*=\s*"([^"]+)"', line)
        if m:
            region = m.group(1)
except FileNotFoundError:
    pass
print(region)
PY
)
printf '  region  %s\n' "$REGION"

if [[ $VERIFY_ONLY -eq 1 ]]; then
  bold "==> Running post-deploy verification only"
  exec python3 scripts/configure.py --verify-only
fi

###############################################################################
bold "==> Checking the VM-Series Marketplace subscription"
###############################################################################
LICENSE_TYPE=$(python3 - <<'PY'
import re
lt = "byol"
try:
    for line in open("terraform.tfvars"):
        m = re.match(r'\s*license_type\s*=\s*"([^"]+)"', line)
        if m:
            lt = m.group(1)
except FileNotFoundError:
    pass
print(lt)
PY
)
AMI_FILTER=$(python3 - <<'PY2'
import re
val = "PA-VM-AWS-11.2.15-*"
try:
    m = re.search(r'panos_version_filter\s*=\s*"([^"]+)"', open("terraform.tfvars").read())
    if m:
        val = m.group(1)
except FileNotFoundError:
    pass
print(val)
PY2
)
INSTANCE_TYPE=$(python3 - <<'PY2'
import re
val = "m5.4xlarge"
try:
    # Anchored to line start: an unanchored "instance_type" also matches
    # "workload_instance_type" and would size the quota check off t3.micro.
    m = re.search(r'^\s*instance_type\s*=\s*"([^"]+)"',
                  open("terraform.tfvars").read(), re.M)
    if m:
        val = m.group(1)
except FileNotFoundError:
    pass
print(val)
PY2
)
# macOS still ships bash 3.2, which has no associative arrays - keep this
# portable with a case lookup.
case "$LICENSE_TYPE" in
  byol)
    PC=6njl1pau431dv1qxipg63mvah
    SUBSCRIBE_URL="https://aws.amazon.com/marketplace/pp/prodview-ddnbdcqoa6q6a" ;;
  bundle1)
    PC=e9yfvyj3uag5uo5j2hjikv74n
    SUBSCRIBE_URL="https://aws.amazon.com/marketplace/pp/prodview-mhhwa5mzl45nk" ;;
  bundle2)
    PC=hd44w1chf26uv4p52cdynb2o
    SUBSCRIBE_URL="https://aws.amazon.com/marketplace/pp/prodview-ekvxpipksnft6" ;;
  *)
    die "unknown license_type '$LICENSE_TYPE' (expected byol, bundle1 or bundle2)" ;;
esac

AMI_ID=$(aws ec2 describe-images --region "$REGION" --owners aws-marketplace \
  --filters "Name=product-code,Values=$PC" "Name=name,Values=$AMI_FILTER" \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text 2>/dev/null || echo None)
[[ "$AMI_ID" != "None" && -n "$AMI_ID" ]] \
  || die "No VM-Series $LICENSE_TYPE AMI matching '$AMI_FILTER' in $REGION."
printf '  AMI %s (license_type=%s)\n' "$AMI_ID" "$LICENSE_TYPE"

# Real entitlement check: a RunInstances dry-run performs the Marketplace
# opt-in validation, so OptInRequired here means "not subscribed" rather than
# us guessing from AMI visibility (marketplace AMIs are visible regardless).
DRY=$(aws ec2 run-instances --region "$REGION" --dry-run \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --count 1 2>&1 || true)
case "$DRY" in
  *DryRunOperation*)
    green "  Marketplace subscription active for $LICENSE_TYPE" ;;
  *OptInRequired*|*not\ subscribed*)
    red   "  This account is NOT subscribed to the VM-Series $LICENSE_TYPE listing."
    red   "  Accept the terms once here, then re-run:"
    red   "    $SUBSCRIBE_URL"
    die   "Marketplace subscription required." ;;
  *UnauthorizedOperation*)
    yellow "  Could not verify the subscription: this identity lacks ec2:RunInstances"
    yellow "  for the dry-run. Continuing; apply will fail with OptInRequired if"
    yellow "  the account is not subscribed." ;;
  *)
    yellow "  Subscription check inconclusive: ${DRY:0:160}"
    yellow "  Continuing; apply will fail with OptInRequired if not subscribed." ;;
esac

###############################################################################
bold "==> Checking the EC2 vCPU quota"
###############################################################################
# The dry-run above launches ONE instance, so it passes even when the account
# cannot fit the whole stack. New accounts default to 5 vCPU for the standard
# on-demand family, and this build needs 10 -- so check the aggregate here
# rather than discovering it halfway through 'terraform apply'.
WORKLOAD_TYPE=$(python3 - <<'PY3'
import re
val = "t3.micro"
try:
    m = re.search(r'workload_instance_type\s*=\s*"([^"]+)"', open("terraform.tfvars").read())
    if m: val = m.group(1)
except FileNotFoundError:
    pass
print(val)
PY3
)
WANT_WORKLOADS=$(python3 - <<'PY4'
import re
val = "true"
try:
    m = re.search(r'deploy_test_workloads\s*=\s*(true|false)', open("terraform.tfvars").read())
    if m: val = m.group(1)
except FileNotFoundError:
    pass
print(val)
PY4
)
WANT_BRANCH=$(python3 - <<'PY5'
import re
val = "true"
try:
    m = re.search(r'^\s*deploy_branch\s*=\s*(true|false)', open("terraform.tfvars").read(), re.M)
    if m: val = m.group(1)
except FileNotFoundError:
    pass
print(val)
PY5
)
BRANCH_TYPE=$(python3 - <<PY6
import re
val = "$INSTANCE_TYPE"
try:
    m = re.search(r'^\s*branch_instance_type\s*=\s*"([^"]+)"', open("terraform.tfvars").read(), re.M)
    if m: val = m.group(1)
except FileNotFoundError:
    pass
print(val)
PY6
)

vcpus_of() {
  aws ec2 describe-instance-types --region "$REGION" --instance-types "$1" \
    --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null || echo ""
}
FW_VCPU=$(vcpus_of "$INSTANCE_TYPE")
WL_VCPU=$(vcpus_of "$WORKLOAD_TYPE")

if [[ -z "$FW_VCPU" || "$FW_VCPU" == "None" ]]; then
  yellow "  Could not read vCPU counts; skipping the quota check."
else
  NEED=$(( FW_VCPU * 2 ))
  WORKLOADS=2
  NEED_DESC="2 x $INSTANCE_TYPE"
  if [[ "$WANT_BRANCH" == "true" ]]; then
    BR_VCPU=$(vcpus_of "$BRANCH_TYPE")
    [[ -n "$BR_VCPU" && "$BR_VCPU" != "None" ]] && NEED=$(( NEED + BR_VCPU ))
    WORKLOADS=3
    NEED_DESC="$NEED_DESC + branch $BRANCH_TYPE"
  fi
  if [[ "$WANT_WORKLOADS" == "true" && -n "$WL_VCPU" && "$WL_VCPU" != "None" ]]; then
    NEED=$(( NEED + WL_VCPU * WORKLOADS ))
    NEED_DESC="$NEED_DESC + $WORKLOADS x $WORKLOAD_TYPE"
  fi

  QUOTA=$(aws service-quotas get-service-quota --region "$REGION" \
    --service-code ec2 --quota-code L-1216C47A \
    --query 'Quota.Value' --output text 2>/dev/null || echo "")

  # Standard-family vCPUs already running/pending in this region, NOT
  # counting this stack's own instances (tag Project = name_prefix): on a
  # re-run after a partial apply they are already part of NEED.
  NAME_PREFIX=$(sed -nE 's/^[[:space:]]*name_prefix[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TFVARS" 2>/dev/null | tail -1)
  NAME_PREFIX=${NAME_PREFIX:-panw-ha}
  IN_USE=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].[InstanceType,CpuOptions.CoreCount,CpuOptions.ThreadsPerCore,Tags[?Key==`Project`]|[0].Value]' \
    --output text 2>/dev/null \
    | awk -v p="$NAME_PREFIX" '$1 ~ /^[acdhimrtz]/ && $4 != p {s += ($2=="None"?0:$2) * ($3=="None"?1:$3)} END {print s+0}')

  if [[ -z "$QUOTA" || "$QUOTA" == "None" ]]; then
    yellow "  Could not read the vCPU quota (needs servicequotas:GetServiceQuota)."
    yellow "  This deployment needs $NEED vCPUs; the default for a new account is 5."
  else
    QUOTA_INT=${QUOTA%.*}
    printf '  need %s vCPUs (%s), in use %s, quota %s\n' \
      "$NEED" "$NEED_DESC" "$IN_USE" "$QUOTA_INT"

    if (( NEED + IN_USE > QUOTA_INT )); then
      red "  QUOTA TOO LOW. The apply will fail with VcpuLimitExceeded partway through."
      red ""
      red "  This account allows $QUOTA_INT vCPUs of standard on-demand capacity in"
      red "  $REGION, and this deployment needs $NEED. Request an increase:"
      red ""
      red "    aws service-quotas request-service-quota-increase \\"
      red "      --region $REGION --service-code ec2 \\"
      red "      --quota-code L-1216C47A --desired-value 64"
      red ""
      red "  Or in the console: Service Quotas > AWS services > Amazon EC2 >"
      red "  'Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances'"
      red ""
      red "  Approval is usually minutes, sometimes a few hours. Check status with:"
      red "    aws service-quotas list-requested-service-quota-change-history-by-quota \\"
      red "      --region $REGION --service-code ec2 --quota-code L-1216C47A"
      red ""
      red "  Note: an HA pair needs 2 x $INSTANCE_TYPE = $(( FW_VCPU * 2 )) vCPUs at minimum."
      red "  Setting deploy_test_workloads = false saves $(( WL_VCPU * WORKLOADS )) but is not enough on its own."
      [[ "$WANT_BRANCH" == "true" ]] && red "  Setting deploy_branch = false saves the branch firewall's ${BR_VCPU:-?} vCPUs."
      die "Insufficient vCPU quota."
    fi
    green "  vCPU quota is sufficient"
  fi
fi

###############################################################################
bold "==> Preparing terraform.tfvars"
###############################################################################
if [[ ! -f $TFVARS ]]; then
  MYIP=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]') \
    || die "Could not detect your public IP; create $TFVARS manually from terraform.tfvars.example"
  cat > "$TFVARS" <<EOF
# Generated by deploy.sh on first run. Edit freely and re-run.
region             = "$REGION"
mgmt_allowed_cidrs = ["$MYIP/32"]

# BYOL. Paste your auth code from the Palo Alto CSP (this file is git-ignored).
license_type     = "byol"
panos_auth_codes = "YOUR-AUTH-CODE"
EOF
  green "  wrote $TFVARS (management locked to $MYIP/32)"
else
  printf '  using existing %s\n' "$TFVARS"
fi

# A BYOL firewall without an auth code boots but never licenses, which only
# shows up much later as a firewall that passes no traffic.
if [[ $LICENSE_TYPE == byol ]]; then
  AUTH_CODE=$(sed -nE 's/^[[:space:]]*panos_auth_codes[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$TFVARS" | tail -1)
  [[ -n $AUTH_CODE && $AUTH_CODE != YOUR-AUTH-CODE ]] \
    || die "license_type is byol but panos_auth_codes is not set in $TFVARS -- add your auth code and re-run"
  if [[ $WANT_BRANCH == true ]] && ! grep -qE '^[[:space:]]*branch_auth_codes[[:space:]]*=[[:space:]]*"[^"]+"' "$TFVARS"; then
    yellow "  NOTE: no branch_auth_codes set; the branch firewall reuses panos_auth_codes,"
    yellow "        so that code must cover THREE instances (the pair plus the branch)."
  fi
fi

# Say it out loud. An open management plane is a legitimate choice for a
# short-lived lab, but it should never be something you discover later.
if grep -qE '^[^#]*mgmt_allowed_cidrs.*0\.0\.0\.0/0' "$TFVARS"; then
  yellow "  WARNING: mgmt_allowed_cidrs is 0.0.0.0/0 -- the firewall web UI and"
  yellow "           XML API are reachable from the entire internet, and PAN-OS"
  yellow "           will be built with no permitted-ip restriction at all."
  yellow "           Fine for a short-lived lab. Narrow it before anything else."
fi

###############################################################################
bold "==> terraform init"
###############################################################################
terraform init -input=false -upgrade

bold "==> terraform validate"
terraform validate

###############################################################################
bold "==> terraform plan"
###############################################################################
terraform plan -input=false -var-file="$TFVARS" -out=tfplan

if [[ $PLAN_ONLY -eq 1 ]]; then
  green "Plan written to ./tfplan. Apply with: terraform apply tfplan"
  exit 0
fi

if [[ $AUTO_APPROVE -eq 0 ]]; then
  echo
  yellow "About to create a VM-Series HA pair in $REGION of account $ACCOUNT."
  if [[ "$WANT_BRANCH" == "true" ]]; then
    yellow "Plus a branch VPC with a third firewall ($BRANCH_TYPE) and an IPsec tunnel."
    yellow "Three firewalls plus EIPs; this costs real money per hour."
  else
    yellow "Two $INSTANCE_TYPE firewalls plus EIPs; this costs real money per hour."
  fi
  read -r -p "Type 'yes' to continue: " REPLY
  [[ "$REPLY" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

###############################################################################
bold "==> terraform apply"
###############################################################################
terraform apply -input=false tfplan
rm -f tfplan

###############################################################################
bold "==> Post-deploy configuration and verification"
###############################################################################
yellow "VM-Series takes 10-20 minutes to boot and apply its bootstrap config."
yellow "configure.py polls the management API until it answers."
echo

python3 scripts/configure.py || {
  red "Post-deploy configuration reported problems - see above."
  red "Infrastructure is up. Finish configuration with 'python3 scripts/configure.py'"
  red "(safe to re-run); './deploy.sh --verify' only checks, it changes nothing."
  exit 1
}

echo
green "============================================================"
green " Deployment complete."
green "============================================================"
terraform output
echo
bold "Credentials"
printf '  username : %s\n' "$(terraform output -raw admin_username)"
printf '  password : %s\n' "$(cat .secrets/admin_password)"
printf '  ssh key  : %s\n' "$(terraform output -raw ssh_private_key_file)"
echo
bold "Next steps"
cat <<'EOT'
  Open the test web page (shows the private IP of the server that answered):
    http://<floating_service_ip>/

  Test the data path from a workload:
    aws ssm start-session --target <workload_instance_id>
    curl -s https://checkip.amazonaws.com     # should show the floating IP

  Test failover (run it again to fail back):
    python3 scripts/configure.py --failover-test

  Branch site (if deployed): from a pair workload, reach the branch over IPsec:
    curl -s http://<branch_workload_private_ip>/ip
  The pre-shared key is in .secrets/ipsec_psk.

  After changing policy on the active firewall, copy it to the passive one:
    python3 scripts/configure.py --sync-config

  Step-by-step guide and troubleshooting: DEPLOYMENT-GUIDE.md

  Tear everything down:
    ./destroy.sh
EOT
