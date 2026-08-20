#!/bin/bash
# frozen_check.sh — проверка, что frozen-файлы не изменены с последнего коммита.
#
# ЗАЧЕМ: PreToolUse-страж (memory_write_guard) блокирует запись инструментами агента,
# но не ловит правку через Bash (cp/mv/sed) и правку руками. Этот скрипт — второй
# контур: смотрит на ФАКТ в git, а не на намерение.
#
# Frozen zones: Project/Sources/, System/archive/, *_backup*, *_prev*
# EXIT: 0 = чисто; 1 = есть изменения во frozen; 2 = не git-репозиторий.

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT" || exit 2

echo "=== ПРОВЕРКА FROZEN ZONES ==="
echo ""

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "НЕ ПРОВЕРЕНО: это не git-репозиторий (детектор git-производный)"
    exit 2
fi

# --name-only HEAD ловит и staged, и unstaged; untracked ловим отдельно
MODIFIED=$(git diff --name-only HEAD 2>/dev/null | grep -E '(Project/Sources/|System/archive/|_backup|_prev)')
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | grep -E '(Project/Sources/|System/archive/)')

if [ -z "$MODIFIED" ] && [ -z "$UNTRACKED" ]; then
    echo "OK: все frozen zones нетронуты"
    exit 0
fi

echo "НАРУШЕНИЕ FROZEN ZONE:"
[ -n "$MODIFIED" ] && echo "$MODIFIED" | while read -r f; do echo "  - изменён: $f"; done
# Новые файлы в Sources — законный путь пополнения входящих, поэтому это ПРЕДУПРЕЖДЕНИЕ.
[ -n "$UNTRACKED" ] && echo "$UNTRACKED" | while read -r f; do echo "  - новый (не в git): $f"; done
[ -n "$MODIFIED" ] && exit 1
exit 0
