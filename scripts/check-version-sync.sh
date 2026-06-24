#!/bin/bash
# check-version-sync.sh — отображаемая версия (major) в заголовках скилла должна
# совпадать с plugin.json. Класс бага (сессия 55): номер версии дублируется в тексте
# заголовков И в манифесте; при бампе обновили манифест, а заголовки «(vN)» забыли →
# в "Отобразить скилл" видна старая версия. Poka-yoke: запускать при каждом релизе.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLDIR="$ROOT/plugins/project-setup/skills/project-setup"
MANIFEST="$ROOT/plugins/project-setup/.claude-plugin/plugin.json"

# major из plugin.json: "8.0.1" → 8
MAJOR=$(grep -m1 '"version"' "$MANIFEST" | grep -oE '[0-9]+' | head -1)

FAIL=0
# заголовки с «(vN)» — это «отображаемая версия скилла»
for f in SKILL.md MIGRATION.md INSTRUCTION.md; do
    HDR=$(head -10 "$SKILLDIR/$f" | grep -m1 -oE '\(v[0-9]+\)' | grep -oE '[0-9]+' || echo "?")
    if [ "$HDR" != "$MAJOR" ]; then
        echo "  ❌ $f: заголовок (v$HDR) ≠ plugin.json major v$MAJOR"
        FAIL=1
    fi
done
# STRUCTURES.md заголовок вида «STRUCTURES vN:»
SHDR=$(head -3 "$SKILLDIR/STRUCTURES.md" | grep -m1 -oE 'STRUCTURES v[0-9]+' | grep -oE '[0-9]+' || echo "?")
[ "$SHDR" != "$MAJOR" ] && { echo "  ❌ STRUCTURES.md: 'STRUCTURES v$SHDR' ≠ v$MAJOR"; FAIL=1; }
# шаблон VERSION.md, который скилл создаёт новому проекту
TMPL=$(grep -m1 -E 'skill_version:\s*v[0-9]+' "$SKILLDIR/STRUCTURES.md" | grep -oE '[0-9]+' || echo "?")
[ "$TMPL" != "$MAJOR" ] && { echo "  ❌ STRUCTURES.md skill_version template: v$TMPL ≠ v$MAJOR (новые проекты родятся как v$TMPL)"; FAIL=1; }

if [ "$FAIL" = 0 ]; then
    echo "✅ версия синхронна: plugin.json major=v$MAJOR == все заголовки скилла + шаблон"
    exit 0
else
    echo "→ обнови заголовки на (v$MAJOR) перед публикацией."
    exit 1
fi
