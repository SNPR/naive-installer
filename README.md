# deploy-naive-server.sh

Turnkey-скрипт для разворачивания NaiveProxy-сервера на Ubuntu/Debian VDS.
Один файл, идемпотентный, интерактивный.

---

## TL;DR — за 5 минут с WARP

**Что надо заранее:** VDS (Ubuntu 22.04/24.04 или Debian 12, root по SSH) + купленный домен с A-записью на IP VDS. Cloudflare, если используешь — серое облако (proxy OFF).

Подключаешься по ssh и запускаешь одной строкой:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/SNPR/naive-installer/main/deploy-naive-server.sh)
```

С WARP сразу:

```bash
ENABLE_WARP=1 bash <(curl -Ls https://raw.githubusercontent.com/SNPR/naive-installer/main/deploy-naive-server.sh)
```

Скрипт интерактивно спросит: домен, email, путь к HTML-заглушке (Enter = пропустить), включить ли WARP, роль ноды (дефолт standalone).

Если хочешь — можно скопировать скрипт руками и запустить локально, поведение идентично:

```bash
scp deploy-naive-server.sh root@<VDS_IP>:/root/
ssh root@<VDS_IP> 'ENABLE_WARP=1 bash /root/deploy-naive-server.sh'
```

Через 3–7 минут увидишь:
```
Client URL: naive+https://USER:PASS@DOMAIN:443
```

Эту строку импортируешь в клиент ([NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases) / [NekoRay](https://github.com/MatsuriDayo/nekoray/releases) / [Karing](https://github.com/KaringX/karing/releases)) через «Импорт из буфера обмена». Логин/пароль также сохранятся в `/root/naive-credentials.txt` на сервере.

Проверка:
```bash
curl -x socks5h://127.0.0.1:1080 https://ifconfig.me   # должен вернуть IP Cloudflare
```

**Хочешь двухнодовую схему** (чистая «российская» нода впереди, заграничная позади — чтобы клиенту светить IP первой, а наружу ходить с IP второй)? См. раздел [Двухнодовая схема (forwarder + standalone)](#двухнодовая-схема-forwarder--standalone) ниже. Промежуточная нода — голый Ubuntu с iptables NAT, ни Caddy, ни домена там не нужно.

---

## Что делает скрипт

- Ставит и собирает Caddy с плагином `klzgrad/forwardproxy@naive` через xcaddy.
- Пишет Caddyfile с `basic_auth`, `probe_resistance`, маскировочным сайтом.
- Создаёт systemd-юнит, открывает 80/443 TCP + 443 UDP в UFW.
- Включает BBR, добавляет swap если RAM < 1.5 ГБ.
- **(опционально)** Поднимает Cloudflare WARP через `wgcf` + kernel WireGuard с policy routing: исходящий трафик идёт через Cloudflare, входящий 443 — через IP VDS.
- **(опционально)** Режим `forwarder` — отдельная L4 iptables-нода перед standalone-сервером. Кешируется в `/etc/ufw/before.rules`, не требует Caddy/сертификата/домена.

## Без интерактива (для автоматизации)

```bash
DOMAIN=example.com EMAIL=you@mail.com ENABLE_WARP=1 HTML_PATH=/root/my-site \
  bash /root/deploy-naive-server.sh
```

### Все переменные окружения

| Переменная | Назначение |
|---|---|
| `DOMAIN` | Твой домен (обязателен) |
| `EMAIL` | Email для Let's Encrypt (обязателен) |
| `HTML_PATH` | Путь на сервере к твоему `index.html` или папке с сайтом |
| `MASK_SITE` | URL стороннего сайта для `reverse_proxy` (альтернатива `HTML_PATH`) |
| `ENABLE_WARP` | `1` — включить wgcf+WARP, `0` — отключить (дефолт) |
| `NODE_ROLE` | `standalone` (дефолт) или `forwarder`. Для двухнодовой схемы см. раздел ниже |
| `ORIGIN_IP` | IP standalone-сервера, на который `forwarder` будет NAT'ить трафик (нужен только для `NODE_ROLE=forwarder`) |
| `NAIVE_USER` / `NAIVE_PASS` | Свои логин/пароль (иначе генерируются случайные) |
| `GO_VERSION` | Версия Go (дефолт: свежая с go.dev) |
| `SWAP_SIZE` | Размер swap если RAM мало (дефолт 2G) |
| `SKIP_UFW=1` | Не трогать firewall |
| `SKIP_BBR=1` | Не включать BBR |
| `REBUILD=1` | Пересобрать Caddy даже если бинарник уже есть |
| `NONINTERACTIVE=1` | Не спрашивать ничего, падать если чего-то не хватает |

## Типичные операции

### Обновить маскировочный сайт
```bash
scp -r ./my-site root@<VDS_IP>:/root/my-site
ssh root@<VDS_IP> 'HTML_PATH=/root/my-site bash /root/deploy-naive-server.sh'
```
Caddy не пересобирается — скрипт видит готовый бинарник и просто обновляет сайт.

### Включить/выключить WARP позже
```bash
ENABLE_WARP=1 bash /root/deploy-naive-server.sh   # включить
ENABLE_WARP=0 bash /root/deploy-naive-server.sh   # выключить (wgcf остановится, policy-routing снимется)
```

### Обновить сам сервер (раз в 2–3 месяца)
```bash
ssh root@<VDS_IP> 'REBUILD=1 bash /root/deploy-naive-server.sh'
```
Флаг `REBUILD=1` заставит пересобрать Caddy со свежим форк-плагином. Домен, креды, WARP — не трогаются.

### Обновить клиент
- NekoBox / NekoRay / Karing — обновляются сами через стор или встроенный updater.
- Сырой бинарник `naive` — скачиваешь новый релиз с [github.com/klzgrad/naiveproxy/releases](https://github.com/klzgrad/naiveproxy/releases) раз в 4–8 недель (синхронно с релизами Chrome Stable).

## Двухнодовая схема (forwarder + standalone)

Нужна когда хочешь чтобы миру светилась «чистая» нода (например, дешёвая российская), а сам naive-сервер жил на второй VDS за ней. Клиент коннектится к домену, чей A-record указывает на forwarder; forwarder на уровне ядра NAT'ит пакеты на origin, где стоит Caddy+naive. Плюсы:

- **Миру виден только IP forwarder'а.** Если его забанят — меняешь одну iptables-инструкцию или переезжаешь на новую дешёвую ноду, origin остаётся нетронутым.
- **Forwarder — голый Ubuntu**, 128MB RAM хватит. Ни Caddy, ни Go, ни сертификата, ни домена на нём не нужно.
- **Ноль TLS-in-TLS на forwarder'е** — клиент TLS-handshake'ится прямо с origin (через ядро). DPI на forwarder'е видит обычный зашифрованный TLS.
- **WARP можно включить на origin** — тогда трафик наружу уходит с IP Cloudflare. На forwarder'е WARP бессмысленен (L4, ничего не инициирует).

### Порядок развёртывания

**1. Поменяй A-запись домена → IP forwarder'а** (ещё до установки; пока никто не ответит, это нормально).

**2. На forwarder-VDS** (дешёвая RU-нода):

```bash
NODE_ROLE=forwarder ORIGIN_IP=<IP origin-сервера> \
  bash <(curl -Ls https://raw.githubusercontent.com/SNPR/naive-installer/main/deploy-naive-server.sh)
```

Интерактивно спросит только ORIGIN_IP, если не передал через env. Занимает ~10 секунд: установка `ufw`, прописывание NAT-правил в `/etc/ufw/before.rules`, открытие портов 80/443 TCP + 443 UDP.

**3. На origin-VDS** (заграничная нода, где будет жить сам naive):

```bash
NODE_ROLE=standalone \
  bash <(curl -Ls https://raw.githubusercontent.com/SNPR/naive-installer/main/deploy-naive-server.sh)
```

Интерактивно домен, email, HTML, WARP. Домен — тот же, который теперь указывает на forwarder. Caddy'шный ACME-flow для Let's Encrypt пройдёт **через forwarder** (ACME-сервер разрешит домен → forwarder IP → пакеты DNAT'нутся на origin → Caddy ответит). Никакой специальной настройки для этого не нужно.

**4. Клиент** получает обычный URL:

```
naive+https://USER:PASS@domain:443
```

Клиент думает что общается с сервером, стоящим на IP forwarder'а. На самом деле TLS-соединение терминируется на origin; forwarder лишь гонит пакеты туда-обратно.

### Проверка после установки

На forwarder:
```bash
sysctl net.ipv4.ip_forward                   # = 1
iptables -t nat -L PREROUTING -n -v | grep DNAT
ufw status verbose | grep "Default:"         # FORWARD: allow
```

На origin:
```bash
systemctl status caddy --no-pager
journalctl -u caddy -n 20 | grep certificate # ACME успешно обновил сертификат
```

С клиента:
```bash
curl -x socks5h://127.0.0.1:1080 https://ifconfig.me
# покажет IP origin (или Cloudflare если на origin включён WARP)
```

### Откат в одиночную ноду

Просто смени A-запись с forwarder'а обратно на origin IP — и всё. На forwarder ничего удалять не обязательно, он перестанет получать трафик. Если хочешь совсем снести — `rm /etc/ufw/before.rules && mv /etc/ufw/before.rules.naive-orig /etc/ufw/before.rules && ufw reload`.

### Почему именно такая модель (а не HTTPS-chain через Caddy upstream)

Короткая версия: L4 forwarding даёт **меньше TLS-слоёв** (клиент делает один TLS-handshake с origin, а не два через промежуточный Caddy), **меньше ресурсов** на промежуточном VDS и **проще в эксплуатации** (нет сертификатов, нет userspace-демонов в цепочке). Подробнее в комментариях к соответствующему коммиту.

## Проверка что всё живо

```bash
systemctl status caddy --no-pager
curl -I https://<домен>/                     # должен вернуть 200

# Если WARP включён:
curl -4 https://ifconfig.me                  # IP Cloudflare, не IP VDS
wg show wgcf                                 # туннель активен
ip rule show                                 # должны быть priority 100/200/300
```

## Логи и траблшутинг

```bash
journalctl -u caddy -n 50 --no-pager          # Caddy
journalctl -u wg-quick@wgcf -n 50 --no-pager  # WARP туннель
tail -50 /var/log/caddy/access.log            # app-события Caddy
```

**Частые проблемы:**

- **`Could not get certificate`** — A-запись не указывает на VDS, или 80/443 блокируются провайдером. Проверь `dig +short <домен>` и firewall у хостера.
- **Клиент не подключается после включения WARP** — тунель не поднялся. Скрипт сам откатит и останется без WARP; если не откатил, смотри `journalctl -u wg-quick@wgcf`.
- **xcaddy упал с OOM на 1 ГБ VDS** — скрипт создаёт swap сам, но если памяти совсем мало, поставь `SWAP_SIZE=4G`.
- **`Caddyfile input is not formatted`** — это warning, не ошибка, можно игнорировать.

## Что создаётся на сервере

| Путь | Что |
|---|---|
| `/usr/bin/caddy` | Собранный Caddy-бинарник |
| `/etc/caddy/Caddyfile` | Конфиг Caddy |
| `/etc/systemd/system/caddy.service` | systemd-юнит |
| `/var/www/html/` | Маскировочный сайт |
| `/var/log/caddy/` | Логи |
| `/root/naive-credentials.txt` | Логин/пароль и клиентский URL |
| `/etc/wireguard/wgcf.conf` | WARP-туннель (если включён) |
| `/etc/wireguard/wgcf-postup.sh` | Policy-routing для WARP |

## Архитектура WARP (кратко)

```
client --443-->  Caddy  -->  outbound target
                  │               │
                  │         table warp
                  │               │
                  ▼               ▼
               eth0 (reply)     wgcf --> Cloudflare --> target
               (fwmark=1)       (fwmark≠1)
```

Входящие коннекты на WAN помечаются CONNMARK=1, их ответы уходят обратно через `eth0`. Всё остальное (новые исходящие от Caddy) идёт через табличку `warp` и выходит через Cloudflare. Собственные UDP-пакеты WireGuard помечаются `FwMark=51820` самим ядром и тоже едут через `eth0`, чтобы не было loop.

## Credits

За основу проекта взят [klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy/tree/master).
