cd ~
cat > instalar-hcwp-termux.sh <<'EOF'
#!/usr/bin/env bash

set -u

REPO_URL="https://github.com/dizcza/hashcat-wpa-server.git"
LAB_DIR="$HOME/lab/repos"
APP_DIR="$LAB_DIR/hashcat-wpa-server"
VENV_DIR="$APP_DIR/.venv"
DATA_DIR="$HOME/.hashcat/wpa-server"
LOG_DIR="$HOME/lab/logs"
PORT="${HCWP_PORT:-9111}"

PASS="${HASHCAT_ADMIN_PASSWORD:-}"

ok=0
warn=0
fail=0

msg() {
    printf '\n[%s] %s\n' "$1" "$2"
}

pass() {
    printf '  [OK] %s\n' "$1"
    ok=$((ok+1))
}

warning() {
    printf '  [WARN] %s\n' "$1"
    warn=$((warn+1))
}

error() {
    printf '  [ERROR] %s\n' "$1"
    fail=$((fail+1))
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

msg INFO "Diagnóstico/instalación hashcat-wpa-server para Kali + Termux"

printf '\n== Entorno ==\n'

printf 'Shell       : %s\n' "${SHELL:-desconocido}"
printf 'HOME        : %s\n' "$HOME"
printf 'PREFIX      : %s\n' "${PREFIX:-no definido}"
printf 'Arquitectura: '
uname -m 2>/dev/null || printf 'desconocida'
printf '\n'

if [ -f /etc/os-release ]; then
    printf 'OS          : '
    sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"'
    printf '\n'
else
    printf 'OS          : /etc/os-release no disponible\n'
fi

printf '\n== Espacio ==\n'
df -h "$HOME" 2>/dev/null || warning "No se pudo consultar df"

printf '\n== Dependencias base ==\n'

for cmd in git python3; do
    if command_exists "$cmd"; then
        pass "$cmd encontrado: $(command -v "$cmd")"
    else
        error "$cmd no encontrado"
    fi
done

if command_exists hashcat; then
    pass "hashcat encontrado: $(command -v hashcat)"
    hashcat --version 2>&1 | head -1 || true
else
    warning "hashcat no está instalado"
    warning "El servidor podrá instalarse, pero no podrá procesar trabajos Hashcat"
fi

if command_exists gunicorn; then
    pass "gunicorn encontrado globalmente"
else
    warning "gunicorn no está instalado globalmente; se instalará dentro del venv"
fi

printf '\n== Arquitectura ==\n'

ARCH="$(uname -m 2>/dev/null || true)"

case "$ARCH" in
    aarch64|arm64)
        pass "Arquitectura ARM64/AArch64 detectada"
        ;;
    armv7l|armv8l|arm*)
        warning "Arquitectura ARM de 32 bits detectada: $ARCH"
        ;;
    *)
        warning "Arquitectura no esperada: $ARCH"
        ;;
esac

printf '\n== Preparando laboratorio ==\n'

mkdir -p "$LAB_DIR" "$LOG_DIR" "$DATA_DIR"

if [ ! -d "$APP_DIR/.git" ]; then
    msg INFO "Clonando repositorio"

    if ! git clone --depth 1 "$REPO_URL" "$APP_DIR"; then
        error "No se pudo clonar el repositorio"
        exit 10
    fi
else
    msg INFO "Repositorio existente"

    cd "$APP_DIR" || exit 11

    if git diff --quiet && git diff --cached --quiet; then
        if git fetch --depth 1 origin master >/dev/null 2>&1; then
            git reset --hard origin/master >/dev/null 2>&1 || \
                warning "No se pudo actualizar automáticamente"
        else
            warning "No se pudo consultar origin/master"
        fi
    else
        warning "Hay modificaciones locales; NO se sobrescribieron"
    fi
fi

cd "$APP_DIR" || exit 12

printf '\n== Archivos del proyecto ==\n'

for item in README.md requirements.txt app; do
    if [ -e "$item" ]; then
        pass "$item presente"
    else
        error "$item falta"
    fi
done

printf '\n== Python ==\n'

PYTHON="$(command -v python3 || true)"

if [ -z "$PYTHON" ]; then
    error "python3 no disponible"
    exit 20
fi

"$PYTHON" --version

if [ ! -d "$VENV_DIR" ]; then
    msg INFO "Creando entorno virtual"

    if ! "$PYTHON" -m venv "$VENV_DIR"; then
        error "No se pudo crear el venv"
        error "En Kali instala python3-venv y vuelve a ejecutar"
        exit 21
    fi
else
    pass "venv existente"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

printf '\n== Venv ==\n'
printf 'Python: %s\n' "$(command -v python)"
python --version

python -m pip install --upgrade pip setuptools wheel

printf '\n== Dependencias Python ==\n'

if ! python -m pip install -r requirements.txt; then
    error "Falló la instalación de requirements.txt"
    error "El repositorio usa versiones antiguas; revisar el error antes de continuar"
    exit 22
fi

pass "Dependencias Python instaladas"

printf '\n== Directorios de datos ==\n'

mkdir -p \
    "$DATA_DIR" \
    "$DATA_DIR/database" \
    "$DATA_DIR/captures" \
    "$DATA_DIR/logs" \
    "$DATA_DIR/wordlists" \
    "$DATA_DIR/brain"

touch "$DATA_DIR/.write-test"

if [ -f "$DATA_DIR/.write-test" ]; then
    rm -f "$DATA_DIR/.write-test"
    pass "Directorio de datos escribible"
else
    error "No se puede escribir en $DATA_DIR"
fi

printf '\n== Importación de la aplicación ==\n'

if python - <<'PY'
import sys

try:
    import flask
    import sqlalchemy
    import flask_login
    import flask_migrate
    import flask_sqlalchemy
    import flask_wtf
    import flask_reuploaded
    import gunicorn
    import wordninja
    import tqdm

    print("Imports Python: OK")

    import app

    print("Import app: OK")

except Exception as e:
    print("IMPORT_ERROR:", repr(e))
    sys.exit(1)
PY
then
    pass "app importable"
else
    error "No se pudo importar app"
    exit 23
fi

printf '\n== SQLite ==\n'

if python - <<'PY'
from pathlib import Path
import sqlite3

p = Path.home() / ".hashcat" / "wpa-server" / "database" / "diagnostic.sqlite"

con = sqlite3.connect(p)
con.execute("CREATE TABLE IF NOT EXISTS diagnostic (id INTEGER PRIMARY KEY)")
con.commit()
con.close()

p.unlink(missing_ok=True)

print("SQLite: OK")
PY
then
    pass "SQLite operativo"
else
    error "SQLite falló"
fi

printf '\n== Hashcat ==\n'

if command_exists hashcat; then

    if hashcat --version >/dev/null 2>&1; then
        pass "hashcat responde"
    else
        error "hashcat existe pero no responde correctamente"
    fi

    printf '\nInformación de dispositivo Hashcat:\n'
    hashcat -I 2>&1 | head -80 || true

else
    warning "Hashcat no está disponible; se omite prueba de dispositivo"
fi

printf '\n== Configuración local ==\n'

LAUNCHER="$HOME/lab/scripts"

mkdir -p "$LAUNCHER"

cat > "$LAUNCHER/hashcat-wpa-server-local.sh" <<'RUNEOF'
#!/usr/bin/env bash

set -u

APP_DIR="$HOME/lab/repos/hashcat-wpa-server"
VENV_DIR="$APP_DIR/.venv"
PORT="${HCWP_PORT:-9111}"

if [ ! -d "$APP_DIR" ]; then
    echo "[ERROR] No existe $APP_DIR"
    exit 30
fi

if [ ! -f "$VENV_DIR/bin/activate" ]; then
    echo "[ERROR] No existe el entorno virtual"
    echo "Ejecuta primero instalar-hcwp-termux.sh"
    exit 31
fi

if [ -z "${HASHCAT_ADMIN_PASSWORD:-}" ]; then
    echo "[ERROR] Define HASHCAT_ADMIN_PASSWORD antes de arrancar"
    echo
    echo 'Ejemplo:'
    echo 'export HASHCAT_ADMIN_PASSWORD="cambia-esta-clave"'
    exit 32
fi

cd "$APP_DIR" || exit 33

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

export HASHCAT_ADMIN_USER="${HASHCAT_ADMIN_USER:-admin}"

echo "=========================================="
echo " hashcat-wpa-server"
echo " localhost:$PORT"
echo " PID: $$"
echo "=========================================="
echo

exec gunicorn \
    --bind "127.0.0.1:${PORT}" \
    --workers 1 \
    --threads 2 \
    --timeout 300 \
    --access-logfile - \
    --error-logfile - \
    app:app
RUNEOF

chmod +x "$LAUNCHER/hashcat-wpa-server-local.sh"

pass "Lanzador creado: $LAUNCHER/hashcat-wpa-server-local.sh"

printf '\n== Diagnóstico final ==\n'

printf 'Repositorio : %s\n' "$APP_DIR"
printf 'Venv        : %s\n' "$VENV_DIR"
printf 'Datos       : %s\n' "$DATA_DIR"
printf 'Lanzador    : %s\n' "$LAUNCHER/hashcat-wpa-server-local.sh"
printf 'Puerto      : %s\n' "$PORT"

printf '\nResultados:\n'
printf '  OK    : %s\n' "$ok"
printf '  WARN  : %s\n' "$warn"
printf '  ERROR : %s\n' "$fail"

if [ "$fail" -gt 0 ]; then
    printf '\n[RESULTADO] Instalación incompleta.\n'
    exit 40
fi

printf '\n[RESULTADO] Instalación base correcta.\n'

printf '\nPara arrancarlo:\n'
printf '  export HASHCAT_ADMIN_PASSWORD="tu-clave-local"\n'
printf '  %s/hashcat-wpa-server-local.sh\n' "$LAUNCHER"

printf '\nDespués abre desde el mismo teléfono:\n'
printf '  http://127.0.0.1:%s\n' "$PORT"

exit 0
EOF

chmod +x instalar-hcwp-termux.sh
./instalar-hcwp-termux.sh