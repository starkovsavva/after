# Разработка

Нужны Apple Silicon, macOS 15+, Swift с SDK macOS 26+, Rust и Python 3.12.
Системный Liquid Glass применяется на macOS 26; на macOS 15 используется
матовое стекло. Снижение прозрачности и повышенный контраст имеют приоритет.

```bash
bash scripts/setup-rust.sh
python3 -m venv .test-data/checks
.test-data/checks/bin/python -m pip install numpy==2.2.6 imageio-ffmpeg==0.6.0
export POSLE_PYTHON="$PWD/.test-data/checks/bin/python"
python3 scripts/verify.py quick
bash scripts/build.sh
```

`verify.py --list` показывает профили:

- `quick`: сборка SwiftUI, SwiftPM core tests, Python contracts, Rust tests.
- `integration`: Rust CLI/C ABI, локальные HTTP-стенды, синтетическое аудио/видео, поиск и миграция модельной среды.
- `native`: SwiftUI и NSApplication в отдельных временных библиотеках. Нужна активная графическая сессия Mac; сценарии запускаются последовательно.
- `release`: все перечисленные проверки и настоящий Sparkle SDK на одноразовых подписанных приложениях. Ничего не публикует и не использует ключ подписи «После».

```bash
python3 scripts/verify.py integration
python3 scripts/verify.py native
python3 scripts/verify.py release --sparkle-root .build/artifacts/sparkle/Sparkle
```

Каталоги сборки можно задать через `POSLE_BUILD_DIR` и `POSLE_RUST_TARGET_DIR`.
Полный Xcode запускает core contracts через SwiftPM/XCTest. Если установлены только
Command Line Tools без XCTest, runner компилирует и запускает те же проверки через
`swiftc`; покрытие не пропускается.

`POSLE_PYTHON` выбирает тестовый Python; личная установленная библиотека приложения
не используется по умолчанию. `scripts/check.sh` сохранён как совместимый запуск `quick`.

Проверки создают собственные временные данные. Они не захватывают микрофон/экран,
не подключают календари, не читают существующие встречи и не вызывают платные API.
Нейросетевое качество распознавания проверяется отдельно с явно выбранными весами:
`--preview --check-embedded-speech --embedded-root "$PWD/.test-data" --full-flow`.
`scripts/smoke_audio.py` работает только с переданным пользователем аудио и root;
он не входит ни в один автоматический профиль.

## Границы кода

- `Sources/PosleApp`: SwiftUI/AppKit, устройства, календарь и координация действий.
- `Sources/PosleCore`: чистые модели, календарная геометрия и форматирование.
- `Sources/PosleApp/Diagnostics`: только DEBUG-сценарии с настоящим UI. Они остаются
  в модуле приложения для доступа к его жизненному циклу; release-сборка их исключает.
- `Tests`: SwiftPM-проверки PosleCore; `UpdateFixture.swift` — отдельное приложение
  для реального Sparkle E2E, не часть production app или core test target.
- `rust-core`: хранилище, поиск, AI-запросы, карточки и атомарные операции.
- `backend`: встроенный CPython для ASR, разделения голосов и медиа.

Очередь хранится в приватной SQLite-базе `jobs.sqlite`. Rust атомарно меняет
состояния, Swift actor управляет исполнителями: одна тяжёлая локальная операция,
до двух облачных и двух лёгких. У задания свой снимок настроек, ревизия входных
данных, отмена и номер попытки. Прерванные платные запросы требуют явного повтора.

Обновления работают через Sparkle с подписанным feed и
[Gentle Reminders](https://sparkle-project.org/documentation/gentle-reminders/).
Плановая проверка показывает действие в приложении; установка ждёт окончания
записи и обработки, закрытия редакторов и сохранения черновиков. Bundle ID
`app.posle.meetings` и путь `/Applications/После.app` сохраняются между версиями.

`build.sh` собирает приложение, `package.sh` упаковывает проверенный bundle,
`publish_release.py` публикует проверенные неизменяемые артефакты и подписанный feed.
Эти этапы не заменяют проверки. Базовый macOS build и `quick` запускаются в GitHub Actions.

Собственный код распространяется по [MIT](../LICENSE). Модели и сторонние
компоненты сохраняют свои лицензии: [THIRD_PARTY.md](../THIRD_PARTY.md).
