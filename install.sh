#!/bin/bash

# Installationsscript für eine Nuclos Docker-Instanz
# auf Basis der offiziellen Docker-Hub-Images von nuccess:
#   https://hub.docker.com/r/nuccess/nuclos-server
#   https://hub.docker.com/r/nuccess/nuclos-db
#
# Erstellt:      Jörg Staub - 15.09.2025
# Überarbeitet:  09/2026 - Umstellung von "Installer-JAR + eigenem Image-Build"
#                auf die fertigen nuccess-Images. Zusätzlich Vorbereitung für den
#                Parallelbetrieb mit Sage 100 / MS-SQL (externe Datenbankverbindung).
#
# Wichtig zur Architektur:
#   - Die nuccess-Images unterstützen als Nuclos-SYSTEMdatenbank ausschließlich
#     PostgreSQL (Datenbank "nuclosdb", Benutzer "nuclos" sind im Image fest
#     vorgegeben; nur Schema und Passwort sind konfigurierbar).
#   - Die Sage-100-Daten (MS-SQL) werden NICHT als Systemdatenbank verwendet,
#     sondern in Nuclos als EXTERNE Datenbankverbindung (JDBC) eingebunden.
#     Dieses Script legt dafür den Microsoft-JDBC-Treiber in den
#     Extensions-Ordner und gibt die fertige JDBC-URL aus.
#
# Aufruf:
#   ./install.sh            normale Installation (Container werden gestartet)
#   ./install.sh --no-start nur Konfiguration erzeugen, Container nicht starten

# Parameter ######################################################################
NO_START=0
for arg in "$@"; do
  case "$arg" in
    --no-start) NO_START=1 ;;
    -h|--help)
      grep '^#' "$0" | head -30
      exit 0
      ;;
  esac
done

# Check RAM ######################################################################
REQUIRED_MEMORY=4000  # 4GB in MB
AVAILABLE_MEMORY=$(free -m | awk '/^Mem:/{print $2}')
if (( AVAILABLE_MEMORY < REQUIRED_MEMORY )); then
    echo "⚠️  Warnung: System hat weniger als 4GB RAM"
fi

# Check Docker Installation ######################################################
if ! command -v docker >/dev/null 2>&1; then
    if [[ $NO_START -eq 1 ]]; then
        echo "⚠️  Docker ist nicht installiert (wegen --no-start nur Warnung)"
    else
        echo "❌ Docker ist nicht installiert"
        exit 1
    fi
elif ! docker info >/dev/null 2>&1; then
    if [[ $NO_START -eq 1 ]]; then
        echo "⚠️  Docker-Daemon läuft nicht (wegen --no-start nur Warnung)"
    else
        echo "❌ Docker-Daemon läuft nicht"
        exit 1
    fi
elif ! docker compose version >/dev/null 2>&1; then
    echo "❌ Docker Compose v2 (docker compose) ist nicht verfügbar"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "⚠️  Script läuft nicht als root - Verzeichnisrechte (chown) werden ggf. per sudo gesetzt"
fi

# Defaults #######################################################################
default_prefix=nuc
default_server_tag=latest        # zum Festpinnen z.B. 4.2026.28
default_db_tag=17.6              # PostgreSQL-Version des nuccess/nuclos-db Images
default_schema=nuclos
default_ram_server=4
default_ram_db=2
default_tz=Europe/Berlin
default_locale=de_DE.UTF-8
default_mssql_port=1433
default_mssql_db=OLReweAbf       # Standard-Datenbankname von Sage 100
default_mssql_user=nuclos_ro     # Read-only-Login fuer Nuclos (wird mit sage100/01-*.sql angelegt)
MSSQL_TOOLS_IMAGE=mcr.microsoft.com/mssql-tools:latest  # sqlcmd fuer den Verbindungstest
MSSQL_JDBC_VERSION=13.6.0.jre11  # Microsoft JDBC-Treiber (Java 11+, passend zu Java 17 im Image)

# Feste Vorgaben der nuccess-Images (nicht änderbar):
NUCLOS_DB_NAME=nuclosdb
NUCLOS_DB_USER=nuclos

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
# Setup logging
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/nuclos_install_${TIMESTAMP}.log"
exec 1> >(tee -a "$LOG_FILE") 2>&1

echo "=== Nuclos Installation Log ==="
echo "Date: ${TIMESTAMP}"
echo "System: $(uname -a)"
echo "==============================="

# Hilfsfunktionen ################################################################
port_in_use() {
  local p=$1
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP -sTCP:LISTEN -Pn 2>/dev/null | grep -qE ":${p}\b"
  else
    ss -tln 2>/dev/null | grep -qE ":${p}\b"
  fi
}

find_free_port() {
  local port=8080
  while port_in_use "$port"; do
    ((port++))
  done
  echo $port
}

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 12
  else
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
  fi
}

as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "⚠️  Bitte manuell als root ausführen: $*"
    return 1
  fi
}

download() {
  # download <url> <ziel>
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    echo "❌ Weder curl noch wget vorhanden"
    return 1
  fi
}

mssql_query() {
  # mssql_query "<SQL>" -> Ergebniszeilen (Tab-getrennt, ohne Header) auf stdout.
  # Läuft in einem Wegwerf-Container; das Passwort geht nur per Umgebungsvariable
  # an sqlcmd und taucht nicht in der Prozessliste auf.
  docker run --rm --add-host host.docker.internal:host-gateway \
    -e "SQLCMDPASSWORD=${SAGE_TEST_PASS}" "$MSSQL_TOOLS_IMAGE" \
    /opt/mssql-tools/bin/sqlcmd -S "${SAGE_MSSQL_HOST},${SAGE_MSSQL_PORT}" \
    -U "$SAGE_TEST_USER" -l 10 -b -h -1 -W -s $'\t' -Q "SET NOCOUNT ON; $1" 2>&1
}

sage_connection_test() {
  # Echter Verbindungstest gegen den Sage-100-SQL-Server: Login, Datenbanken,
  # Sage-Struktur (KHKMandanten) und Mandantenliste.
  local dbs out first mandanten newdb
  echo "Lade sqlcmd-Container (${MSSQL_TOOLS_IMAGE}, beim ersten Mal etwas Geduld)..."
  if ! docker pull -q "$MSSQL_TOOLS_IMAGE" >/dev/null 2>&1; then
    echo "⚠️  Image konnte nicht geladen werden - Verbindungstest übersprungen."
    return 0
  fi
  echo "Prüfe SQL-Login ${SAGE_TEST_USER} auf ${SAGE_MSSQL_HOST}:${SAGE_MSSQL_PORT} ..."
  if ! dbs=$(mssql_query "SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name"); then
    echo "❌ Anmeldung fehlgeschlagen:"
    echo "$dbs" | head -n 3 | sed 's/^/   /'
    echo "   (Login/Passwort, SQL-Authentifizierung (Mixed Mode) und Firewall prüfen)"
    return 0
  fi
  echo "✅ Anmeldung erfolgreich. Sichtbare Datenbanken auf dem Server:"
  echo "$dbs" | sed 's/^/   - /'
  if ! echo "$dbs" | grep -qix "$SAGE_MSSQL_DB"; then
    echo "⚠️  Datenbank '${SAGE_MSSQL_DB}' nicht gefunden (oder keine Berechtigung)."
    read -p "Datenbankname korrigieren [Enter für ${SAGE_MSSQL_DB}]: " newdb
    SAGE_MSSQL_DB=${newdb:-$SAGE_MSSQL_DB}
  fi
  if ! out=$(mssql_query "SELECT CASE WHEN OBJECT_ID('[${SAGE_MSSQL_DB}].dbo.KHKMandanten') IS NULL THEN 'NO' ELSE 'YES' END") \
     || [[ "$(echo "$out" | grep -v '^[[:space:]]*$' | tail -n1 | tr -d '[:space:]')" != "YES" ]]; then
    echo "⚠️  In '${SAGE_MSSQL_DB}' wurde keine Sage-100-Struktur gefunden (Tabelle KHKMandanten fehlt)."
    echo "   Datenbankname prüfen - die Angaben können später in Nuclos korrigiert werden."
    return 0
  fi
  echo "✅ '${SAGE_MSSQL_DB}' ist eine Sage-100-Datenbank."
  if mandanten=$(mssql_query "SELECT m.Mandant, (SELECT COUNT(*) FROM [${SAGE_MSSQL_DB}].dbo.KHKAdressen a WHERE a.Mandant = m.Mandant) FROM (SELECT DISTINCT Mandant FROM [${SAGE_MSSQL_DB}].dbo.KHKMandanten) m ORDER BY m.Mandant") \
     && [[ -n "$mandanten" ]]; then
    echo "Mandanten in ${SAGE_MSSQL_DB}:"
    echo "$mandanten" | awk -F'\t' '{printf "   - Mandant %s  (%s Adressen)\n", $1, $2}'
    first=$(echo "$mandanten" | head -n1 | cut -f1)
    read -p "Mandant für die Nuclos-Anbindung [Enter für ${first}]: " SAGE_MSSQL_MANDANT
    SAGE_MSSQL_MANDANT=${SAGE_MSSQL_MANDANT:-$first}
  else
    echo "⚠️  Mandanten konnten nicht gelesen werden (Berechtigung auf ${SAGE_MSSQL_DB}?)."
  fi
}

clear
set -e
echo "-----------------------------------------------------------"
echo "Nuclos Docker-Instanz Setup (nuccess/nuclos-server)"
echo "Dieses Script erzeugt automatisch .env, docker-compose.yml,"
echo "das Secrets-Verzeichnis sowie Backup-, Restore-, Upgrade-"
echo "und Uninstall-Scripte."
echo "-----------------------------------------------------------"
echo "Folgende Container werden erzeugt:"
echo "  nuccess/nuclos-db     (PostgreSQL Systemdatenbank)"
echo "  nuccess/nuclos-server (Nuclos Applikationsserver)"
echo "Es wird KEIN Installer-JAR und KEIN lokaler Image-Build mehr benötigt."
echo "-----------------------------------------------------------"

if [[ -f docker-compose.yml || -f .env ]]; then
  echo "⚠️  In diesem Verzeichnis existiert bereits eine Konfiguration"
  echo "   (.env / docker-compose.yml). Sie wird überschrieben,"
  echo "   vorhandene Datenverzeichnisse bleiben erhalten."
  read -p "Fortfahren? (ja/nein): " confirm
  [[ "$confirm" == "ja" ]] || exit 1
fi

# Parameter abfragen #############################################################
echo "> Docker Parameter --------------------------------------------------------"
read -p "Docker Container-Präfix [Enter für $default_prefix]: " PREFIX
PREFIX=${PREFIX:-$default_prefix}
PREFIX=$(echo "$PREFIX" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
[[ -n "$PREFIX" ]] || PREFIX=$default_prefix
echo "Verwendeter Präfix: $PREFIX"

echo "> Nuclos Versionen --------------------------------------------------------"
echo "Verfügbare Tags: https://hub.docker.com/r/nuccess/nuclos-server/tags"
read -p "Nuclos-Server Tag (z.B. 4.2026.28) [Enter für $default_server_tag]: " NUCLOS_SERVER_TAG
NUCLOS_SERVER_TAG=${NUCLOS_SERVER_TAG:-$default_server_tag}
read -p "Nuclos-DB Tag (PostgreSQL, z.B. 17.6) [Enter für $default_db_tag]: " NUCLOS_DB_TAG
NUCLOS_DB_TAG=${NUCLOS_DB_TAG:-$default_db_tag}

echo "> Datenbank Parameter -----------------------------------------------------"
echo "Hinweis: Datenbankname ($NUCLOS_DB_NAME) und Benutzer ($NUCLOS_DB_USER) sind"
echo "durch die nuccess-Images fest vorgegeben. Konfigurierbar sind Schema und Passwort."
read -p "Datenbank-Schema der Instanz [Enter für $default_schema]: " DB_SCHEMA
DB_SCHEMA=${DB_SCHEMA:-$default_schema}
DB_SCHEMA=$(echo "$DB_SCHEMA" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')
[[ -n "$DB_SCHEMA" ]] || DB_SCHEMA=$default_schema

generated_password=$(gen_password)
read -p "Datenbank Passwort [Enter für generiertes: $generated_password]: " DB_PASSWORD
DB_PASSWORD=${DB_PASSWORD:-$generated_password}
if [[ "$DB_PASSWORD" == "password" ]]; then
    echo "⚠️  Warnung: 'password' ist das Default-Passwort der Images und für Produktion ungeeignet"
    read -p "Trotzdem fortfahren? (y/N): " confirm
    [[ $confirm == "y" ]] || exit 1
fi

echo "> Ressourcen --------------------------------------------------------------"
read -p "RAM für Nuclos-Server in GB [Enter für $default_ram_server]: " NUCLOS_RAM_GB
NUCLOS_RAM_GB=${NUCLOS_RAM_GB:-$default_ram_server}
read -p "RAM für Datenbank in GB [Enter für $default_ram_db]: " DB_RAM_GB
DB_RAM_GB=${DB_RAM_GB:-$default_ram_db}

echo "> Lokalisierung -----------------------------------------------------------"
read -p "Zeitzone [Enter für $default_tz]: " TZ_VALUE
TZ_VALUE=${TZ_VALUE:-$default_tz}
read -p "Locale [Enter für $default_locale]: " LOCALE_VALUE
LOCALE_VALUE=${LOCALE_VALUE:-$default_locale}

# Port automatisch vorschlagen ###################################################
default_port=$(find_free_port)
echo "> Netzwerk ----------------------------------------------------------------"
echo "Vorgeschlagener freier Port: $default_port"

while true; do
  read -p "Freier HTTP-Port für Nuclos [Enter für $default_port]: " NUCLOS_PORT
  NUCLOS_PORT=${NUCLOS_PORT:-$default_port}

  if port_in_use "$NUCLOS_PORT"; then
    echo "❌ Port $NUCLOS_PORT ist bereits belegt. Bitte einen anderen wählen."
  else
    echo "✅ Port $NUCLOS_PORT ist frei."
    break
  fi
done

# Sage 100 / MS-SQL Anbindung ####################################################
echo "> Sage 100 / MS-SQL -------------------------------------------------------"
echo "Nuclos läuft parallel zu Sage 100. Die Sage-Datenbank (MS-SQL) wird in"
echo "Nuclos als externe Datenbankverbindung (JDBC) eingebunden - dafür wird der"
echo "Microsoft-JDBC-Treiber in den Extensions-Ordner des Servers gelegt."
read -p "Sage 100 / MS-SQL Anbindung vorbereiten? (J/n): " MSSQL_PREP
MSSQL_PREP=${MSSQL_PREP:-J}

SAGE_MSSQL_HOST=""
SAGE_MSSQL_PORT=""
SAGE_MSSQL_DB=""
SAGE_MSSQL_USER=""
SAGE_MSSQL_MANDANT=""
SAGE_TEST_USER=""
SAGE_TEST_PASS=""
if [[ "$MSSQL_PREP" =~ ^[JjYy] ]]; then
  echo "Der MS-SQL-Server (Sage 100) läuft auf einem ANDEREN Server:"
  echo "Hostname oder IP dieses Servers angeben - er muss vom Docker-Host aus"
  echo "über den MS-SQL-Port erreichbar sein (Firewall!)."
  echo "(Sonderfall: läuft MS-SQL doch auf dem Docker-Host selbst,"
  echo " 'host.docker.internal' eintragen.)"
  read -p "MS-SQL Host (Hostname/IP des Sage-100-Servers): " SAGE_MSSQL_HOST
  read -p "MS-SQL Port [Enter für $default_mssql_port]: " SAGE_MSSQL_PORT
  SAGE_MSSQL_PORT=${SAGE_MSSQL_PORT:-$default_mssql_port}
  read -p "Sage 100 Datenbankname [Enter für $default_mssql_db]: " SAGE_MSSQL_DB
  SAGE_MSSQL_DB=${SAGE_MSSQL_DB:-$default_mssql_db}
  echo "SQL-Benutzer, mit dem Nuclos auf die Sage-Datenbank zugreift (empfohlen ein"
  echo "eigener Read-only-Login; wird mit sage100/01-nuclos-readonly-login.sql angelegt)."
  read -p "SQL-Benutzer für Nuclos [Enter für $default_mssql_user]: " SAGE_MSSQL_USER
  SAGE_MSSQL_USER=${SAGE_MSSQL_USER:-$default_mssql_user}

  if [[ -z "$SAGE_MSSQL_HOST" ]]; then
    echo "ℹ️  Kein Host angegeben - die Verbindungsdaten können später direkt"
    echo "   in Nuclos hinterlegt werden."
  else
    if [[ "$SAGE_MSSQL_HOST" != "host.docker.internal" ]]; then
      echo "Prüfe Erreichbarkeit von ${SAGE_MSSQL_HOST}:${SAGE_MSSQL_PORT} ..."
      if timeout 5 bash -c "exec 3<>/dev/tcp/${SAGE_MSSQL_HOST}/${SAGE_MSSQL_PORT} && exec 3>&-" 2>/dev/null; then
        echo "✅ ${SAGE_MSSQL_HOST}:${SAGE_MSSQL_PORT} ist vom Docker-Host aus erreichbar."
      else
        echo "⚠️  ${SAGE_MSSQL_HOST}:${SAGE_MSSQL_PORT} ist aktuell NICHT erreichbar."
        echo "   Bitte prüfen: Firewall-Freigabe vom Docker-Host, TCP/IP im"
        echo "   SQL Server Configuration Manager, Namensauflösung."
        echo "   (Die Installation läuft trotzdem weiter.)"
      fi
    fi

    echo ""
    echo "Optional: Verbindungstest mit echter SQL-Anmeldung. Der Installer prüft"
    echo "den Login, listet die Datenbanken des Sage-Servers auf und zeigt die"
    echo "Mandanten zur Auswahl. Das läuft in einem Wegwerf-Container mit sqlcmd -"
    echo "nichts wird auf dem Host installiert, das Passwort wird nicht gespeichert."
    echo "(Existiert ${SAGE_MSSQL_USER} noch nicht, kann z.B. 'sa' zum Testen genutzt werden.)"
    read -p "Login für den Verbindungstest [Enter für ${SAGE_MSSQL_USER}]: " SAGE_TEST_USER
    SAGE_TEST_USER=${SAGE_TEST_USER:-$SAGE_MSSQL_USER}
    read -s -p "Passwort für ${SAGE_TEST_USER} [Enter = Test überspringen]: " SAGE_TEST_PASS
    echo ""
    if [[ -n "$SAGE_TEST_PASS" ]]; then
      if docker info >/dev/null 2>&1; then
        sage_connection_test
      else
        echo "⚠️  Docker-Daemon nicht erreichbar - Verbindungstest übersprungen."
      fi
      unset SAGE_TEST_PASS
    fi
  fi
fi

# Verzeichnisse anlegen ##########################################################
echo "Lege Verzeichnisse an..."
mkdir -p nuclos-pgdata
mkdir -p nuclos-db-exchange
mkdir -p nuclos-data/documents nuclos-data/index nuclos-data/logs nuclos-data/nucletimport
mkdir -p nuclos-extensions/server nuclos-extensions/client nuclos-extensions/common
mkdir -p nuclos-backups
mkdir -p nuclos-control
mkdir -p secrets

# Rechte passend zu den Container-Benutzern setzen:
#   nuclos-db     läuft als postgres (uid 999, gid 999)
#   nuclos-server läuft als nuclos   (uid 1000, gid 1000)
#   /var/nuclos-db wird von beiden genutzt (999:1000, 770)
echo "Setze Verzeichnisrechte (Container-UIDs 999/1000)..."
as_root chown 999:999 nuclos-pgdata || true
as_root chmod 700 nuclos-pgdata || true
as_root chown 999:1000 nuclos-db-exchange || true
as_root chmod 770 nuclos-db-exchange || true
as_root chown -R 1000:1000 nuclos-data nuclos-extensions nuclos-backups nuclos-control || true

# Secrets ########################################################################
echo "Erzeuge Secrets-Datei ./secrets/db_password ..."
printf '%s' "$DB_PASSWORD" > secrets/db_password
as_root chown -R 999:1000 secrets || true
as_root chmod 750 secrets || true
as_root chmod 640 secrets/db_password || true

# .gitignore erzeugen ############################################################
# Falls das Installationsverzeichnis (auch) ein Git-Repo ist: Secrets,
# Laufzeitdaten und generierte Dateien dürfen niemals eingecheckt werden.
if [[ ! -f .gitignore ]]; then
cat > .gitignore <<'EOF'
# Von install.sh erzeugte Dateien und Laufzeitdaten - niemals committen!
secrets/
.env
docker-compose.yml
logs/
nuclos-pgdata/
nuclos-data/
nuclos-extensions/
nuclos-backups/
nuclos-db-backups/
nuclos-db-exchange/
nuclos-control/
nuclos-instanzbackup/
nuclos-archiv/
backup-*.tar.gz
*.backup
# generierte Hilfsscripte
uninstall.sh
backup-db.sh
backup-instanz.sh
restore-instanz.sh
upgrade.sh
EOF
echo "Erzeuge .gitignore (Secrets/Laufzeitdaten vom Einchecken ausgeschlossen)"
fi

# .env erzeugen ##################################################################
cat > .env <<EOF
# Generated .env
# Installation: ${TIMESTAMP}
#
# Docker
PREFIX="${PREFIX}"
# Image-Tags (https://hub.docker.com/r/nuccess/nuclos-server/tags)
NUCLOS_SERVER_TAG="${NUCLOS_SERVER_TAG}"
NUCLOS_DB_TAG="${NUCLOS_DB_TAG}"
# Nuclos
NUCLOS_PORT="${NUCLOS_PORT}"
DB_SCHEMA="${DB_SCHEMA}"
NUCLOS_RAM_GB="${NUCLOS_RAM_GB}"
DB_RAM_GB="${DB_RAM_GB}"
LIVE_SEARCH="false"
TZ="${TZ_VALUE}"
LOCALE="${LOCALE_VALUE}"
# Datenbank (durch die nuccess-Images fest vorgegeben)
# Datenbankname: ${NUCLOS_DB_NAME} / Benutzer: ${NUCLOS_DB_USER}
# Das DB-Passwort steht NICHT hier, sondern in ./secrets/db_password
#
# Sage 100 / MS-SQL (nur Referenz - die Verbindung wird in Nuclos konfiguriert)
SAGE_MSSQL_HOST="${SAGE_MSSQL_HOST}"
SAGE_MSSQL_PORT="${SAGE_MSSQL_PORT}"
SAGE_MSSQL_DB="${SAGE_MSSQL_DB}"
SAGE_MSSQL_USER="${SAGE_MSSQL_USER}"
SAGE_MSSQL_MANDANT="${SAGE_MSSQL_MANDANT}"
EOF

# docker-compose.yml erzeugen ####################################################
# Hinweise:
#  - Der Nuclos-Server erwartet die Datenbank fest unter dem Hostnamen "postgres"
#    (Netzwerk-Alias), Port 5432, Datenbank "nuclosdb", Benutzer "nuclos".
#  - /var/nuclos-db ist das gemeinsame Austauschverzeichnis von Server und DB
#    (Schema-Anlage, DockerBackup/DockerRestore) und MUSS geteilt werden.
#  - Der PostgreSQL-Port wird bewusst NICHT am Host veröffentlicht.
#  - Der MS-SQL-Server (Sage 100) läuft auf einem anderen Server und wird über
#    das normale Netzwerk erreicht. host.docker.internal ist nur der Sonderfall
#    "MS-SQL läuft auf dem Docker-Host selbst".
cat > docker-compose.yml <<'EOF'
name: ${PREFIX}-nuclos

networks:
  nuclos-net:
    driver: bridge

services:
  db:
    image: nuccess/nuclos-db:${NUCLOS_DB_TAG}
    container_name: ${PREFIX}-db
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      LOCALE: ${LOCALE}
      TOTAL_RAM_GB: ${DB_RAM_GB}
    volumes:
      - ./nuclos-pgdata:/var/lib/postgresql/nuclos
      - ./nuclos-db-exchange:/var/nuclos-db
      - ./secrets:/opt/nuclos/secrets:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nuclos -d nuclosdb"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 60s
    networks:
      nuclos-net:
        aliases:
          - postgres

  server:
    image: nuccess/nuclos-server:${NUCLOS_SERVER_TAG}
    container_name: ${PREFIX}-server
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "${NUCLOS_PORT}:8080"
    environment:
      DOCKER_NUCLOS_PORT: ${NUCLOS_PORT}
      DB_SCHEMA: ${DB_SCHEMA}
      TOTAL_RAM_GB: ${NUCLOS_RAM_GB}
      LIVE_SEARCH: ${LIVE_SEARCH}
      TZ: ${TZ}
      LOCALE: ${LOCALE}
    volumes:
      - ./nuclos-data/documents:/opt/nuclos/home/data/documents
      - ./nuclos-data/index:/opt/nuclos/home/data/index
      - ./nuclos-data/logs:/opt/nuclos/home/logs
      - ./nuclos-data/nucletimport:/opt/nuclos/home/data/nucletimport
      - ./nuclos-backups:/opt/nuclos/backups
      - ./nuclos-extensions:/opt/nuclos/extensions
      - ./nuclos-control:/opt/nuclos/control
      - ./nuclos-db-exchange:/var/nuclos-db
      - ./secrets:/opt/nuclos/secrets:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    healthcheck:
      # Prüft nur, ob Tomcat lauscht. Der Erststart (AutoDbSetup) kann
      # mehrere Minuten dauern, daher grosszügige start_period.
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080 && exec 3>&-"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 1800s
    networks:
      - nuclos-net
EOF

# MS-SQL JDBC-Treiber für Sage 100 Anbindung #####################################
if [[ "$MSSQL_PREP" =~ ^[JjYy] ]]; then
  JDBC_JAR="nuclos-extensions/server/mssql-jdbc-${MSSQL_JDBC_VERSION}.jar"
  JDBC_URL="https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/${MSSQL_JDBC_VERSION}/mssql-jdbc-${MSSQL_JDBC_VERSION}.jar"
  if [[ -f "$JDBC_JAR" ]]; then
    echo "✅ MS-SQL JDBC-Treiber bereits vorhanden: $JDBC_JAR"
  else
    echo "Lade Microsoft JDBC-Treiber ${MSSQL_JDBC_VERSION} herunter..."
    if download "$JDBC_URL" "$JDBC_JAR"; then
      as_root chown 1000:1000 "$JDBC_JAR" || true
      echo "✅ Treiber gespeichert: $JDBC_JAR"
      echo "   (wird beim Serverstart automatisch in den Nuclos-Classpath übernommen)"
    else
      echo "⚠️  Download fehlgeschlagen. Bitte manuell laden:"
      echo "   $JDBC_URL"
      echo "   und nach $JDBC_JAR kopieren."
    fi
  fi
fi

# nuclos uninstallscript #########################################################
cat > uninstall.sh <<'EOF'
#!/bin/bash
set -e
# Uninstall-Script für Nuclos Docker-Instanz
cd "$(dirname "$0")"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
echo "⚠️  Achtung: Diese Aktion entfernt alle Nuclos-Docker-Komponenten und Daten!"
read -p "Bist du sicher? (ja/nein): " confirm
if [[ "${confirm}" != "ja" ]]; then
  echo "Abbruch durch Benutzer."
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "❌ .env-Datei nicht gefunden. Abbruch."
  exit 1
fi
set -a; source ./.env; set +a

echo "🧨 Stoppe und entferne Container..."
docker compose down --volumes --remove-orphans

echo "🧨 Packe Datenverzeichnis..."
tar -czf "backup-nuclos-data${TIMESTAMP}.tar.gz" ./nuclos-data ./nuclos-extensions ./nuclos-backups
echo "🧨 Packe Datenbankverzeichnis..."
tar -czf "backup-nuclos-pgdata${TIMESTAMP}.tar.gz" ./nuclos-pgdata
echo "🧨 Packe Konfiguration (.env, docker-compose.yml, secrets)..."
tar -czf "backup-nuclos-config${TIMESTAMP}.tar.gz" .env docker-compose.yml secrets

echo "🧹 Entferne lokale Datenverzeichnisse..."
rm -rf nuclos-pgdata nuclos-data nuclos-extensions nuclos-backups nuclos-db-exchange nuclos-control secrets

echo "🗑️ Entferne Konfigurationsdateien..."
rm -f .env docker-compose.yml uninstall.sh backup-db.sh backup-instanz.sh restore-instanz.sh upgrade.sh

echo "✅ Nuclos-Docker-Instanz wurde vollständig entfernt."
echo "   Die backup-*.tar.gz Dateien bleiben zur Sicherheit liegen."
EOF

# ################################################################################
# BACKUP SCRIPTS #################################################################
# nuclos db backupscript #########################################################
cat > backup-db.sh <<'EOF'
#!/bin/bash
set -e
# Datenbank-Backup (pg_dump, Custom-Format) der Nuclos-Systemdatenbank
cd "$(dirname "$0")"
set -a; source ./.env; set +a

CONTAINER_NAME=${PREFIX}-db
BACKUP_DIR="./nuclos-db-backups"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Backup-Verzeichnis sicherstellen
mkdir -p "$BACKUP_DIR"

# Backup ausführen (Datenbank nuclosdb, Benutzer nuclos = Vorgabe der Images)
echo "Sichere Datenbank..."
docker exec "$CONTAINER_NAME" pg_dump -U nuclos -Fc nuclosdb > "$BACKUP_DIR/nuclosdb-backup-$TIMESTAMP.backup"

# Wiederherstellen mit:
#   docker exec -i <container> pg_restore -U nuclos -d nuclosdb --clean --if-exists < <datei>.backup

# Alte Backups nach 30 Tagen löschen
echo "Lösche alte Datenbankbackups älter >30 Tage..."
find "$BACKUP_DIR" -type f -name "*.backup" -mtime +30 -delete
EOF

# ################################################################################
# nuclos backup-instanz.sh #######################################################
cat > backup-instanz.sh <<'EOF'
#!/bin/bash
set -e
# Instanzbackup / Vollbackup (Datenbank-Dump + alle Daten- und Konfigdateien)
# Am besten als root ausführen (Verzeichnisse gehören den Container-Benutzern).
cd "$(dirname "$0")"
set -a; source ./.env; set +a

CONTAINER_NAME=${PREFIX}-db
BACKUP_DIR="./nuclos-instanzbackup"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

echo "⚠️  Instanzbackup / Vollbackup (Container werden kurz gestoppt)"
read -p "Bist du sicher? (ja/nein): " confirm
if [[ "${confirm}" != "ja" ]]; then
  echo "Abbruch durch Benutzer."
  exit 1
fi

# Backup-Verzeichnis sicherstellen
mkdir -p "$BACKUP_DIR"

# Datenbank-Dump ausführen
echo "Backup Database only..."
docker exec "$CONTAINER_NAME" pg_dump -U nuclos -Fc nuclosdb > "$BACKUP_DIR/nuclosdb-backup-$TIMESTAMP.backup"

echo "Lösche alte Backups >30 Tage..."
find "$BACKUP_DIR" -type f \( -name "*.backup" -o -name "*.tar.gz" \) -mtime +30 -delete

echo "🧨 Stoppe Container..."
docker compose down

echo "🧨 Packe Datenverzeichnis..."
tar -czf "$BACKUP_DIR/backup-nuclos-data$TIMESTAMP.tar.gz" ./nuclos-data ./nuclos-extensions ./nuclos-backups
echo "🧨 Packe Datenbankverzeichnis..."
tar -czf "$BACKUP_DIR/backup-nuclos-pgdata$TIMESTAMP.tar.gz" ./nuclos-pgdata
echo "🧨 Packe Konfiguration (.env, docker-compose.yml, secrets)..."
tar -czf "$BACKUP_DIR/backup-nuclos-config$TIMESTAMP.tar.gz" .env docker-compose.yml secrets

echo "✅ Nuclos-Docker-Instanz wurde vollständig gesichert."

echo "🧨 Starte Container neu..."
docker compose up -d
EOF

# ################################################################################
# Upgradescript ##################################################################
# ################################################################################
cat > upgrade.sh <<'EOF'
#!/bin/bash
set -e
# Nuclos Upgrade: Backup, neuen Image-Tag setzen, Images ziehen, neu starten.
# Es wird KEIN Installer-JAR mehr benötigt - das Upgrade erfolgt über den
# Image-Tag von https://hub.docker.com/r/nuccess/nuclos-server/tags
cd "$(dirname "$0")"
set -a; source ./.env; set +a

CONTAINER_NAME=${PREFIX}-db
BACKUP_DIR="./nuclos-instanzbackup"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

echo "⚠️  Nuclos Upgrade ausführen"
echo "Aktueller Nuclos-Server Tag: ${NUCLOS_SERVER_TAG}"
read -p "Neuer Tag [Enter für ${NUCLOS_SERVER_TAG}]: " NEW_TAG
NEW_TAG=${NEW_TAG:-$NUCLOS_SERVER_TAG}
read -p "Bist du sicher? (ja/nein): " confirm
if [[ "${confirm}" != "ja" ]]; then
  echo "Abbruch durch Benutzer."
  exit 1
fi

# Backup-Verzeichnis sicherstellen
mkdir -p "$BACKUP_DIR"

# Datenbank-Dump ausführen
echo "Backup Database only..."
docker exec "$CONTAINER_NAME" pg_dump -U nuclos -Fc nuclosdb > "$BACKUP_DIR/nuclosdb-backup-$TIMESTAMP.backup"

echo "🧨 Stoppe Container..."
docker compose down

echo "🧨 Packe Datenverzeichnis..."
tar -czf "$BACKUP_DIR/backup-nuclos-data$TIMESTAMP.tar.gz" ./nuclos-data ./nuclos-extensions ./nuclos-backups
echo "🧨 Packe Datenbankverzeichnis..."
tar -czf "$BACKUP_DIR/backup-nuclos-pgdata$TIMESTAMP.tar.gz" ./nuclos-pgdata
echo "🧨 Packe Konfiguration (.env, docker-compose.yml, secrets)..."
tar -czf "$BACKUP_DIR/backup-nuclos-config$TIMESTAMP.tar.gz" .env docker-compose.yml secrets

echo "✅ Backup abgeschlossen."

echo "Setze neuen Nuclos-Server Tag: ${NEW_TAG} ..."
sed -i "s|^NUCLOS_SERVER_TAG=.*|NUCLOS_SERVER_TAG=\"${NEW_TAG}\"|" .env

echo "Ziehe Images..."
docker compose pull

echo "🧨 Starte Container neu (Datenbank-Migration läuft automatisch)..."
docker compose up -d

echo "Fortschritt beobachten mit: docker compose logs -f server"
EOF

# ################################################################################
# Restore ########################################################################
# nuclos restore-instanz-script ##################################################
cat > restore-instanz.sh <<'EOF'
#!/bin/bash
set -e
# Instanz aus dem letzten Vollbackup (backup-instanz.sh) wiederherstellen.
# Am besten als root ausführen.
cd "$(dirname "$0")"

BACKUP_DIR="./nuclos-instanzbackup"
ARCHIVE_DIR="./nuclos-archiv"

echo "⚠️  Instanz zurückspielen / Möglicher Datenverlust ⚠️"
echo "Dadurch wird die aktuelle Instanz überschrieben"
read -p "Bist du sicher? (ja/nein): " confirm
if [[ "${confirm}" != "ja" ]]; then
  echo "Abbruch durch Benutzer."
  exit 1
fi

# Archiv-Verzeichnis sicherstellen
mkdir -p "$ARCHIVE_DIR"

# Jeweils das NEUESTE Backup-Set ermitteln
newest() { ls -1t "$BACKUP_DIR"/$1 2>/dev/null | head -n1; }
TAR_PGDATA=$(newest 'backup-nuclos-pgdata*.tar.gz')
TAR_DATA=$(newest 'backup-nuclos-data*.tar.gz')
TAR_CONFIG=$(newest 'backup-nuclos-config*.tar.gz')

if [[ -z "$TAR_PGDATA" || -z "$TAR_DATA" || -z "$TAR_CONFIG" ]]; then
  echo "❌ Kein vollständiges Backup-Set in $BACKUP_DIR gefunden. Abbruch."
  exit 1
fi
echo "Wiederherzustellendes Set:"
echo "  $TAR_PGDATA"
echo "  $TAR_DATA"
echo "  $TAR_CONFIG"

echo "🧨 Stoppe Container..."
docker compose down

echo "🧨 Entpacke Datenverzeichnisse..."
tar -xzf "$TAR_PGDATA"
tar -xzf "$TAR_DATA"
echo "🧨 Entpacke Konfiguration..."
tar -xzf "$TAR_CONFIG"

echo "🧨 Starte Container..."
docker compose up -d

echo "Aufräumen (verwendetes Set ins Archiv verschieben)..."
mv "$TAR_PGDATA" "$TAR_DATA" "$TAR_CONFIG" "$ARCHIVE_DIR"/
EOF

# ################################################################################
# Ausführbar machen ##############################################################
chmod +x backup-db.sh
chmod +x backup-instanz.sh
chmod +x uninstall.sh
chmod +x restore-instanz.sh
chmod +x upgrade.sh

echo ""
echo "Alle Konfigurationsdateien wurden erfolgreich erzeugt:"
echo "- .env"
echo "- docker-compose.yml"
echo "- secrets/db_password (+ .gitignore-Schutz)"
echo "- uninstall.sh"
echo "- backup-db.sh"
echo "- backup-instanz.sh"
echo "- restore-instanz.sh"
echo "- upgrade.sh"

# Container starten ##############################################################
if [[ $NO_START -eq 1 ]]; then
  echo ""
  echo "ℹ️  --no-start gesetzt: Container werden nicht gestartet."
  echo "   Start später mit: docker compose up -d"
else
  echo ""
  echo "Ziehe Docker-Images (nuccess/nuclos-db:${NUCLOS_DB_TAG}, nuccess/nuclos-server:${NUCLOS_SERVER_TAG})..."
  if ! docker compose pull; then
      echo "❌ Docker pull fehlgeschlagen"
      exit 1
  fi

  echo "Starte Docker-Container..."
  docker compose up -d

  echo ""
  echo "⏳ Hinweis: Der ERSTE Start dauert mehrere Minuten (automatisches"
  echo "   Datenbank-Setup). Fortschritt: docker compose logs -f server"
fi

# Zusammenfassung ################################################################
echo ""
echo "------------------------------------------------------------"
echo "✅ Installation abgeschlossen."
echo ""
echo "Nuclos Webclient:   http://<server-ip>:${NUCLOS_PORT}"
echo "Nuclos Startseite:  http://<server-ip>:${NUCLOS_PORT}/nuclos"
echo "Desktop-Client:     nuclos://<server-ip>:${NUCLOS_PORT}/nuclos"
echo "Standard-Benutzer:  nuclos (leeres Passwort) -> nach dem ersten"
echo "                    Login unbedingt Passwort setzen!"
if [[ "$MSSQL_PREP" =~ ^[JjYy] ]]; then
DISPLAY_MSSQL_HOST=${SAGE_MSSQL_HOST:-"<sage-server>"}
echo ""
echo "--- Sage 100 / MS-SQL Anbindung ----------------------------"
echo "In Nuclos eine externe Datenbankverbindung anlegen"
echo "(Administration -> Datenbankverbindungen), z.B. für Datenquellen"
echo "und dynamische Entitäten auf die Sage-100-Daten:"
echo ""
echo "  Treiber-Klasse: com.microsoft.sqlserver.jdbc.SQLServerDriver"
echo "  JDBC-URL:       jdbc:sqlserver://${DISPLAY_MSSQL_HOST}:${SAGE_MSSQL_PORT};databaseName=${SAGE_MSSQL_DB};encrypt=true;trustServerCertificate=true"
echo "  Benutzer:       ${SAGE_MSSQL_USER:-nuclos_ro}  (Passwort wird beim Anlegen der Verbindung in Nuclos eingegeben)"
if [[ -n "$SAGE_MSSQL_MANDANT" ]]; then
echo "  Mandant:        ${SAGE_MSSQL_MANDANT}  (in Datenquellen: WHERE Mandant = ${SAGE_MSSQL_MANDANT})"
fi
echo ""
echo "Empfehlung: Sage-seitig einen Read-only-Login und das Schema 'nuclos' mit"
echo "Views auf Adressen, Kunden, Artikel und Belege anlegen - fertige SQL-Skripte"
echo "und Datenquellen-Beispiele im Ordner sage100/ des Repos:"
echo "  https://github.com/protronic/docker-nuclos-installer/tree/main/sage100"
echo ""
echo "Voraussetzungen auf dem Sage/MS-SQL-Server:"
echo "  - TCP/IP im SQL Server Configuration Manager aktiviert (Port ${SAGE_MSSQL_PORT})"
echo "  - SQL-Server-Authentifizierung (Mixed Mode) + eigener Login,"
echo "    empfohlen nur mit Lesezugriff (db_datareader) auf die Sage-DB"
echo "  - Firewall: der Docker-Host muss ${DISPLAY_MSSQL_HOST}:${SAGE_MSSQL_PORT} erreichen"
if [[ "$SAGE_MSSQL_HOST" == "host.docker.internal" ]]; then
echo "  - 'host.docker.internal' zeigt auf den Docker-Host (MS-SQL läuft dort)"
fi
echo ""
echo "Der JDBC-Treiber liegt in ./nuclos-extensions/server/ und wird beim"
echo "Serverstart automatisch geladen."
fi
echo ""
echo "------------------------------------------------------------"
echo "               ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️ ⚠️               "
echo "Produktivbetrieb im Internet nur hinter einem Reverse-Proxy!"
echo "(siehe Beipiel-NGINX-Config.txt)"
echo "------------------------------------------------------------"
