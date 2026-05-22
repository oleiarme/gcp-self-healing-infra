# Спецификация дизайна: Оптимизация Docker Compose в startup_cos.sh

**Дата**: 2026-05-22  
**Статус**: На рассмотрении  

## 1. Введение и цели
Цель изменения — сократить время запуска виртуальной машины на базе Container-Optimized OS (COS) в GCP (в частности, для типа машины `e2-micro`). 
В текущей конфигурации при каждом старте (например, при восстановлении группы управляемых инстансов — MIG) скрипт `startup_cos.sh` скачивает бинарный файл `docker-compose` v2 с GitHub. 
На современных версиях COS встроенная команда `docker compose` уже предустановлена. Мы хотим избежать лишней сетевой задержки и зависимости от GitHub API на этапе старта машины.

## 2. Предлагаемые изменения

### Компонент: `scripts/startup_cos.sh`

Мы заменим жестко закодированную установку и вызовы `docker-compose` на динамическое определение команды.

1. **Определение команды `docker compose`**:
   Скрипт проверяет наличие встроенной команды `docker compose` (в виде docker cli-плагина) или классической `docker-compose`. Если они отсутствуют, скрипт скачивает бинарник во временную директорию (как резервный вариант).

```bash
# ==========================================
# 1.5 Setup Docker Compose Command
# ==========================================
echo "=== Detecting Docker Compose ==="
if docker compose version >/dev/null 2>&1; then
  echo "✅ Native 'docker compose' is available"
  COMPOSE_CMD="docker compose"
elif docker-compose version >/dev/null 2>&1; then
  echo "✅ Native 'docker-compose' is available"
  COMPOSE_CMD="docker-compose"
else
  echo "⏳ No native compose found, falling back to download..."
  COMPOSE_BIN="/var/lib/docker/cli-plugins/docker-compose"
  COMPOSE_VERSION="v2.32.4"
  COMPOSE_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64"
  if [ ! -x "$COMPOSE_BIN" ]; then
    mkdir -p /var/lib/docker/cli-plugins
    retry curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_BIN"
    chmod +x "$COMPOSE_BIN"
    echo "✅ Docker Compose $(${COMPOSE_BIN} version --short) installed"
  fi
  COMPOSE_CMD="$COMPOSE_BIN"
fi
```

2. **Замена вызовов**:
   Все команды вида `/var/lib/docker/cli-plugins/docker-compose` будут заменены на переменную `$COMPOSE_CMD`.

## 3. План верификации

### Ручное тестирование (Manual Verification)
1. Выполнить проверку синтаксиса скрипта через `shellcheck` (запустить локально или в CI):
   ```bash
   shellcheck scripts/startup_cos.sh
   ```
2. Развернуть инфраструктуру в GCP и проверить логи запуска в `/var/log/startup.log` на VM:
   - Убедиться, что выводится строка `✅ Native 'docker compose' is available` и скачивание с GitHub не производится.
