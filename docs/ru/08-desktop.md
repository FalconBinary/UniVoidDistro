# 08. Рабочий стол и изоляция приложений

> Модуль 8 промпта. Файлы: `/usr/local/bin/{vh-session,vh-wlfilter,vh-browse,refurswm,refursline}`,
> `/usr/local/sbin/vh-browser`, `/usr/local/libexec/vh/browser-sandbox`, `/etc/vh/firefox/*`,
> `/etc/pipewire/pipewire-pulse.conf.d/60-vh-sandbox.conf`,
> `/etc/wireplumber/wireplumber.conf.d/60-vh-sandbox.conf`, `/etc/apparmor.d/vh.*`.
> Исходники рабочего стола: `desktop/refurswm`, `desktop/refursline` (откуда — `desktop/UPSTREAM`).

## 1. Как запускается сеанс

```
agetty tty1 → login (PAM: пароль, pam_access, faillock, /run/user/UID)
 → bash -l → /etc/profile.d/zz-vh.sh: umask 077, PYTHONNOUSERSITE, LESSSECURE
 → exec /usr/local/bin/vh-session
     → /usr/local/bin/refurswm  (экран и ввод — через seatd)
         autostart: pipewire (+ wireplumber, pipewire-pulse), vh-wlfilter, refursline, swayidle
     ← RefursWM завершился (выход или падение)
     → kill -KILL -1   (ни один процесс пользователя не переживает сеанс)
 → снова приглашение входа, а не шелл
```

**seatd** вместо elogind: маленький root-демон, который выдаёт активному сеансу
дескрипторы `/dev/dri/card0` и устройств ввода и отбирает их при переключении на
другой VT. Пользователю не нужны группы `video` и `input` — достаточно `_seatd`.

**`kill -KILL -1` в конце сеанса.** Вредонос, отвязавшийся от сеанса (`setsid`, `nohup`,
двойной fork), переживает обычный выход. Здесь — нет: после RefursWM убиваются все
процессы этого UID. Процессы браузера (другой UID) завершаются через гибель их
родителя-doas: `bwrap --die-with-parent` убивает всю песочницу ([5](#5-браузер-в-песочнице)).

Тайм-ауты: блокировка через 5 минут простоя (`swayidle` → `swaylock`), «защищённая
комбинация» — `Super+L`.

## 2. RefursWM и что в нём важно для защиты

**RefursWM** — тайлово-скроллинговый композитор на Zig поверх wlroots 0.20 (раскладки
dwindle и scroll, `Super+Tab`). wlroots, libinput и libseat собраны из исходников (хеши в
`desktop/refurswm/build.zig.zon`) и вшиты в бинарник статически: ни X11, ни Xwayland, ни
Lua и glib в системе нет. Собирается установщиком в RAM live-среды
(`install/build-desktop.sh`), компилятор в систему не попадает.

**Конфиг компилируется в бинарник** — `desktop/refurswm/src/config.zig`. В `$HOME` нет
файла, который вредонос под пользователем мог бы дописать (`exec-once=…`): чтобы что-то
изменить, нужно пересобрать RefursWM из live-среды ([09](09-updates.md)). Ошибка в конфиге —
ошибка компиляции, а не сломанный сеанс.

Что в конфиге void-hardened важно для защиты:

| Настройка | Зачем |
|---|---|
| `grants` — только бар `/usr/local/bin/refursline` (`.shell`) | привилегированные протоколы (снимок экрана, буфер обмена в фоне, виртуальный ввод, гамма) не получает **никто** — ни программы из терминала, ни запущенные хоткеем |
| `rules`: `.app_id_prefix = "vh-sandbox"` → стол 9 | окна песочниц открываются на отдельном столе (метку ставит vh-wlfilter, раздел 3) |
| `lock_command = /usr/bin/swaylock` | абсолютный путь: свой `swaylock` в `$PATH` не подменит локер |
| `realtime = false` | лимит rtprio дал бы SCHED_RR любому процессу пользователя |
| абсолютные пути во всех хоткеях и автозапуске | поиск по `$PATH` не используется |

Что RefursWM делает сам, без настроек:
- **Нет IPC-сокета.** У mango и sway любой процесс пользователя через IPC запускал команды
  и менял привязки; здесь такого канала нет вовсе. Бар получает рабочие столы и тему по
  своему протоколу `refurs-shell`, который видит только программа с grant `.shell`,
  запущенная самим RefursWM (приватное соединение `WAYLAND_SOCKET`).
- **Фокус.** Окно песочницы не забирает клавиатуру при открытии; xdg-activation даёт фокус
  только по токену из окна, которое было в фокусе.
- **Буфер обмена** меняет только окно с клавиатурным фокусом — фоновое приложение не
  подменит скопированный адрес или команду.
- **Блокировка** (`ext-session-lock-v1`): «заблокировано» локер получает только после того,
  как каждый монитор показал кадр с заслонкой; упал локер — экран остаётся закрытым.
- **Своя песочница композитора**: лаунчер-процесс отделяется до ограничений и запускает
  программы; сам композитор — no_new_privs, не-dumpable, без capability, **Landlock** (читает
  `/usr /etc /sys /proc /run/udev`, пишет только в шейдерный кэш, `/dev/shm`, `/dev/dri`;
  TCP закрыт) и **seccomp** (нет exec/fork, ptrace, сетевых сокетов, mount, bpf, io_uring).
  В журнале при старте: `sandbox: landlock (ABI N), seccomp on`. `REFURS_SANDBOX=0` выключает
  её для диагностики на новом железе.
- **Сборка**: ReleaseSafe (проверки границ и переполнений), PIE, full RELRO, `_FORTIFY_SOURCE=3`,
  stack protector, CET для C-зависимостей.

Подробности и 45 проверок враждебным клиентом — `desktop/refurswm/README.md` и
`desktop/refurswm/tests/security.sh`.

## 3. Модель безопасности Wayland и vh-wlfilter

В X11 любое окно читает чужой экран и нажатия. В Wayland по умолчанию — нет, но
композиторы на wlroots обычно дают **любому клиенту** «привилегированные» протоколы:

| Протокол | Что даёт атакующему |
|---|---|
| `zwlr_screencopy`, `ext_image_copy_capture`, `zwlr_export_dmabuf` | снимки экрана — пароли, документы |
| `zwlr_data_control`, `ext_data_control` | чтение буфера обмена в любой момент |
| `zwp_virtual_keyboard`, `zwlr_virtual_pointer` | ввод команд в ваш терминал |
| `zwp_input_method_v2` | перехват ввода в полях других окон |
| `zwlr_layer_shell` | поддельный экран блокировки или запрос пароля поверх всего |
| `ext_session_lock` | захват блокировки экрана |
| `zwlr_foreign_toplevel`, `zwlr_gamma_control`, `zwlr_output_*` | список окон, управление экраном |
| `zwp_keyboard_shortcuts_inhibit` | отключить привязки композитора |

В RefursWM защита двухслойная.

**Слой 1 — RefursWM.** Привилегированные протоколы на основном сокете видят только
программы из `grants` (у нас — никто, кроме бара с его `refurs-shell`). Для песочниц есть
отдельный сокет `$XDG_RUNTIME_DIR/wayland-N-sandbox`: его клиенты не видят layer-shell,
session-lock, idle-notify и привилегированные протоколы вовсе (как security-context-v1 у
sway, но без участия клиента), не берут фокус при открытии окна и **не включают полный
экран сами** (это добавлено в копию RefursWM для void-hardened).

**Слой 2 — vh-wlfilter** (`zig/tools/vh-wlfilter.zig`, [17](17-zig-tools.md)) — прокси на Zig
перед сокетом песочниц:

```
Firefox ──/run/vh-sandbox/wayland──► vh-wlfilter ──$XDG_RUNTIME_DIR/wayland-0-sandbox──► RefursWM
          (сокет 0660, группа browser)  (процесс пользователя)
```

К основному сокету прокси не подключается: нет сокета песочниц — нет и прокси (ошибка при
старте). Что он делает:
1. **Белый список глобалов.** Клиент видит только объекты из списка `allowed[]`:
   compositor, shm, seat, output, xdg-shell, dmabuf, viewporter, fractional-scale,
   cursor-shape, буфер обмена `wl_data_device`, text-input… Всё прочее он просто не
   видит. RefursWM скрывает чёрный список, прокси — всё вне белого: протокол, добавленный
   в будущую версию wlroots, закрыт для песочницы, даже если его забыли внести в политику.
2. **Попытка угадать номер скрытого глобала** (`wl_registry.bind` с чужим номером)
   рвёт соединение.
3. **Пометка окон.** Каждое окно песочницы получает `app_id` «vh-sandbox.…» и заголовок
   «[песочница] …». Клиент не может это подделать: прокси переписывает его запросы.
   На этот app_id опирается правило RefursWM «стол 9».
4. **Запросы полноэкранного режима отбрасываются** (и вторым слоем — в RefursWM). Страница
   не нарисует во весь экран «экран блокировки» с полем пароля. Видео во весь экран —
   `Super+F` (решение принимает RefursWM, а не страница).

Цена: сообщения Wayland браузера проходят через лишний процесс — около 0,02 мкс
процессорного времени на сообщение и 0,5–1 МБ памяти ([замер](17-zig-tools.md#3-замеры)).
Буферы кадров передаются дескрипторами (dmabuf/shm), их содержимое через прокси не
копируется. Данные от браузера недоверенные: каждое поле читается после проверки длины,
ошибка разбора рвёт только это соединение.

**Что не закрыто.** Буфер обмена отдаётся окну, получившему фокус, — это
основа копирования и вставки. Правило: пароли копируйте с автоочисткой
(`wl-copy --paste-once`). Полноэкранное окно можно имитировать большим обычным
окном без рамок — поэтому «защищённая комбинация»: перед вводом пароля в любой
экран блокировки нажмите `Super+L`, настоящий swaylock ляжет поверх.

Проверка: из песочницы `wayland-info` (пакет `wayland-utils`) не должен показать ни
одного протокола из таблицы выше.

## 4. Звук песочницы

PipeWire поднимает дополнительный сокет PulseAudio для песочницы
(`/run/vh-sandbox/pulse`, `client.access = "restricted"`). Права «restricted»-клиентам
выдаёт WirePlumber: по умолчанию `rx` **на всё, включая микрофон** — видно и можно
подключить к своему потоку. Наш менеджер прав `vh-sandbox`
(`wireplumber.conf.d/60-vh-sandbox.conf`) делает источники звука и видео
(`Audio/Source`, `Video/Source` и т. п.) для таких клиентов невидимыми: воспроизведение
работает, запись — нет.

Проверка в песочнице: `pactl list short sources` пусто, `pactl list short sinks` — ваши выходы.

## 5. Браузер в песочнице

```
Super+B → vh-browse → doas /usr/local/sbin/vh-browser trusted      (правило без пароля, только этот аргумент)
  → [root] проверка DOAS_USER, наличие /run/vh-sandbox/wayland
  → exec nsenter --net=/proc/1/ns/net      (сеть init: если сеанс в пустом netns — optional/session-netns)
  → exec setpriv --reuid=browser --regid=browser --init-groups --reset-env
             --no-new-privs --inh-caps=-all --bounding-set=-all
  → exec browser-sandbox trusted                                      [uid browser]
  → exec bwrap …                                                      [новые namespace]
  → firefox
```

Каждая ступень — `exec`: родителем bwrap остаётся процесс doas, и когда сеанс
пользователя убивает свои процессы (`kill -KILL -1`), doas гибнет, а с ним
(`--die-with-parent`) — вся песочница.

### Почему отдельный пользователь

Разные UID — граница ядра: браузер не читает файлы пользователя (`/home/user` —
0700), не шлёт сигналы его процессам, не трогает их память. bwrap и AppArmor —
второй и третий слой поверх этой границы.

### bwrap: что видит Firefox

| | Внутри песочницы |
|---|---|
| `/usr` | только чтение |
| `/usr/lib/firefox` | собран заново: файлы пакета + наш `vh.cfg` и `vh-autoconfig.js`, только чтение |
| `/etc` | только fonts, ssl, resolv.conf, hosts, nsswitch.conf, localtime, ld.so.cache, политика Firefox; `passwd`/`group` — одна строка (имена других пользователей не видны) |
| `/proc` | свой (новый pid namespace), `/proc/interrupts`, `/proc/softirqs`, `/proc/stat` — пустые |
| `/dev` | минимальный; GPU — только render node i915 (доверенный профиль) |
| `/tmp`, `/dev/shm` | каталоги на хостовом tmpfs с `noexec` (этот флаг в user namespace снять нельзя) |
| `HOME` | `/var/lib/vh-browser/trusted` (постоянный, noexec) или пустой tmpfs (одноразовый) |
| `~/Downloads` | `/home/xfer` — общий с пользователем каталог |
| Wayland | только `/run/vh-sandbox/wayland` (vh-wlfilter) |
| звук | только `/run/vh-sandbox/pulse` |
| сеть | общая (`--share-net`), но nftables: 80/443 и QUIC, без LAN и localhost |
| D-Bus, основной сокет Wayland (и сокет песочниц RefursWM напрямую — только через vh-wlfilter) и PipeWire | нет |

Ключевые флаги: `--unshare-all --share-net` (свои pid, ipc, uts, cgroup, user namespace),
`--disable-userns --assert-userns-disabled` (внутри песочницы новые user namespace
создать нельзя — весь класс эксплойтов ядра «из своего userns»: nf_tables, overlayfs,
FUSE — закрыт), `--cap-drop ALL`, `--clearenv`, `--new-session` (нет TIOCSTI в чужой
терминал), `--die-with-parent`, `--seccomp 3`.

### seccomp-фильтр песочницы

`browser-sandbox` генерирует фильтр (`/usr/local/libexec/vh/vh-seccomp browser` — программа
на C: ассемблер classic BPF с метками; это данные, а не код) и передаёт его bwrap
дескриптором 3. bwrap применяет
его **после** сборки песочницы, его наследуют все процессы Firefox — поверх их
собственного фильтра контент-процессов, который не покрывает главный процесс.

| Вызов | Разрешено | Что закрывает |
|---|---|---|
| `socket` | AF_UNIX; AF_INET/AF_INET6 только TCP и UDP; AF_NETLINK только NETLINK_ROUTE | MPTCP, SCTP, UDP-Lite, сырые сокеты, AF_ALG, AF_PACKET, NETLINK_NETFILTER (nf_tables) |
| `socketpair` | AF_UNIX | — |
| `setsockopt` | всё, кроме `TCP_ULP` и `SO_ATTACH_*` (BPF на сокете) | kTLS/ULP и cBPF — поверхность ядра без привилегий |
| `clone` | без флагов `CLONE_NEW*` | новые namespace |
| `clone3` | → ENOSYS | флаги лежат в структуре по указателю — BPF их не видит; glibc откатывается на `clone` |
| `personality` | 0 и запрос | `READ_IMPLIES_EXEC`, `ADDR_NO_RANDOMIZE` |
| монтирование, `unshare`, `setns`, `bpf`, `perf_event_open`, `userfaultfd`, `keyctl`, `io_uring_*`, `kexec_*`, `modify_ldt`… | запрещены | классы LPE из песочницы |

Порядок инструкций выбран ради **кэша seccomp ядра**: архитектура и бит x32 — первыми,
затем вызовы с проверкой аргументов и запрещённые; всё прочее — безусловный ALLOW без
чтения аргументов. Для таких вызовов (read, write, mmap… — подавляющее большинство) ядро
запоминает решение и BPF не запускает: цена фильтра почти нулевая. Переходы в программе
считает мини-ассемблер с метками, а `vh-seccomp --selftest` прогоняет оба фильтра через
встроенный интерпретатор BPF на 48 вызовах с ожидаемым результатом (`vh-audit` делает
это при каждой проверке).

> Firefox умеет работать без user namespace: его собственная песочница контента
> (seccomp-bpf + брокер файлов) работает, теряется только его chroot/pid/net-слой —
> его заменяет bwrap. Проверка: `about:support` → «Песочница».
> Chromium без userns и без setuid-помощника не запускается — поэтому Firefox.

**Счётчики прерываний** (`/proc/interrupts`, `/proc/stat`) замаскированы: по ним код в
песочнице может восстановить тайминги нажатий клавиш — в том числе при вводе
пароля в swaylock.

### Два профиля

| | `vh-browse` (доверенный, `Super+B`) | `vh-browse untrusted` (`Super+Shift+B`) |
|---|---|---|
| Профиль | постоянный: логины, закладки, история | пустой при каждом запуске, исчезает после выхода |
| JIT | включён | **выключен** (`javascript.options.*`) — JS в разы медленнее, но исчезает главный класс RCE |
| GPU | render node i915: WebRender, VA-API | нет: программная отрисовка, WebGL и WebGPU выключены |
| Fullscreen API | работает внутри окна (прокси не даёт развернуть на экран) | выключен |
| Для чего | свои сайты: почта, банк, работа | всё остальное: ссылки, поиск, незнакомые сайты |

### Политики и autoconfig

Политики Firefox (`/etc/vh/firefox/policies-{trusted,untrusted}.json`) подставляются в
песочницу как `/etc/firefox/policies/policies.json` — на **установку**, а не на профиль:
скомпрометированный браузер не изменит их через `prefs.js`. Заблокированы:

- телеметрия, Studies, обновления самого Firefox (обновляет xbps);
- DoH (DNS только через unbound), включён HTTPS-only;
- **плагины GMP** (OpenH264 от Cisco, Widevine) и EME — закрытые бинарники, которые
  Firefox скачивает сам мимо репозитория. H.264 декодируется системным ffmpeg
  (`libavcodec6`) и VA-API;
- WebRTC; камера, микрофон, геолокация, уведомления — запрос сразу отклоняется;
- расширения: все запрещены, кроме uBlock Origin (ставится автоматически);
- `network.IDN_show_punycode` (домены-двойники видны как xn--…), автозаполнение
  паролей в формах выключено.

Политика `Preferences` разрешает не все настройки: `javascript.options.*` и
`app.normandy.*` запереть ею нельзя (проверено по документации политик). Их запирает
**autoconfig** (`vh-trusted.cfg`/`vh-untrusted.cfg`, `lockPref`): файлы
подмонтированы в каталог Firefox внутри песочницы, пакет их не перезаписывает.

## 6. Каталог обмена /home/xfer

Браузер скачивает в `~/Downloads` (внутри песочницы) = `/home/xfer`; у пользователя
`~/Downloads` — ссылка туда же. Права: владелец `browser`, группа `xfer` (оба
пользователя), `2770` (setgid — новые файлы получают группу xfer), ACL по умолчанию
`u:user:rwX, u:browser:rwX` — иначе файл, скачанный с umask 077, был бы нечитаем.

Монтирование `noexec,nosymfollow`: скачанное не запускается, а **симлинки, подложенные
браузером, не разыменовываются вообще** — ни редактором, ни архиватором
(`fs.protected_symlinks` в этом каталоге не действует: он не sticky-world-writable).

Не открывайте скачанное программами вне песочницы, если не доверяете файлу:
просмотрщики в песочнице — `optional/viewers` ([13](13-optional.md)).

## 7. Бар RefursLine

**RefursLine** (`desktop/refursline`) — бар только для RefursWM: один статический бинарник
`/usr/local/bin/refursline` на чистом Zig, без libc и libwayland, с меню внутри. Рабочие
столы, заголовок окна, режим раскладки, раскладку клавиатуры и тему он получает по протоколу
`refurs-shell`; запущенный не самим RefursWM (из терминала) — отказывается работать.

Сборка — вместе с RefursWM в RAM live-среды (`install/build-desktop.sh`):

- в репозитории Void есть только zig 0.13, а нужен 0.17 (тот же, что для своих инструментов
  и thor, `zig/ZIG_VERSION`) — компилятор скачивается с ziglang.org и проверяется подписью
  **minisign** и SHA-256;
- в установленную систему попадают только готовые бинарники (`/usr/local/bin`, root, 0755),
  quirks libinput (`/usr/local/share/refurswm/libinput`) и хэши в `/etc/vh/desktop.sha256`.
  Компилятора в системе нет;
- [ВНЕ ОГРАНИЧЕНИЙ]: бинарники не из репозитория Void. Смягчение: исходники в этом же
  репозитории (`desktop/`), wlroots/libinput/seatd — по хешу из `build.zig.zon`, сборка в
  проверенной live-среде, хэши для сверки (`vh-audit`).

Меню (`Super+D` лаунчер, `Super+N` Wi‑Fi, `Super+Shift+N` Bluetooth, `Super+P` обои,
`Super+C` календарь, `Super+Escape` питание):

| Меню | Через что работает |
|---|---|
| Wi‑Fi | iwd по D-Bus (группа `netdev`); пароль — своему агенту iwd, затирается сразу. 802.1X — профиль от админа `/var/lib/iwd/<SSID>.8021x` |
| Bluetooth | BlueZ; при `VH_BLUETOOTH=optional` переключатель сам запускает сервис (`doas vh-bluetooth on`) |
| Питание | без logind: `doas -n /usr/bin/reboot` / `poweroff` по правилам без пароля (запасного пути через sudo нет); блокировка и выход — через RefursWM; сна нет |
| Обои | рисует сам бар из `~/Pictures/wallpapers` (JPEG, PNG) — отдельной программы обоев нет |
| статус | sysfs и netlink — без демонов |

Собственная защита бара: seccomp (нет exec, новых сокетов, записи файлов), Landlock (чтение
только `/sys`, `/proc`, tzdata, шрифта и каталога обоев); программы запускает отдельный
broker, и только свои меню — по O_PATH-дескриптору собственного бинарника. Настройки бара —
`desktop/refursline/src/config.zig` (компилируются в бинарник, как и у RefursWM).

**Обновить или перенастроить RefursWM/RefursLine** — пересборка из live-флешки
([09](09-updates.md#рабочий-стол)): компилятора в системе нет намеренно.

## 8. AppArmor

**AppArmor** — LSM с профилями: для процесса под профилем ядро проверяет каждое
обращение к файлу, сети, capability, сигналу по правилам профиля — **даже у root и
даже внутри своего user namespace**. Профили загружаются в стадии 1
(`09-apparmor.sh` из `runit-void-apparmor`) до старта сервисов.

Профили базового слоя (`/etc/apparmor.d/vh.*`):

- **`vh.firefox`** — Firefox внутри песочницы. Запрещены: сетевые семейства, кроме
  inet и unix (в том числе `alg` — модули AF_ALG, загруженные для iwd, иначе доступны
  всем; `packet`), монтирование, capability `net_admin`, `net_raw`, `sys_module`,
  `sys_admin`, исполнение и mmap-исполнение из `/tmp`, `/dev/shm`, HOME и Downloads.
  `flags=(attach_disconnected)`: внутри bwrap пути вне корня песочницы «отсоединены».
- **`vh.unbound`, `vh.chronyd`, `vh.dhcpcd`, `vh.iwd`** — сервисы: только свои файлы,
  только нужные сетевые семейства и capability. `alg` разрешён только iwd.

```sh
doas aa-status                      # загруженные профили и процессы под ними
doas svlogtail kernel | grep apparmor   # отказы: operation, profile, name
```

Режим «complain» (только журнал, без запрета) для отладки профиля:
`doas aa-complain /etc/apparmor.d/vh.firefox`, обратно — `aa-enforce`.

## 9. Если сеанс не стартует

1. Войдите на tty2 админом: `doas cat /run/user/$(id -u user)/refurswm.log` — журнал RefursWM
   (строки `running on`, `sandbox:`, `cannot run …` — не найдена программа автозапуска).
2. `sv status seatd` — seatd работает? Пользователь в группе `_seatd`? (`id user`)
3. `ls -l /dev/dri/` — card0 и renderD128 есть?
4. Чёрный экран после входа — RefursWM упал, `vh-session` убил процессы и вернул login:
   смотрите refurswm.log. Если подозреваете его песочницу на новом железе — один раз
   запустите с `REFURS_SANDBOX=0` из tty1 (`REFURS_SANDBOX=0 /usr/local/bin/refurswm`) и сравните.

## Итог главы

| Защищает от | Остаточный риск | Цена в скорости | Цена в удобстве |
|---|---|---|---|
| Снимков экрана, чтения буфера, ввода в терминал, поддельных экранов из браузера и от любых программ пользователя (grants пусты); команд через IPC композитора (его нет); эксплойтов ядра из userns; доступа браузера к файлам пользователя, LAN, микрофону; закрепления через профиль и prefs; закрытых плагинов | Буфер обмена отдаётся окну в фокусе; большое окно без рамок вместо полноэкранного; поверхность i915 у доверенного профиля; процессы самого пользователя на основном сокете (без привилегированных протоколов, но со своими окнами) | прокси Wayland: мкс на сообщение; одноразовый профиль без JIT и GPU — в разы медленнее JS | Окна браузера на столе 9 без автофокуса; полноэкранный режим — Super+F; файлы для сайтов — через ~/Downloads |
