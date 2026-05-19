---
inclusion: auto
---

# RTK — сжатие вывода команд для экономии токенов

При выполнении shell-команд используй `rtk` как прокси для сжатия вывода. Это экономит 60-90% токенов контекста.

## Правила использования

- Вместо `git status` → `rtk git status`
- Вместо `git diff` → `rtk git diff`
- Вместо `git log` → `rtk git log`
- Вместо `cargo test` / `npm test` / `pytest` → `rtk cargo test` / `rtk npm test` / `rtk pytest`
- Вместо `docker ps` → `rtk docker ps`
- Вместо `docker logs <c>` → `rtk docker logs <c>`
- Для чтения файлов предпочитай встроенные инструменты (read_file), но если нужен `cat` → `rtk read <file>`
- Для поиска предпочитай grep_search, но если нужен `grep` / `rg` → `rtk grep "pattern" .`
- Для листинга директорий предпочитай list_directory, но если нужен `ls` → `rtk ls .`

## Когда НЕ использовать rtk

- Для команд, где нужен полный raw-вывод (например, скачивание файлов, pipe в другую команду)
- Для интерактивных команд
- Когда rtk не установлен (проверь `rtk --version` при первом использовании)

## Флаги

- `-u` / `--ultra-compact` — максимальное сжатие (ASCII-иконки, inline-формат)
- При ошибках rtk сохраняет полный вывод в `~/.local/share/rtk/tee/` — можно прочитать при необходимости
