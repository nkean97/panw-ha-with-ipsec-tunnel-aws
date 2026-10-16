#!/usr/bin/env bash
#
# Tear down the VM-Series HA pair and everything Terraform created for it.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

AUTO=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && AUTO=1

if [[ ! -f terraform.tfstate && ! -d .terraform ]]; then
  red "No Terraform state here - nothing to destroy."
  exit 1
fi

bold "==> Resources that will be destroyed"
terraform plan -destroy -input=false -var-file=terraform.tfvars -no-color \
  | grep -E '^\s+# ' || true

if [[ $AUTO -eq 0 ]]; then
  echo
  yellow "This permanently deletes the firewalls, the VPC, the bootstrap bucket,"
  yellow "and releases the Elastic IPs (including the floating service IP)."
  read -r -p "Type 'destroy' to confirm: " REPLY
  [[ "$REPLY" == "destroy" ]] || { echo "Aborted."; exit 1; }
fi

terraform destroy -input=false -auto-approve -var-file=terraform.tfvars

bold "==> Cleaning up local artefacts"
rm -rf .rendered tfplan
yellow "Left in place: ./.secrets (admin password + SSH key). Remove manually when done:"
yellow "  rm -rf .secrets"
