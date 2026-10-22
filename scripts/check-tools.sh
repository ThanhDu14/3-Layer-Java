#!/usr/bin/env bash
# Verify every tool the project needs is installed; print versions, list what is missing.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# molecule shells out to ansible-config, so the venv must be on PATH.
export PATH="$root/.venv/bin:$PATH"
missing=()

check() {
  local name=$1; shift
  local out
  if out=$("$@" 2>&1 | head -1) && [ -n "$out" ]; then
    printf '%-18s %s\n' "$name" "$out"
  else
    missing+=("$name")
  fi
}

check terraform        terraform version
check packer           packer version
check docker           docker --version
check aws              aws --version
check wg               wg --version
check ansible-playbook "$root/.venv/bin/ansible-playbook" --version
check molecule         "$root/.venv/bin/molecule" --version

# Terraform >= 1.10 is required for S3 native state locking (use_lockfile).
if command -v terraform >/dev/null; then
  tf=$(terraform version -json | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])')
  if ! printf '1.10.0\n%s\n' "$tf" | sort -V -C; then
    missing+=("terraform>=1.10 (found $tf)")
  fi
fi

if [ ${#missing[@]} -gt 0 ]; then
  printf 'MISSING: %s\n' "${missing[@]}" >&2
  exit 1
fi
