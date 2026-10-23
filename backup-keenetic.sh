#!/bin/sh
# ============================================================
# Бэкап Keenetic + Entware
# ============================================================
# Что сохраняется:
#   - /opt/etc/           (конфиги: 3proxy, скрипты, amnezia-routes.txt, ifstatechanged.d)
#   - /opt/tmp/           (только *.sh, *.txt, *.json — скрипты и списки)
#   - список пакетов opkg (opkg list-installed + список для переустановки)
#   - конфиги opkg (репозитории)
#   - crontab
#   - история команд shell (ash/bash history)
#   - логи 3proxy и amnezia-routes (последние 30 дней)
#   - running-config KeeneticOS (через ndmq/ndmc)
#   - версия прошивки KeeneticOS (ndmc -c "show version")
#   - лог самого бэкапа (backup-keenetic.log)
#
# Использование:
#   /opt/etc/backup-keenetic.sh           — сделать бэкап
#   /opt/etc/backup-keenetic.sh --clean   — почистить старые бэкапы
#   /opt/etc/backup-keenetic.sh --list    — показать бэкапы
# ============================================================

# ---------- Настройки ----------
BACKUP_ROOT="/opt/tmp/backup"
KEEP_COUNT=7                    # сколько последних бэкапов хранить
DATE_TAG=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$DATE_TAG"
LOG_DIR="/opt/var/log"
LOG_FILE="$LOG_DIR/backup-keenetic.log"
MAX_LOG_SIZE=1048576            # 1 MB, потом ротация
EXCLUDE_PATTERNS="--exclude=*.log --exclude=*/cache/* --exclude=*/tmp/* --exclude=*.pid"

# ---------- Функции ----------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_ok() {
    log "[OK]   $1"
}

log_warn() {
    log "[WARN] $1"
}

log_err() {
    log "[ERR]  $1"
}

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$SIZE" -gt "$MAX_LOG_SIZE" ]; then
            mv "$LOG_FILE" "$LOG_FILE.old"
            log "Лог ротирован (был $SIZE байт)"
        fi
    fi
}

clean_old_backups() {
    log "Очистка старых бэкапов (оставляю $KEEP_COUNT последних)"
    if [ ! -d "$BACKUP_ROOT" ]; then
        log_warn "Папка $BACKUP_ROOT не существует"
        return
    fi
    COUNT=$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | wc -l)
    log "Найдено бэкапов: $COUNT"
    if [ "$COUNT" -le "$KEEP_COUNT" ]; then
        log_ok "Чистка не требуется"
        return
    fi
    REMOVE_COUNT=$((COUNT - KEEP_COUNT))
    log "Удаляю $REMOVE_COUNT старых бэкапов"
    ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | head -n "$REMOVE_COUNT" | while read -r dir; do
        log "  Удаляю: $dir"
        rm -rf "$dir"
    done
    log_ok "Очистка завершена"
}

list_backups() {
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "Папка $BACKUP_ROOT не существует"
        return
    fi
    echo "Бэкапы в $BACKUP_ROOT:"
    ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | while read -r dir; do
        SIZE=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        echo "  $(basename "$dir")  ($SIZE)"
    done
}

# ---------- Обработка аргументов ----------
case "$1" in
    --clean)
        rotate_log
        clean_old_backups
        exit 0
        ;;
    --list)
        list_backups
        exit 0
        ;;
    --help|-h)
        echo "Использование: $0 [--clean|--list|--help]"
        echo "  без аргументов — сделать бэкап"
        echo "  --clean       — удалить старые бэкапы"
        echo "  --list        — показать список бэкапов"
        exit 0
        ;;
esac

# ---------- Старт ----------
rotate_log
log "============================================================"
log "СТАРТ БЭКАПА: $DATE_TAG"
log "============================================================"

# Создаём папку бэкапа
mkdir -p "$BACKUP_DIR" || {
    log_err "Не могу создать $BACKUP_DIR"
    exit 1
}
log_ok "Создана папка: $BACKUP_DIR"

# ---------- 1. /opt/etc/ ----------
log "--- 1. Бэкап /opt/etc/ ---"
if [ -d /opt/etc ]; then
    TAR_ETC="$BACKUP_DIR/opt-etc.tar.gz"
    if tar -czf "$TAR_ETC" $EXCLUDE_PATTERNS -C /opt etc 2>>"$LOG_FILE"; then
        SIZE=$(du -h "$TAR_ETC" | awk '{print $1}')
        log_ok "/opt/etc/ сохранён ($SIZE)"
    else
        log_err "Ошибка бэкапа /opt/etc/"
    fi
else
    log_warn "/opt/etc/ не существует — пропускаю"
fi

# ---------- 2. /opt/tmp/ (только скрипты и списки) ----------
log "--- 2. Бэкап /opt/tmp/ (скрипты и списки) ---"
if [ -d /opt/tmp ]; then
    TAR_TMP="$BACKUP_DIR/opt-tmp-scripts.tar.gz"
    # Сохраняем только *.sh, *.txt, *.json, исключая backup/
    tar -czf "$TAR_TMP" \
        --exclude='backup' \
        --exclude='*.log' \
        -C /opt/tmp \
        $(find /opt/tmp -maxdepth 1 -type f \( -name '*.sh' -o -name '*.txt' -o -name '*.json' \) -printf '%f ' 2>/dev/null) \
        2>>"$LOG_FILE"
    if [ $? -eq 0 ]; then
        SIZE=$(du -h "$TAR_TMP" 2>/dev/null | awk '{print $1}')
        log_ok "/opt/tmp/ (скрипты и списки) сохранён ($SIZE)"
    else
        log_warn "Не удалось сохранить /opt/tmp/ (возможно, пусто)"
    fi
else
    log_warn "/opt/tmp/ не существует — пропускаю"
fi

# ---------- 3. Список пакетов opkg ----------
log "--- 3. Список пакетов opkg ---"
PKG_FILE="$BACKUP_DIR/opkg-installed.txt"
if opkg list-installed > "$PKG_FILE" 2>>"$LOG_FILE"; then
    COUNT=$(wc -l < "$PKG_FILE")
    log_ok "Список пакетов сохранён ($COUNT пакетов)"
else
    log_err "Ошибка получения списка пакетов"
fi

# ---------- 3b. Пакеты opkg в формате для переустановки ----------
log "--- 3b. Пакеты opkg (список для переустановки) ---"
PKG_LIST="$BACKUP_DIR/opkg-packages.txt"
if opkg list-installed 2>/dev/null | awk '{print $1}' > "$PKG_LIST"; then
    COUNT=$(wc -l < "$PKG_LIST")
    log_ok "Список пакетов для переустановки сохранён ($COUNT пакетов)"
else
    log_warn "Не удалось создать список пакетов для переустановки"
fi

# ---------- 3c. Конфиги opkg (репозитории) ----------
log "--- 3c. Конфиги opkg ---"
if [ -d /opt/etc/opkg ]; then
    tar -czf "$BACKUP_DIR/opkg-configs.tar.gz" -C /opt/etc opkg 2>>"$LOG_FILE"
    if [ $? -eq 0 ]; then
        log_ok "Конфиги opkg сохранены"
    else
        log_warn "Не удалось сохранить конфиги opkg"
    fi
else
    log_warn "/opt/etc/opkg не существует — пропускаю"
fi

# ---------- 4. crontab ----------
log "--- 4. crontab ---"
CRON_FILE="$BACKUP_DIR/crontab.txt"
if crontab -l > "$CRON_FILE" 2>/dev/null; then
    COUNT=$(wc -l < "$CRON_FILE")
    log_ok "crontab сохранён ($COUNT строк)"
else
    log_warn "crontab пуст или недоступен"
    : > "$CRON_FILE"
fi

# ---------- 4b. История команд (shell history) ----------
log "--- 4b. История команд (shell history) ---"
HIST_DIR="$BACKUP_DIR/history"
mkdir -p "$HIST_DIR"

HIST_FOUND=0
# Стандартные места для root и пользователей Entware
for hfile in \
    /opt/root/.ash_history \
    /opt/root/.bash_history \
    /home/root/.ash_history \
    /home/root/.bash_history \
    /root/.ash_history \
    /root/.bash_history
do
    if [ -f "$hfile" ]; then
        SAFE_NAME=$(echo "$hfile" | sed 's|^/||; s|/|_|g')
        cp "$hfile" "$HIST_DIR/$SAFE_NAME" 2>>"$LOG_FILE"
        if [ $? -eq 0 ]; then
            LINES=$(wc -l < "$hfile")
            log_ok "История сохранена: $hfile ($LINES строк)"
            HIST_FOUND=$((HIST_FOUND + 1))
        fi
    fi
done

# История для всех пользователей из /opt/home и /home (если есть)
for home_dir in /opt/home/* /home/*; do
    [ -d "$home_dir" ] || continue
    for hfile in "$home_dir/.ash_history" "$home_dir/.bash_history"; do
        if [ -f "$hfile" ]; then
            SAFE_NAME=$(echo "$hfile" | sed 's|^/||; s|/|_|g')
            cp "$hfile" "$HIST_DIR/$SAFE_NAME" 2>>"$LOG_FILE"
            if [ $? -eq 0 ]; then
                LINES=$(wc -l < "$hfile")
                log_ok "История сохранена: $hfile ($LINES строк)"
                HIST_FOUND=$((HIST_FOUND + 1))
            fi
        fi
    done
done

if [ "$HIST_FOUND" -eq 0 ]; then
    log_warn "Файлы history не найдены (возможно, history не включён в shell)"
    rmdir "$HIST_DIR" 2>/dev/null
else
    # Упаковываем в архив, чтобы не плодить файлы в корне бэкапа
    tar -czf "$BACKUP_DIR/history.tar.gz" -C "$BACKUP_DIR" history 2>>"$LOG_FILE"
    if [ $? -eq 0 ]; then
        SIZE=$(du -h "$BACKUP_DIR/history.tar.gz" | awk '{print $1}')
        log_ok "История упакована в history.tar.gz ($SIZE)"
        rm -rf "$HIST_DIR"
    else
        log_warn "Не удалось упаковать history, оставляю как есть"
    fi
fi

# ---------- 5. Логи (последние 30 дней) ----------
log "--- 5. Логи ---"
LOG_ARCHIVE="$BACKUP_DIR/logs.tar.gz"
if [ -d "$LOG_DIR" ]; then
    tar -czf "$LOG_ARCHIVE" \
        --exclude='backup-keenetic.log' \
        --exclude='*.old' \
        -C /opt/var log 2>>"$LOG_FILE"
    if [ $? -eq 0 ]; then
        SIZE=$(du -h "$LOG_ARCHIVE" 2>/dev/null | awk '{print $1}')
        log_ok "Логи сохранены ($SIZE)"
    else
        log_warn "Не удалось сохранить логи"
        rm -f "$LOG_ARCHIVE"
    fi
else
    log_warn "$LOG_DIR не существует"
fi

# ---------- 6. running-config KeeneticOS ----------
log "--- 6. running-config KeeneticOS ---"
KEENETIC_CFG="$BACKUP_DIR/keenetic-running-config.txt.gz"
if command -v ndmq >/dev/null 2>&1; then
    if ndmq -p "show running-config" -P message | gzip > "$KEENETIC_CFG" 2>>"$LOG_FILE"; then
        SIZE=$(du -h "$KEENETIC_CFG" | awk '{print $1}')
        log_ok "running-config сохранён через ndmq ($SIZE)"
    else
        log_warn "ndmq не смог получить running-config"
        rm -f "$KEENETIC_CFG"
    fi
elif command -v ndmc >/dev/null 2>&1; then
    if ndmc -c "show running-config" 2>/dev/null | gzip > "$KEENETIC_CFG"; then
        SIZE=$(du -h "$KEENETIC_CFG" | awk '{print $1}')
        log_ok "running-config сохранён через ndmc ($SIZE)"
    else
        log_warn "ndmc не смог получить running-config"
        rm -f "$KEENETIC_CFG"
    fi
else
    log_warn "ndmq/ndmc не найден — running-config не сохранён"
    log_warn "Сохраните его вручную через веб-интерфейс: Управление → Файлы → Конфигурация"
fi

# ---------- 7. Информация о системе ----------
log "--- 7. Информация о системе ---"
SYSINFO="$BACKUP_DIR/system-info.txt"
{
    echo "=== Дата бэкапа ==="
    date
    echo ""
    echo "=== uname -a ==="
    uname -a
    echo ""
    echo "=== uptime ==="
    uptime
    echo ""
    echo "=== free ==="
    free
    echo ""
    echo "=== df -h ==="
    df -h
    echo ""
    echo "=== ip route show table 4096 ==="
    ip route show table 4096 2>/dev/null | head -50
    echo ""
    echo "=== ip route show table 4096 | wc -l ==="
    ip route show table 4096 2>/dev/null | wc -l
} > "$SYSINFO" 2>&1
log_ok "Информация о системе сохранена"

# ---------- 7b. Версия прошивки ----------
log "--- 7b. Версия прошивки KeeneticOS ---"
FW_VERSION_FILE="$BACKUP_DIR/firmware-version.txt"
if command -v ndmc >/dev/null 2>&1; then
    if ndmc -c "show version" > "$FW_VERSION_FILE" 2>>"$LOG_FILE"; then
        if [ -s "$FW_VERSION_FILE" ]; then
            log_ok "Версия прошивки сохранена"
        else
            log_warn "ndmc вернул пустой вывод"
            rm -f "$FW_VERSION_FILE"
        fi
    else
        log_warn "ndmc не смог получить версию прошивки"
        rm -f "$FW_VERSION_FILE"
    fi
else
    log_warn "ndmc не найден — версия прошивки не сохранена"
fi

# ---------- 8. Лог бэкапа (копия в папку бэкапа) ----------
log "--- 8. Лог бэкапа ---"
BACKUP_LOG_COPY="$BACKUP_DIR/backup-keenetic.log"
if [ -f "$LOG_FILE" ]; then
    cp "$LOG_FILE" "$BACKUP_LOG_COPY" 2>>"$LOG_FILE"
    if [ $? -eq 0 ]; then
        LINES=$(wc -l < "$BACKUP_LOG_COPY")
        SIZE=$(du -h "$BACKUP_LOG_COPY" | awk '{print $1}')
        log_ok "Лог бэкапа сохранён в папку бэкапа ($LINES строк, $SIZE)"
    else
        log_warn "Не удалось скопировать лог в папку бэкапа"
    fi
else
    log_warn "Файл лога $LOG_FILE не найден"
fi

# ---------- 9. Контрольные суммы ----------
log "--- 9. Контрольные суммы ---"
CHECKSUM_FILE="$BACKUP_DIR/checksums.md5"
cd "$BACKUP_DIR" && md5sum *.tar.gz *.txt *.log 2>/dev/null > "$CHECKSUM_FILE"
if [ -s "$CHECKSUM_FILE" ]; then
    log_ok "Контрольные суммы созданы"
else
    log_warn "Не удалось создать контрольные суммы"
    rm -f "$CHECKSUM_FILE"
fi
cd - >/dev/null

# ---------- 10. Итоговый архив ----------
log "--- 10. Итоговый архив ---"
FINAL_ARCHIVE="$BACKUP_ROOT/keenetic-backup-$DATE_TAG.tar.gz"
if tar -czf "$FINAL_ARCHIVE" -C "$BACKUP_DIR" . 2>>"$LOG_FILE"; then
    SIZE=$(du -h "$FINAL_ARCHIVE" | awk '{print $1}')
    log_ok "Итоговый архив: $FINAL_ARCHIVE ($SIZE)"
else
    log_err "Не удалось создать итоговый архив"
fi

# ---------- 11. Очистка старых бэкапов ----------
log "--- 11. Очистка старых бэкапов ---"
clean_old_backups

# ---------- Итог ----------
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
log "============================================================"
log "БЭКАП ЗАВЕРШЁН"
log "Папка: $BACKUP_DIR ($TOTAL_SIZE)"
log "Архив: $FINAL_ARCHIVE"
log "Лог:   $LOG_FILE"
log "============================================================"

exit 0
