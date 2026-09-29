#!/usr/bin/env bash
set -euo pipefail

required=(
  "docs/10_현대형_무한성장_GDD.md"
  "docs/11_현대형_구현계약.md"
  "docs/12_구현_QA_증거.md"
)

for path in "${required[@]}"; do
  test -s "$path" || { echo "Missing required document: $path" >&2; exit 1; }
done

rg -q "강제 엔딩 없음" docs/10_현대형_무한성장_GDD.md
rg -q "AC-UI-06" docs/11_현대형_구현계약.md
rg -q "244/244 PASS" docs/12_구현_QA_증거.md
rg -q "남은 미구현 항목은 없다" docs/12_구현_QA_증거.md
echo "Documentation contract passed."
