# 📊 Node Exporter Install Script with TLS

Автоматизированный скрипт для быстрой установки **Node Exporter** с TLS-шифрованием на VPN-ноды для мониторинга через **Prometheus + Grafana**.

## 🚀 Быстрый старт

### На ноде — установка Node Exporter

```bash
curl -fsSL https://raw.githubusercontent.com/ibmaga/node-exporter-install/main/node-exporter-install.sh -o ne-install.sh
chmod +x ne-install.sh
sudo ./ne-install.sh --prometheus-ip <IP_PROMETHEUS_SERVER>
```

### На сервере мониторинга — добавить ноду в Prometheus

```bash
curl -fsSL https://raw.githubusercontent.com/ibmaga/node-exporter-install/main/prometheus-add-node.sh -o add-node.sh
chmod +x add-node.sh
sudo ./add-node.sh --ip <NODE_IP> --name <NODE_NAME>
```

### Пример

```bash
# На ноде example:
sudo ./ne-install.sh --prometheus-ip 193.39.208.155

# На сервере мониторинга:
sudo ./add-node.sh --ip 37.139.33.63 --name example
```

## 📋 Что делает скрипт

- ✅ Устанавливает Node Exporter v1.10.2
- ✅ Генерирует self-signed TLS сертификат (10 лет)
- ✅ Создаёт systemd сервис с автозапуском
- ✅ Автоматически находит свободный порт (по умолчанию 9101)
- ✅ Настраивает UFW firewall (доступ только с IP Prometheus)
- ✅ Проверяет что всё работает

## ⚙️ Параметры

### node-exporter-install.sh (на ноде)

| Параметр | Описание | По умолчанию |
|---|---|---|
| `-p, --prometheus-ip` | IP адрес Prometheus сервера | *обязательный* |
| `-P, --port` | Порт Node Exporter | `9101` |
| `-n, --hostname` | Hostname для сертификата | автоопределение |
| `-i, --node-ip` | IP ноды для сертификата | автоопределение |
| `-v, --version` | Версия Node Exporter | `1.10.2` |
| `-h, --help` | Справка | |

### prometheus-add-node.sh (на сервере мониторинга)

| Параметр | Описание | По умолчанию |
|---|---|---|
| `-i, --ip` | IP адрес ноды | *обязательный* |
| `-P, --port` | Порт Node Exporter на ноде | `9101` |
| `-n, --name` | Имя ноды (комментарий) | |
| `-d, --dir` | Директория Prometheus | `/opt/prometheus` |
| `-l, --list` | Показать все таргеты и их статус | |
| `-r, --remove` | Удалить ноду по IP | |
| `-h, --help` | Справка | |

### Примеры

```bash
# === На ноде ===

# Базовая установка
sudo ./ne-install.sh -p 193.39.208.155

# Указать порт и hostname
sudo ./ne-install.sh -p 193.39.208.155 -P 9100 -n my-vpn-node

# Полная кастомизация
sudo ./ne-install.sh --prometheus-ip 10.0.0.1 --port 9100 --hostname example --node-ip 37.139.33.63

# === На сервере мониторинга ===

# Добавить ноду
sudo ./add-node.sh --ip 37.139.33.63 --name example

# Список всех таргетов с проверкой
sudo ./add-node.sh --list

# Удалить ноду
sudo ./add-node.sh --remove 37.139.33.63
```

## 🏗️ Архитектура

```
┌─────────────────┐         ┌─────────────────┐
│  Prometheus +   │  HTTPS  │   VPN Node 1    │
│  Grafana        │◄───────►│  node_exporter  │
│  Server         │         │  :9101 (TLS)    │
│                 │         └─────────────────┘
│                 │         ┌─────────────────┐
│                 │  HTTPS  │   VPN Node 2    │
│                 │◄───────►│  node_exporter  │
│                 │         │  :9101 (TLS)    │
│                 │         └─────────────────┘
│                 │         ┌─────────────────┐
│                 │  HTTPS  │   VPN Node N    │
│                 │◄───────►│  node_exporter  │
│                 │         │  :9101 (TLS)    │
└─────────────────┘         └─────────────────┘
```

## 📈 Настройка Prometheus

После установки на ноде добавьте таргет в `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'vpn-nodes'
    scheme: https
    tls_config:
      insecure_skip_verify: true
    static_configs:
      - targets:
        - '<NODE_IP>:9101'
    relabel_configs:
      - source_labels: [__address__]
        regex: '(.*):\d+'
        target_label: instance
        replacement: '${1}'
```

Перезагрузите конфиг:

```bash
cd /opt/prometheus && docker compose restart prometheus
```

## 📊 Настройка Grafana

1. Откройте Grafana → **Connections → Data Sources → Add Prometheus**
2. URL: `http://prometheus:9090`
3. **Save & Test**
4. **Dashboards → Import → ID: 1860 → Load**
5. Выберите Data Source: Prometheus → **Import**

## 🔧 Управление

```bash
# Статус
systemctl status node_exporter

# Перезапуск
systemctl restart node_exporter

# Логи
journalctl -u node_exporter -f

# Проверка метрик
curl -k https://localhost:9101/metrics | head -5

# Проверка сертификата
openssl s_client -connect localhost:9101 -tls1_2 </dev/null 2>&1 | grep -E "(Protocol|Cipher)"
```

## 🔒 Безопасность

- TLS шифрование метрик (self-signed, 10 лет)
- Firewall: доступ только с IP Prometheus сервера
- Порт 9101 не открыт для всех

## 🔍 Полезные PromQL запросы

```promql
# CPU Usage %
100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory Usage %
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# Disk Usage %
(1 - (node_filesystem_avail_bytes{fstype!="tmpfs"} / node_filesystem_size_bytes{fstype!="tmpfs"})) * 100

# Network Traffic (bytes/sec)
irate(node_network_receive_bytes_total{device="eth0"}[5m])
irate(node_network_transmit_bytes_total{device="eth0"}[5m])
```

## 🛠️ Troubleshooting

### Port already in use

Скрипт автоматически найдёт свободный порт. Или укажите вручную:

```bash
sudo ./ne-install.sh -p 193.39.208.155 -P 9102
```

### Prometheus не видит ноду

1. Проверьте firewall: `ufw status | grep 9101`
2. Проверьте доступность: `curl -k https://<NODE_IP>:9101/metrics` с сервера Prometheus
3. Проверьте `prometheus.yml` — правильный IP и порт
4. Убедитесь что `scheme: https` указан

### Сервис не запускается

```bash
journalctl -u node_exporter --no-pager -n 20
```

## 📄 Лицензия

MIT License

## 🙏 Благодарности

- [Prometheus](https://prometheus.io/)
- [Node Exporter](https://github.com/prometheus/node_exporter)
- [Grafana](https://grafana.com/)
- [Remnawave](https://github.com/remnawave)
