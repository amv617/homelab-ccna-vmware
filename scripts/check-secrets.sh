#!/usr/bin/env bash
# Scan the repo for things that should never be committed:
# MAC addresses, IOS password hashes, RSA key material, SNMP communities.
# Usage: ./scripts/check-secrets.sh   (exit code 1 if anything is found)
# Tip: run it as a git pre-commit hook:
#   ln -s ../../scripts/check-secrets.sh .git/hooks/pre-commit

set -u
cd "$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/.." && pwd))" || exit 2

found=0
check() {
  local label="$1" pattern="$2"
  local hits
  hits=$(grep -rInE --exclude-dir=.git --exclude-dir=live-configs \
         --exclude=check-secrets.sh "$pattern" . 2>/dev/null)
  if [ -n "$hits" ]; then
    echo "== $label =="
    echo "$hits"
    echo
    found=1
  fi
}

# Cisco dotted MAC (aaaa.bbbb.cccc) and colon/dash MACs (aa:bb:cc:dd:ee:ff)
check "MAC address (Cisco format)" '\b[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\b'
check "MAC address (colon/dash)"   '\b([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}\b'
# IOS secrets: type 5/8/9 hashes and type 7 reversible passwords
check "IOS secret hash"            '(secret|password) [0-9] [^<[:space:]]+'
check "Type 9/8/5 hash string"     '\$(9|8|1)\$[A-Za-z0-9./]{4,}'
# Key material
check "Private key block"          'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
check "IOS RSA pubkey dump"        'ssh-rsa AAAA[A-Za-z0-9+/]{40,}'
check "Certificate chain"          'certificate (self-signed|ca) [0-9A-F]+'
# SNMP and other shared secrets
check "SNMP community"             'snmp-server community [^<[:space:]]+'
check "Key string"                 'key-string [^<[:space:]]+'

if [ "$found" -eq 0 ]; then
  echo "No secrets or device identifiers found."
fi
exit "$found"
