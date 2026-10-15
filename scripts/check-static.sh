#!/usr/bin/env bash
# Статические проверки репозитория БЕЗ выполнения проверяемых скриптов.
#
# Что делает:
#   1. bash -n для всех shell-скриптов (setup-*.sh, tailnet-add);
#   2. shellcheck --severity=warning (если установлен);
#   3. синтаксический разбор setup-windows.ps1 через AST-парсер PowerShell
#      (только парсинг, скрипт НЕ запускается; нужен pwsh);
#   4. PSScriptAnalyzer для setup-windows.ps1 (если установлен модуль);
#   5. грубый поиск случайных секретов (приватные ключи, похожие на настоящие
#      pre-auth ключи Headscale значения).
#
# Запуск:  bash scripts/check-static.sh
#          STRICT=1 bash scripts/check-static.sh   # отсутствие инструментов = ошибка
#
# В CI (см. .github/workflows/static-checks.yml) запускается со STRICT=1:
# shellcheck и PSScriptAnalyzer там устанавливаются явно.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT="${STRICT:-0}"

SH_FILES=(
  "$ROOT/setup-server.sh"
  "$ROOT/setup-linux.sh"
  "$ROOT/setup-mac.sh"
  "$ROOT/tailnet-add"
)
PS_FILES=(
  "$ROOT/setup-windows.ps1"
)

fail=0
warn() { echo "WARN: $*" >&2; }
err()  { echo "FAIL: $*" >&2; fail=1; }
ok()   { echo "OK: $*"; }

missing_tool() { # missing_tool <имя> <для-чего>
  if [ "$STRICT" = "1" ]; then err "инструмент '$1' отсутствует ($2), а STRICT=1"; \
  else warn "инструмент '$1' отсутствует ($2) — пропускаю"; fi
}

# ---------- 1. bash -n ----------
for f in "${SH_FILES[@]}"; do
  if [ ! -f "$f" ]; then err "файл не найден: $f"; continue; fi
  if bash -n "$f"; then ok "bash -n $f"
  else err "bash -n $f"; fi
done

# ---------- 2. shellcheck ----------
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "${SH_FILES[@]}"; then ok "shellcheck --severity=warning"
  else err "shellcheck нашёл замечания (см. выше)"; fi
else
  missing_tool "shellcheck" "линт shell-скриптов"
fi

# ---------- 3+4. PowerShell: AST-разбор и PSScriptAnalyzer (без запуска) ----------
if command -v pwsh >/dev/null 2>&1; then
  for f in "${PS_FILES[@]}"; do
    if pwsh -NoProfile -Command "
\$errs = \$null; \$toks = \$null
[void][System.Management.Automation.Language.Parser]::ParseFile('$f', [ref]\$toks, [ref]\$errs)
foreach (\$e in \$errs) { Write-Output (\$e.Extent.StartLineNumber.ToString() + ': ' + \$e.Message) }
exit \$errs.Count
"; then ok "pwsh AST-парсинг $f (ошибок: 0)"
    else err "pwsh AST-парсинг $f нашёл синтаксические ошибки (см. выше)"; fi
  done
  if pwsh -NoProfile -Command "Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1" | grep -q PSScriptAnalyzer; then
    if pwsh -NoProfile -Command "
Invoke-ScriptAnalyzer -Path '$ROOT/setup-windows.ps1' -ExcludeRule 'PSAvoidUsingWriteHost' -Severity @('Error','Warning') | Format-Table -AutoSize | Out-String | Write-Output
\$r = Invoke-ScriptAnalyzer -Path '$ROOT/setup-windows.ps1' -ExcludeRule 'PSAvoidUsingWriteHost' -Severity @('Error')
exit \$r.Count
"; then ok "PSScriptAnalyzer (Error=0; PSAvoidUsingWriteHost исключён — цвета Write-Host часть UX)"
    else err "PSScriptAnalyzer нашёл ошибки severity=Error (см. выше)"; fi
  else
    missing_tool "PSScriptAnalyzer" "линт PowerShell (Install-Module PSScriptAnalyzer)"
  fi
else
  missing_tool "pwsh" "проверка синтаксиса PowerShell"
fi

# ---------- 5. грубый поиск случайных секретов ----------
# Плейсхолдеры (<ключ>, hskey-auth-..., $KEY) под эти шаблоны не подпадают.
secret_hits=0
check_secret() { # check_secret <grep-pattern> <описание>
  local hits
  hits=$(grep -rEn --exclude-dir=.git --exclude='check-static.sh' -e "$1" "$ROOT" || true)
  if [ -n "$hits" ]; then err "возможный секрет ($2):"; echo "$hits" >&2; secret_hits=1; fi
}
check_secret '-----BEGIN [A-Z ]*PRIVATE KEY-----' "приватный ключ в репозитории"
check_secret 'hskey-[A-Za-z0-9]{12,}' "похоже на настоящий pre-auth ключ Headscale"
[ "$secret_hits" = 0 ] && ok "поиск случайных секретов (приватные ключи, hskey-*)"

if [ "$fail" = 0 ]; then echo "static-checks: PASS"; else echo "static-checks: FAIL" >&2; fi
exit "$fail"
