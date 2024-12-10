#!/bin/bash

# Configuración
PAGERDUTY_TOKEN="60b1d6aff448459386bbcf5cb31dfee7"
HOSTNAME=$(hostname)
LOG_FILE="/var/log/dns/monitor_bind.log"
INCIDENT_KEY_BIND="bind-monitor-incident-$HOSTNAME"
INCIDENT_KEY_DNS="dns-monitor-incident-$HOSTNAME"
STATE_FILE_BIND="/var/run/bind_monitor_state"
STATE_FILE_DNS="/var/run/dns_monitor_state"
EXPECTED_IP="217.196.56.227"
DNS_SERVERS=("ns1.cps.com.ar" "ns2.cps.com.ar" "ns3.metrotel.ar")
DNS_QUERY="metrotel.com.ar"

# Asegurar que curl, dig y mkdir estén disponibles
if ! command -v curl &> /dev/null || ! command -v dig &> /dev/null || ! command -v mkdir &> /dev/null; then
    echo "Error: curl, dig y/o mkdir no están instalados. Por favor, instálalos para usar este script." | tee -a "$LOG_FILE"
    exit 1
fi

# Crear archivo de log si no existe
[ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"

# Crear directorio para los archivos de estado si no existe
mkdir -p "$(dirname "$STATE_FILE_BIND")"

# Función para registrar eventos en el log
log_event() {
    echo "$(date): $1" >> "$LOG_FILE"
}

# Función para enviar un evento a PagerDuty
send_pagerduty_event() {
    local action="$1"
    local summary="$2"
    local severity="$3"
    local incident_key="$4"
    
    curl_output=$(curl -X POST "https://events.pagerduty.com/v2/enqueue" \
        -H "Content-Type: application/json" \
        -d '{
            "routing_key": "'"$PAGERDUTY_TOKEN"'",
            "event_action": "'"$action"'",
            "dedup_key": "'"$incident_key"'",
            "payload": {
                "summary": "'"$summary"'",
                "source": "'"$HOSTNAME"'",
                "severity": "'"$severity"'"
            }
        }' 2>&1)
    
    if [ $? -ne 0 ]; then
        log_event "Error al enviar evento a PagerDuty: $curl_output"
    else
        log_event "Evento enviado a PagerDuty: $action - $summary"
    fi
}

# Verificar si el servicio BIND está activo
check_bind_service() {
    if ! systemctl is-active --quiet named; then
        log_event "El servicio BIND está caído. Notificando a PagerDuty e iniciando acciones correctivas."

        # Notificar a PagerDuty sobre la caída del servicio BIND
        send_pagerduty_event "trigger" "Problemas de resolución y disponibilidad del servidor BIND en $HOSTNAME" "critical" "$INCIDENT_KEY_BIND"

        # Actualizar archivo de estado para indicar que el incidente está activo
        echo "incident_active" > "$STATE_FILE_BIND"

        # Intentar reiniciar BIND con reintentos
        attempts=0
        max_attempts=3
        while ! systemctl is-active --quiet named && [ $attempts -lt $max_attempts ]; do
            log_event "Reintentando reiniciar named... intento $((attempts + 1)) de $max_attempts."
            systemctl restart named
            sleep 30
            ((attempts++))
        done

        if systemctl is-active --quiet named; then
            log_event "Servicio named reiniciado y funcionando correctamente."
            # Resolver el incidente en PagerDuty si estaba activo
            if [ -f "$STATE_FILE_BIND" ] && grep -q "incident_active" "$STATE_FILE_BIND"; then
                send_pagerduty_event "resolve" "Servicio BIND restaurado en $HOSTNAME" "info" "$INCIDENT_KEY_BIND"
                log_event "Incidente BIND resuelto y cerrado en PagerDuty."
                > "$STATE_FILE_BIND" # Limpiar archivo de estado
            fi
        else
            log_event "No se pudo recuperar named después de $max_attempts intentos."
            exit 1
        fi
    else
        log_event "El servicio BIND está funcionando correctamente. No se requiere acción."
        # Resolver el incidente en PagerDuty si estaba activo
        if [ -f "$STATE_FILE_BIND" ] && grep -q "incident_active" "$STATE_FILE_BIND"; then
            send_pagerduty_event "resolve" "Servicio BIND restaurado en $HOSTNAME" "info" "$INCIDENT_KEY_BIND"
            log_event "Incidente BIND resuelto y cerrado en PagerDuty."
            > "$STATE_FILE_BIND" # Limpiar archivo de estado
        fi
    fi
}

# Verificar consultas DNS
check_dns_resolution() {
    local issues_found=0

    for server in "${DNS_SERVERS[@]}"; do
        log_event "Consultando $DNS_QUERY en $server."
        result=$(dig @$server $DNS_QUERY +short)

        if [ "$result" != "$EXPECTED_IP" ]; then
            log_event "Respuesta inesperada de $server para $DNS_QUERY. Esperado: $EXPECTED_IP, Recibido: $result"
            issues_found=1
        else
            log_event "Respuesta correcta de $server para $DNS_QUERY: $result"
        fi
    done

    if [ $issues_found -eq 1 ]; then
        log_event "Se encontraron problemas de resolución y disponibilidad del servidor. Notificando a PagerDuty."
        send_pagerduty_event "trigger" "Problemas de resolución y disponibilidad del servidor para $DNS_QUERY en $HOSTNAME" "critical" "$INCIDENT_KEY_DNS"

        # Actualizar archivo de estado para indicar que el incidente está activo
        echo "incident_active" > "$STATE_FILE_DNS"
    else
        log_event "Todas las resoluciones DNS son correctas."

        # Resolver el incidente en PagerDuty si estaba activo
        if [ -f "$STATE_FILE_DNS" ] && grep -q "incident_active" "$STATE_FILE_DNS"; then
            send_pagerduty_event "resolve" "Resolución DNS restaurada para $DNS_QUERY en $HOSTNAME" "info" "$INCIDENT_KEY_DNS"
            log_event "Incidente DNS resuelto y cerrado en PagerDuty."
            > "$STATE_FILE_DNS" # Limpiar archivo de estado
        fi
    fi
}

# Ejecutar las verificaciones
check_bind_service
check_dns_resolution
