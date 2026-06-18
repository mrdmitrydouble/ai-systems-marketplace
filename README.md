# ai-systems-marketplace

Приватный Claude Code marketplace ризомы **AI Project Intelligence**. Раздаёт **споры** — плагины, которые при запуске разворачивают полноценную систему управления проектом (память, правила, harness, ризоматический паспорт).

Заменяет старую доставку через ZIP: теперь **пропагация = бамп версии + `git push`**. Узлы ризомы получают обновление через `/plugin update`.

## Плагины

| Плагин | Версия | Что делает |
|--------|--------|-----------|
| `project-setup` | 7.0.0 | Инициализация мета-проекта или подопечного; миграция между версиями. Скилл + 6-слойный harness + шаблоны. |

## Установка (получатель споры)

```
# 1. Подключить marketplace (приватный репо — нужен доступ collaborator + gh auth login)
/plugin marketplace add mrdmitrydouble/ai-systems-marketplace

# 2. Установить плагин
/plugin install project-setup@ai-systems-marketplace

# 3. Запустить инициализацию
«Инициализируй мета-проект. Я получил спору от Дмитрия.»
```

Скилл вызывается как `/project-setup:project-setup` или просто по смыслу запроса (model-invoked). При онбординге он копирует `harness/` в `.claude/` целевого проекта — хуки НЕ применяются глобально из плагина (они per-project, ставятся флоу инициализации).

> Подробная инструкция для бизнес-партнёра — внутри плагина: `plugins/project-setup/skills/project-setup/INSTRUCTION.md`.

## Обновление (доставка новой версии)

```
/plugin marketplace update ai-systems-marketplace
/plugin update project-setup@ai-systems-marketplace
```

## Для мейнтейнера (Дмитрий)

**Источник истины** скилла — мета-проект: `Создание ИИ систем/Проект/Документы/Скиллы/project-setup/`. Этот marketplace — артефакт сборки (как раньше ZIP).

**Цикл выпуска новой версии:**
1. Отредактировать скилл в мета-проекте, прогнать ревью (адверсариальное) + smoke-тесты harness.
2. Синхронизировать в плагин: `cp -R "…/project-setup/." plugins/project-setup/skills/project-setup/`
3. Поднять `version` в `plugins/project-setup/.claude-plugin/plugin.json` И в `.claude-plugin/marketplace.json` (держать синхронно — при расхождении plugin.json выигрывает молча).
4. **Линт ASCII-имён:** `bash scripts/check-spore-ascii.sh` → должен быть `exit 0`. Не-ASCII имя файла/папки в `plugins/` → загрузчик отвергает ZIP («invalid characters»). Содержимое файлов кириллицей — можно; имена — только ASCII.
5. `git commit + push`. Узлы получают через `/plugin update`.

**Приватный доступ:** добавить партнёра — Settings → Collaborators в GitHub UI. Для авто-обновления у партнёра должен быть `gh auth login` или `GITHUB_TOKEN` в окружении.

> Genesis ризомы: `650ee649-da20-4e64-a72d-43e14ea146b6` · rhizome_name `AI Project Intelligence`.
