# Harness — обвязка надёжности (v2)

> v2 (2026-06-11, скилл project-setup v7). v1.0 закрывала только сессионный цикл (4 слоя);
> v2 добавляет стража параллельности, health-скрипт и автопересборку индекса.
> Применяется к Claude Code проектам. Cowork — не поддерживается (нет хуков).

## Зачем

Паттерн P-001 (из ОКО Оценка): Claude объявляет «сессия завершена» без фактического обновления PROGRESS/SYSTEM_LOG/HANDOFF. Повторялся 6+ раз ПОСЛЕ того как был задокументирован — запись об ошибке не предотвращает повторение. Решение — **harness** (Правило 13: «Harness > Memory LLM»): реестр ошибок — диагностика, хук — лечение.

## Шесть слоёв защиты

### 1. `/end` — позитивный путь (slash-команда)
`end.md` → `.claude/commands/end.md`. Протокол закрытия: слияние инбоксов параллельных сессий (шаг 0) → обновить память → валидация → commit+push → флаг.

### 2. Stop-хук — страховка от забывчивости
`stop_guard.sh` → `.claude/hooks/`. Ловит декларацию «сессия завершена/handoff готов» без прохождения `/end` → блокирует (`exit 2`) с инструкцией. Фильтры ложных срабатываний: escape hatch «без wrap-up», активность сессии, флаг корректного закрытия.

### 3. SessionEnd-хук — снапшот при закрытии окна
`session_end_snapshot.sh` → `.claude/hooks/`. При закрытии окна без `/end` (v3, **marker-only** — research 2026-06-16): НЕ мутирует общий git. `git stash create` кладёт durable-снапшот рабочего дерева в БД объектов git БЕЗ смены HEAD/ветки/индекса и БЕЗ записи в stash-list (якорится `refs/wip-snapshot/<sid>` от GC), затем АТОМАРНО (temp + os.replace, строго последним) пишется маркер `.claude/.session_incomplete.json` с полем `snapshot_ref`. Данные остаются в рабочем дереве как у IDE-autosave (JetBrains Local History / VS Code Hot Exit) → **main не трогается, team-безопасно**. При чистом дереве маркер НЕ пишется; снимает свой маркер из реестра живых сессий. (Прошлая версия делала WIP-коммит в main → накопила 24+ мусорных коммита и цикл-инцидент — отказались.)

### 4. SessionStart-хук — recovery + гигиена старта
`session_start_recovery.sh` → `.claude/hooks/`. При старте: (а) если есть `.session_incomplete.json` — через `additionalContext` принудительно инструктирует Claude восстановить wrap-up (шаг обработки прерванной сессии в STARTUP — backup); (б) пишет маркер своей сессии в реестр `.claude/live_sessions/` и чистит протухшие (>2ч); (в) авто-убирает stale `.git/index.lock` (>30 мин без живого git-процесса).

### 5. PreToolUse-страж — frozen zones + параллельность
`memory_write_guard.sh` → `.claude/hooks/` (matcher `Edit|Write`). Две функции:
- **Frozen zones:** физический блок записи в `Project/Sources/`, `System/archive/`, `*_backup*` (для легитимной архивации — Bash cp/mv).
- **Страж параллельности (v3):** при записи в общие файлы памяти при живой ЧУЖОЙ live-сессии — deny с инструкцией агенту записать дельту в `System/memory/inbox_sessions/` (заголовок «## для [файл]»). Слияние — `/end` шаг 0 или шаг слияния инбоксов в STARTUP. Владельцу — ноль кнопок. Scheduled-прогоны исключены по label (бесконфликтны по дизайну).

### 6. quick_health.sh — детерминированные метрики
`quick_health.sh` → `System/scripts/`. Запускается в STARTUP: лимиты строк файлов памяти, наличие обязательных файлов/папок, git-статус, свежесть HANDOFF, секция `[HARNESS]` (stale lock, chmod 444, неслитые инбоксы) → PID-метрики + статус ЗЕЛЁНЫЙ/ЖЁЛТЫЙ/КРАСНЫЙ. Факты вместо самоописания агента.

**Инфраструктура слоёв:** реестр живых сессий `.claude/live_sessions/*.marker` (пишет SessionStart, снимает SessionEnd) + личные инбоксы `System/memory/inbox_sessions/`.

**Дополнительно:** `rebuild_file_index.sh` → `System/scripts/` — автопересборка FILE_INDEX.md (ручное ведение реестров протухает молча; у меты индекс был заморожен 72 дня).

## Принципы дизайна harness (выстраданы полевыми итерациями v1→v3)

1. **Адресат реакции — агент, не владелец.** Deny с инструкцией агенту лучше ask-кнопки владельцу: беспокоить человека только решениями, которые агенту не по силам.
2. **Мерь предмет риска, не прокси.** Таймеры активности ненадёжны (research-сессия молчит полчаса, оставаясь живой) — живость определяется по транскрипту, конфликт записи решается архитектурой, а не угадыванием.
3. **Сначала «ошибка невозможна», потом «детектить».** Развести записи по инбоксам (затирание стало невозможным) лучше, чем ловить опасный момент.
4. **3-5 пользовательских сценариев ДО выкатки** — включая негативные («не перегибает?») и граничные. Тест на exit-коды ≠ тест на UX.
5. **Хук не подавляет ошибки.** `|| true` с рапортом об успехе — антипаттерн; статус всегда честный.
6. **Хронический паттерн (повторился ≥2 раз при наличии правила) → хук.** Реестр ошибок — диагностика, хук — лечение.

## Установка в проект

> ⚠️ **Путь к скиллу (C5):** команды `cp` ниже используют `$SKILL_DIR` — АБСОЛЮТНЫЙ путь к папке установленного скилла. Относительный `harness/` НЕ работает: рабочая папка агента = корень нового проекта, а не папка скилла. Определи путь один раз:
> ```bash
> SKILL_DIR=$(dirname "$(find ~ -name SKILL.md -path '*project-setup*' 2>/dev/null | head -1)")
> ls "$SKILL_DIR/harness/"   # должен показать *.sh и end.md — иначе путь не найден
> ```

1. Структура:
   ```bash
   mkdir -p .claude/hooks .claude/commands .claude/live_sessions System/scripts System/memory/inbox_sessions
   touch System/memory/inbox_sessions/.gitkeep
   ```

2. Файлы (из `$SKILL_DIR/harness/`):
   ```bash
   cp "$SKILL_DIR/harness/end.md" .claude/commands/end.md
   cp "$SKILL_DIR/harness/"{stop_guard,session_end_snapshot,session_start_recovery,memory_write_guard}.sh .claude/hooks/
   cp "$SKILL_DIR/harness/"{close_session_check,quick_health,rebuild_file_index}.sh System/scripts/
   chmod +x .claude/hooks/*.sh System/scripts/*.sh
   # ПРОВЕРКА после копирования (C5/C7): 4 хука на месте?
   ls .claude/hooks/*.sh   # пусто/<4 файлов = установка не прошла → НЕ объявляй harness установленным
   # Слой 1 harness — физическая защита body-файлов (quick_health проверяет эти 444):
   chmod 444 CLAUDE.md System/memory/RULES.md System/memory/ARCH_PRINCIPLES.md
   ```
   (Для правки body-файла: `chmod +w <файл>` → правка → `chmod 444 <файл>`. Облачный синк сбрасывает права — quick_health тогда алертит.)

3. `.claude/settings.json` — слить секции **PreToolUse + Stop + SessionEnd + SessionStart** из `settings.hooks.snippet.json`. Если был старый хук frozen zones (inline-python) — заменить на memory_write_guard.
   > Оба snippet'а — **чистый валидный JSON** (без `_comment`-ключей, дефект C6 устранён): если `.claude/settings.json` ещё нет — можно скопировать snippet целиком как стартовый файл; если есть — JSON-merge нужных секций (не заменять весь файл: там могут быть другие ключи проекта). Лишние верхнеуровневые `_*`-ключи делают settings.json невалидным/игнорируемым — поэтому пояснения держим здесь, а не в самих .json.

3b. **АВТОНОМНОСТЬ scheduled-задач** — слить блок `permissions` из `settings.permissions.snippet.json` (широкий `allow` + `deny` на frozen/секреты). **deny имеет приоритет над allow** → frozen-зоны и секреты защищены даже при широком allow. Без `allow` фоновая scheduled-задача виснет на промпте «разрешить Edit/Bash?», которого владелец не видит → задача молча не работает. ⚠️ Вставляет **владелец вручную** (редактор или Customize/UI): агент НЕ может писать широкие allow-правила в активный settings.json сам — это самоэскалация прав на исполнение кода, harness её hard-блокирует (как NDA-блок), и это корректно. Проверено боем: deny-only конфиг AiGid → задача `aigid-daily-audit` зависала на «Allow edit SYSTEM_LOG.md?».
   > **Кросс-проектное чтение (C1):** если проект ПОДОПЕЧНЫЙ и его scheduled-задачи читают папку меты (PROJECT_PATHS/VERSION-маяки), добавь в `permissions` ключ `"additionalDirectories": ["<АБСОЛЮТНЫЙ путь к папке меты>"]`. Без него фоновая задача, читающая вне корня проекта, виснет на промпте. Путь машинно-специфичен → в шаблон-snippet намеренно не зашит, подставляется при установке.

4. `System/memory/STARTUP.md` — шаги обработки `.session_incomplete.json` и слияния `inbox_sessions/` (в шаблоне STARTUP v7 из STRUCTURES.md это шаги 0.2 и 0.3 — уже на месте).

5. `System/memory/RULES.md` — правило закрытия сессии: триггер-слова → `/end`.

6. Проверка: `bash System/scripts/quick_health.sh` (метрики выводятся) и `bash System/scripts/close_session_check.sh` (FAIL в начале сессии — ожидаемо).

## Адаптация под проект

- `quick_health.sh`: лимиты строк и список обязательных файлов — в начале скрипта, подстрой под проект.
- `close_session_check.sh`: блок 3 (лимиты) и `WINDOW_MINUTES=240` — подбираются.
- `stop_guard.sh`: ключевые слова `CLOSURE_RE` — расширить под язык/стиль пользователя.
- **Team-проекты:** SessionEnd v3 marker-only НЕ коммитит вообще (durable `git stash create` без мутации main) → team-безопасен из коробки, отдельная ветка не нужна. Память разделена по участникам — страж параллельности всё равно нужен (общие TRACKER/CONTEXT/shared_board).
- Маркер `.session_incomplete.json` можно добавить в `.gitignore`, если WIP-коммиты маркера шумят в истории.

## Проверка при старте новой сессии

Шаги обработки маркера и слияния инбоксов в STARTUP — обязательны. Без них SessionEnd-маркер и инбоксы создаются, но не обрабатываются (write-only — главный анти-паттерн памяти).
