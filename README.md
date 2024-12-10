cd /usr/local/bin

wget --inet4-only https://raw.githubusercontent.com/datacenter-metrotel/Bind-Monitor-Autoritativo/refs/heads/main/disponibilidad.sh

wget --inet4-only https://raw.githubusercontent.com/datacenter-metrotel/Bind-Monitor-Autoritativo/refs/heads/main/monitor_bind_and_dns.sh

chmod +x disponibilidad.sh

chmod +x monitor_bind_and_dns.sh

crontab -e

*/1 * * * * /usr/local/bin/disponibilidad.sh
