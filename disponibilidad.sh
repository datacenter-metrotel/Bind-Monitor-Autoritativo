#!/bin/bash

# Configuración
PAGERDUTY_TOKEN="60b1d6aff448459386bbcf5cb31dfee7"
HOSTNAME=$(hostname)
LOG_FILE="/var/log/dns/monitor_dns.log"
INCIDENT_KEY_DNS="dns-monitor-incident-$HOSTNAME"
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
mkdir -p "$(dirname "$STATE_FILE_DNS")"

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
            "routing_key": "'$PAGERDUTY_TOKEN'",
            "event_action": "'$action'",
            "dedup_key": "'$incident_key'",
            "payload": {
                "summary": "'$summary'",
                "source": "'$HOSTNAME'",
                "severity": "'$severity'"
            }
        }' 2>&1)
    
    if [ $? -ne 0 ]; then
        log_event "Error al enviar evento a PagerDuty: $curl_output"
    else
        log_event "Evento enviado a PagerDuty: $action - $summary"
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

# Ejecutar la verificación
check_dns_resolution
