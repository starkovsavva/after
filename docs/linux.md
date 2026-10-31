# Разработка на Arch Linux

Текущий Linux-срез Tauri: библиотека, заметки, папки, задачи/карточки и импорт медиа.
Запись Linux, ASR, конспектирование, календарь и полный паритет со Swift-клиентом
ещё находятся в плане: [этапы](linux-implementation-plan.md), [аудит](linux-portability-audit.md).

## Подготовка

Нужны Rust stable, Node 24+, npm, Python 3, C/C++ toolchain и pkg-config.
Для существующего Tauri-host требуется именно GTK3/WebKitGTK 4.1:

```sh
sudo pacman -S --needed base-devel pkgconf rust nodejs npm python webkit2gtk-4.1
pkg-config --modversion gtk+-3.0 webkit2gtk-4.1 openssl
cd desktop
npm ci --ignore-scripts
cd ..
```

`webkitgtk-6.0` не предоставляет `webkit2gtk-4.1.pc` для этой сборки.
Для выбора файлов нужна рабочая desktop-сессия с реализацией системного диалога;
Linux rfd использует portal backend. Наличие пакета portal не подтверждает работу
конкретного графического окружения. Поддержку медиа/кодеков проверяйте отдельно.

## Проверки и запуск

```sh
python3 scripts/verify.py desktop
cargo build --manifest-path rust-core/Cargo.toml --locked --target-dir .build/rust
python3 scripts/stage-desktop-engine.py
cd desktop
AFTER_DATA_DIR=/absolute/path/to/disposable-library npm run tauri dev
```

Профиль `desktop` не запускает Swift: Rust-регрессия, build движка, frontend build/tests,
host tests и ignored интеграции настоящего engine через transport и Tauri IPC.
Он не заменяет графический smoke и не захватывает устройства. В CI Ubuntu также
проходят browser-интеграции; это отдельный уровень проверки от Linux WebView.

Стадируйте движок заново после изменений ядра и пересобирайте host: digest встроен
при сборке. Не подключайте живую библиотеку Mac-клиента. Preview сохраняет свою
библиотеку `app.posle.desktop`. Для сборки release engine обязателен в resources.

## Архитектурные границы

Общие типы настроек находятся в `rust-core/src/domain/config.rs` без I/O и runtime.
`ai_config` отвечает за чтение/разрешение профилей и пока относится к application/
infrastructure, а не к чистому domain. File picker изолирован в host `platform.rs`.
Engine объявляет общие tasks/cards; host дополняет capabilities своими адаптерами.
Запись доступна только там, где реализован capture backend.

## Автономная debug-сборка и native smoke

```sh
cd desktop
CARGO_TARGET_DIR="$PWD/../.build/tauri" npm run tauri -- build --debug --no-bundle --features custom-protocol
cd ..
python3 scripts/check-desktop-linux.py --app .build/tauri/debug/After --receipt .build/linux-native-smoke.json
```

Для автономной debug-сборки нужен `custom-protocol`; без него приложение ожидает
Vite dev server. Smoke запускает настоящее окно в графической сессии, проверяет
инициализацию canonical SQLite через UI/IPC/встроенный engine и завершает процесс.
Данные временные, личная библиотека не используется. Это проверка старта, не полный
UI-сценарий и не проверка нормального закрытия окна пользователем.
`AFTER_WEBVIEW_DIAGNOSTICS=1` включает консоль WebView и коды ошибок host только
в debug; не включайте её при работе с личными материалами.

## Подтверждённый срез

Локально на Arch прошли portable-профиль (418 core + 4 CLI теста, frontend build/test,
host-тесты, 2 real-engine интеграции и настоящий Tauri IPC-сценарий) и native
WebView startup smoke с bundled engine. Сценарий IPC также импортирует синтетический
файл и проверяет чтение диапазона медиа. После исправления resource locator добавлен
отдельный регрессионный тест; финально 20 host-тестов, включая настоящий IPC, прошли. Диалог выбора файла, кодеки и физические устройства
этим не проверены. Ubuntu/Arch/Windows workflows настроены, их удалённый прогон
не выполнялся в этой сессии.
