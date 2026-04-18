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

**Хочешь двухнодовую цепочку** (entry + exit, чтобы миру был виден IP второй VDS, а не первой)? См. раздел [Двухнодовая цепочка](#двухнодовая-цепочка-entry--exit) ниже.

---

## Что делает скрипт

- Ставит и собирает Caddy с плагином `klzgrad/forwardproxy@naive` через xcaddy.
- Пишет Caddyfile с `basic_auth`, `probe_resistance`, маскировочным сайтом.
- Создаёт systemd-юнит, открывает 80/443 TCP + 443 UDP в UFW.
- Включает BBR, добавляет swap если RAM < 1.5 ГБ.
- **(опционально)** Поднимает Cloudflare WARP через `wgcf` + kernel WireGuard с policy routing: исходящий трафик идёт через Cloudflare, входящий 443 — через IP VDS.
- **(опционально)** Поддерживает топологию из двух нод (entry + exit): клиент коннектится к entry-домену, а наружу уходит с IP exit-ноды (или Cloudflare, если на exit включён WARP).

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
| `NODE_ROLE` | `standalone` (дефолт), `entry` или `exit`. Для chain-топологии см. раздел ниже |
| `UPSTREAM_DOMAIN` / `UPSTREAM_USER` / `UPSTREAM_PASS` | Координаты exit-ноды (нужны только для `NODE_ROLE=entry`) |
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

## Двухнодовая цепочка (entry + exit)

Нужна если хочешь спрятать «выходной» IP за второй VDS — клиент коннектится к entry-домену, а запросы наружу уходят с IP exit-ноды. Плюсы:

- Миру светится только entry-IP. Если его забанят — меняешь только entry, exit остаётся чистым.
- Entry можно взять поближе (низкий пинг из РФ), exit — в юрисдикции получше.
- На exit можно включить WARP — тогда трафик миру показывается от Cloudflare, а не от VDS.

### Порядок развёртывания

**1. Сначала поднимаешь exit-ноду** (домен B, VDS Y):

```bash
scp deploy-naive-server.sh root@<EXIT_VDS_IP>:/root/
ssh root@<EXIT_VDS_IP> 'NODE_ROLE=exit ENABLE_WARP=1 bash /root/deploy-naive-server.sh'
# Интерактивно: домен exit-ноды, email
```

В `/root/naive-credentials.txt` на exit найдёшь блок:
```
For a downstream ENTRY node, pass these values:
  UPSTREAM_DOMAIN=exit.example.com
  UPSTREAM_USER=<…>
  UPSTREAM_PASS=<…>
```

**2. Потом поднимаешь entry-ноду** (домен A, VDS X), передавая exit-креды:

```bash
scp deploy-naive-server.sh root@<ENTRY_VDS_IP>:/root/
ssh root@<ENTRY_VDS_IP> '
  NODE_ROLE=entry \
  UPSTREAM_DOMAIN=exit.example.com \
  UPSTREAM_USER=<из шага 1> \
  UPSTREAM_PASS=<из шага 1> \
  bash /root/deploy-naive-server.sh
'
```

На интерактивные вопросы отвечаешь:
- **Domain** / **Email** — для entry-ноды (не для exit).
- **HTML path** — что хочешь на заглушке entry-ноды.
- **`Route outbound traffic through Cloudflare WARP? [y/N]`** → **n**. На entry WARP не нужен: трафик и так уходит на exit-ноду по TCP/443, а WARP на entry — просто лишний хоп. Если всё-таки ответишь `y`, скрипт это пропустит но выдаст предупреждение.

В конце скрипт выполнит smoke-тест — curl через entry-прокси на `ifconfig.me`. Если вернётся IP exit (или Cloudflare при WARP на exit) — цепочка работает.

**3. Клиент настраиваешь на entry-домен:**

```
naive+https://ENTRY_USER:ENTRY_PASS@entry.example.com:443
```

Клиент даже не знает о существовании exit — для него это обычный naive-сервер.

### Правила

- **WARP ставь на exit, не на entry.** На entry он бесполезен (трафик и так идёт на exit по TCP/443).
- **exit-сервер публичный**: entry коннектится к нему по TCP/443 как обычный клиент. Никакой особой настройки фаервола на exit не нужно.
- **Entry использует HTTPS-upstream** (`upstream https://…` в Caddy).
- **Если exit недоступен** — entry перестанет проксировать. Имеет смысл держать запасной exit и переключаться правкой `/etc/caddy/Caddyfile` + `systemctl reload caddy`.

### Разворачивать обратно в standalone

```bash
NODE_ROLE=standalone bash /root/deploy-naive-server.sh
# или просто пропустить вопрос роли (дефолт = standalone)
```

Скрипт перегенерирует Caddyfile без `upstream`, и entry станет обычным naive-сервером (клиент сможет продолжать пользоваться теми же кредами).

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
