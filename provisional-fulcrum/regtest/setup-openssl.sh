#!/bin/bash

# Ruta del directorio de trabajo
WORK_DIR="/home/safeuser"
LOG_FILE="$WORK_DIR/setup-openssl.log"

# Crea un nuevo archivo de log
echo "Inicio de la configuración de OpenSSL" > "$LOG_FILE"

# Cambia al directorio de trabajo
if [ ! -d "$WORK_DIR" ]; then
  echo "Directorio de trabajo $WORK_DIR no existe." >> "$LOG_FILE"
  exit 1
fi

cd "$WORK_DIR" || { echo "No se pudo cambiar al directorio $WORK_DIR" >> "$LOG_FILE"; exit 1; }

# Verifica la versión de OpenSSL
{
    echo "Verificando versión de OpenSSL..."
    openssl version >> "$LOG_FILE" 2>&1
} || {
    echo "Error al verificar la versión de OpenSSL." >> "$LOG_FILE"
    exit 1
}

# Genera una clave privada sin frase de contraseña
{
    echo "Generando clave privada..."
    openssl genrsa -out server.key 2048 >> "$LOG_FILE" 2>&1
} || {
    echo "Error al generar la clave privada." >> "$LOG_FILE"
    exit 1
}

# Verifica si la clave privada se ha creado
if [ ! -f "server.key" ]; then
  echo "No se pudo generar la clave privada." >> "$LOG_FILE"
  exit 1
fi

# Crea una solicitud de firma de certificado (CSR)
{
    echo "Generando CSR..."
    openssl req -new -key server.key -out server.csr -config openssl.cnf -batch >> "$LOG_FILE" 2>&1
} || {
    echo "Error al generar la solicitud de firma de certificado (CSR)." >> "$LOG_FILE"
    exit 1
}

# Verifica si la solicitud de firma de certificado (CSR) se ha creado
if [ ! -f "server.csr" ]; then
  echo "No se pudo generar la solicitud de firma de certificado (CSR)." >> "$LOG_FILE"
  exit 1
fi

# Genera un certificado auto-firmado
{
    echo "Generando certificado..."
    openssl x509 -req -sha256 -days 365 -in server.csr -signkey server.key -out server.crt -extensions req_ext -extfile openssl.cnf >> "$LOG_FILE" 2>&1
} || {
    echo "Error al generar el certificado." >> "$LOG_FILE"
    exit 1
}

# Verifica si el certificado se ha creado
if [ ! -f "server.crt" ]; then
  echo "No se pudo generar el certificado." >> "$LOG_FILE"
  exit 1
fi

# Elimina los archivos temporales si existen
{
    echo "Eliminando archivos temporales..."
    rm -f server.csr >> "$LOG_FILE" 2>&1
} || {
    echo "Error al eliminar los archivos temporales." >> "$LOG_FILE"
}

echo "Proceso completado exitosamente." >> "$LOG_FILE"

