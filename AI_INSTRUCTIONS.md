# AI_INSTRUCTIONS — VoiceCapture 3.3.0 (macOS / Swift)

> **ПРОЧИТАЙ ЭТОТ ФАЙЛ ПЕРВЫМ.** Это стартовая инструкция для AI-ассистента по проекту.
> Язык общения: **русский**. Тон: инженер-инженеру, без воды.

---

## 1. Что это за проект

**VoiceCapture 3.2.1** — нативное macOS-приложение на **Swift + AppKit**.
Распознаёт речь и вставляет текст в активное приложение (hold-to-talk). В backend
FluidAudio показывает промежуточный текст прямо во время записи. Live-оверлей использует
многострочный `NSTextView` и растёт на полную высоту транскрипта без программного лимита.

- Это **полностью отдельный проект**, переписанный с нуля на Swift.
- Старый проект — Python/PyQt6 (Windows) — лежит в соседней папке `../voice2.0`. **Его не трогаем.** Это был источник бизнес-логики.
- Владелец: Ivan Olyansky (Solo Founder). Приоритет: **скорость и работающий результат**, не академический код.

### Принцип работы (hold-to-talk)
1. Пользователь зажимает **⌘ + ⌃ (Cmd+Ctrl)**.
2. Идёт запись с микрофона.
3. Отпустил клавиши → аудио распознаётся → текст копируется в буфер → авто-вставка Cmd+V.

---

## 2. Ключевые решения (КОНТЕКСТ — почему так)

| Решение                                                     | Причина                                                                                 |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| **Swift + AppKit**, не Python                               | Нативность, надёжные хоткеи, лёгкий .app                                                |
| **SwiftPM**, не Xcode-проект                                | Собирается из CLI (`swift build`), Xcode не обязателен для повседневной разработки      |
| **whisper.cpp локально**                                    | Офлайн, приватно, бесплатно. Сохранён как отдельный backend и fallback                  |
| **FluidAudio / Parakeet v3** как опция                      | Локальный Core ML/ANE, русский + live-текст во время записи (Apple Silicon, macOS 14+)  |
| **Groq** как опция                                          | Облачное распознавание, если нужно                                                      |
| **Корректор/постобработка УБРАНЫ**                          | По требованию владельца — не нужен LLM-корректор                                        |
| **whisper.cpp собран на CPU+Accelerate**                    | Metal Toolchain не ставился. CPU быстр для коротких диктовок. Metal — будущее улучшение |
| **Хоткеи через CGEventTap**                                 | Нативно, надёжно, требует только Accessibility (не root)                                |
| Backend распознавания: **Local + FluidAudio + Groq + both** | OpenAI/OpenRouter из старого проекта НЕ переносим                                       |

---

## 3. Структура проекта

```
VoiceCapture/
├── AI_INSTRUCTIONS.md          # ← ЭТОТ ФАЙЛ
├── README.md                   # инструкция пользователя
├── Package.swift               # SwiftPM манифест
├── Package.resolved            # зафиксированные версии зависимостей (FluidAudio 0.15.5)
├── search.js                   # обязательный web-search runner для AI
├── build_whisper.sh            # сборка whisper.cpp → libwhisper_combined.a
├── build_app.sh                # swift build release + упаковка .app
├── download_model.sh           # скачивание ggml-моделей
├── Vendor/
│   ├── whisper.cpp/            # склонированный репозиторий (git, depth 1)
│   └── install/                # результат build_whisper.sh (lib + include)
├── Sources/
│   ├── CWhisper/               # C-обёртка над whisper.cpp
│   │   ├── include/            # заголовки whisper/ggml + CWhisper.h + module.modulemap НЕ нужен (target header)
│   │   └── shim.c
│   └── VoiceCapture/           # основной Swift-код
│       ├── main.swift              # точка входа (NSApplication.accessory)
│       ├── AppDelegate.swift       # КООРДИНАТОР: menubar, хоткеи, цикл записи
│       ├── Settings.swift          # модель настроек (Codable JSON)
│       ├── GlobalHotkeyMonitor.swift  # CGEventTap, hold-to-talk
│       ├── AudioRecorder.swift     # AVAudioEngine, 16kHz mono, WAV
│       ├── Recognizer.swift        # протокол Recognizer + ошибки
│       ├── LocalWhisperRecognizer.swift  # whisper.cpp
│       ├── FluidAudioRecognizer.swift    # Parakeet TDT v3 / Core ML / live snapshot ASR
│       ├── GroqRecognizer.swift    # Groq API
│       ├── ClipboardManager.swift  # NSPasteboard + Cmd+V
│       ├── StatusController.swift  # плавающий индикатор статуса
│       └── SettingsWindowController.swift  # окно настроек (AppKit)
└── dist/VoiceCapture.app       # собранное приложение
```

---

## 4. Как собирать и запускать

```bash
# Активный тулчейн (один раз; требует пароль админа)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# 1) Собрать whisper.cpp (один раз или после обновления Vendor)
./build_whisper.sh

# 2a) Запуск из исходников (быстро, для разработки)
swift run

# 2b) Сборка .app
./build_app.sh
open dist/VoiceCapture.app
```

> ВАЖНО про инструменты сборки whisper.cpp:
> - cmake/Homebrew **НЕ нужны**. `build_whisper.sh` компилирует исходники ggml+whisper напрямую через `clang++` с фреймворком Accelerate.
> - Версионные макросы (`GGML_VERSION`, `WHISPER_VERSION`, `GGML_COMMIT`) задаются через `-D` в скрипте (обычно их генерит cmake).
> - Если линковка падает на `dl_*`, `__cxa_*`, `ggml_backend_*` — проверь список исходников в `build_whisper.sh` (нужны `ggml-backend-meta.cpp`, `ggml-backend-dl.cpp`) и флаг `-lc++` в `Package.swift`.

---

## 5. Модели распознавания

### FluidAudio / Parakeet TDT v3

- Скачивается из окна настроек, размер около 500 MB.
- Хранится в `~/Library/Application Support/FluidAudio/Models/`.
- Поддерживает 25 европейских языков, включая русский; язык определяется автоматически.
- Live-preview: таймер 0.35с, первый проход после накопления 0.5с аудио, новый проход после каждых 0.25с новых samples.
- Каждый preview декодирует полный snapshot с новым `TdtDecoderState`, чтобы состояние не дублировало текст.
- Live-текст выводится через отдельный многострочный `NSTextView`; окно растёт на полную высоту текста без программного ограничения.
- При отпускании выполняется отдельный финальный pass по полной записи.

### whisper.cpp

Скачивается скриптом в `~/Library/Application Support/VoiceCapture/Models/`:

```bash
./download_model.sh tiny|base|small|medium|large-v3|large-v3-turbo
```

- Дефолт — **large-v3-turbo** (`ggml-large-v3-turbo.bin`, ~1.6 ГБ): быстрая и точная, лучший баланс.
- Максимум точности — **large-v3** (~3.1 ГБ), полегче — medium/small.
- Активная модель выбирается в Настройках (поле «Локальная модель»).

---

## 6. Разрешения macOS (обязательны)

1. **Микрофон** — `NSMicrophoneUsageDescription` в Info.plist, запрос автоматический.
2. **Accessibility (Универсальный доступ)** — для CGEventTap (хоткеи) и Cmd+V (вставка).
   Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → включить VoiceCapture → **перезапустить app**.

При смене бинарника (пересборке) разрешение Accessibility может «слетать» — TCC привязывается к подписи. Используется ad-hoc codesign в `build_app.sh`.

---

## 7. Хранение настроек

`~/Library/Application Support/VoiceCapture/settings.json` (Codable `AppSettings`):
- `backend`: `local` | `fluidAudio` | `groq` | `both` (дефолт — **`both`**)
- `localModel`: имя файла модели (дефолт — **`ggml-large-v3-turbo.bin`**)
- `language`: `ru` | `en` | `auto`
- `groqApiKey`, `groqModel`
- `autoPaste`: bool
- `microphoneUID`: String — CoreAudio device UID выбранного микрофона. Пусто = системный по умолчанию. Выбирается в Настройках («Микрофон»). `AudioRecorder` пересоздаёт `AVAudioEngine` на каждый `start()` и биндит вход через `kAudioOutputUnitProperty_CurrentDevice`.
- `localStartDelay`: Double (сек) — задержка перед запуском локального whisper в режиме `both` (дефолт 2.0, настраивается в UI, кламп 0…10). Декодирование настроек устойчиво к отсутствующим ключам (кастомный `init(from:)` с `decodeIfPresent ?? default`) — добавление новых полей не сбрасывает settings.json.
- Режим `both` — «совместный». Стратегия: сразу шлём Groq; если за `localStartDelay` Groq не дал результат — параллельно запускаем локальный whisper. Побеждает первый успешный непустой результат. Если Groq провалился раньше таймера — Local подключается немедленно. Работает только если задан Groq-ключ И скачана локальная модель (`parallelRaceApplicable`). Реализация — `AppDelegate.runParallel(...)`.
- `fluidAudio` использует отдельный async-пайплайн и не реализует синхронный протокол `Recognizer`. Язык определяется Parakeet автоматически; `language` и `initialPrompt` не применяются.
- `hotkeyRequiresCommand/Control/Option/Shift`: какие модификаторы держать

---

## 8. ТЕКУЩИЕ ЗАДАЧИ / TODO (на момент написания)

### Сделано в 3.3.0
- [x] **Выбор микрофона в UI** — popup «Микрофон» в настройках, список через CoreAudio (`AudioRecorder.availableInputDevices()`).
- [x] Первый пункт списка — системный микрофон по умолчанию (его имя показано в скобках).
- [x] Устройство сохраняется по UID (`microphoneUID`), применяется без перезапуска приложения.
- [x] `AVAudioEngine` пересоздаётся на каждый `start()` — иначе смена устройства нестабильна (кэш формата входа).
- [x] Фолбэк на системный микрофон, если сохранённое устройство исчезло.
- [x] Версия приложения и release bundle обновлены до 3.3.0.

### Сделано в 3.2.1
- [x] Live-оверлей переведён с однострочного `NSTextField` на многострочный `NSTextView`.
- [x] Текст переносится по словам; плашка растёт на полную высоту транскрипта без программного лимита.
- [x] Компактные статусы остаются размером 320×64.
- [x] Версия приложения и release bundle обновлены до 3.2.1.

### Сделано в 3.2
- [x] **FluidAudio / Parakeet TDT v3** — отдельный backend в UI, модель ~500 MB скачивается из настроек.
- [x] **Live-текст во время записи** — независимые проходы по полному snapshot; оверлей обновляется, при отпускании выполняется final pass и вставка.
- [x] Скачивание, прогресс Core ML-оптимизации, повторная загрузка, папка и удаление FluidAudio-модели.
- [x] FluidAudio SDK зафиксирован на `0.15.5` (Apache 2.0), модель — CC BY 4.0. Код GPLv3 FluidVoice не копировался.
- [x] Минимальная система поднята до macOS 14; готовый релиз и FluidAudio рассчитаны на Apple Silicon.
- [x] Версия приложения и release bundle обновлены до 3.2.0.

### Сделано в 3.1
- [x] **Совместный режим (`both`)** — Groq + Local «гонкой», дефолтный backend. См. `AppDelegate.runParallel(...)`.
- [x] **Настраиваемая задержка** запуска Local в режиме `both` (`localStartDelay`, дефолт 2.0, UI-поле).
- [x] **История распознаваний** (последние 10) + **счётчики** распознаваний/слов в меню-баре. См. `RecognitionHistory.swift`.
- [x] **Перезапуск из меню** (`⌘R`) — корректный рестарт процесса.
- [x] **Стабильная авто-вставка** (в т.ч. браузеры) + защита от второго экземпляра (flock).
- [x] Дефолтная модель — **large-v3-turbo** (`ggml-large-v3-turbo.bin`, ~1.6 ГБ), `Settings.swift`.
- [x] **Выбор модели в UI** + скачивание прямо из настроек (список каталога, кнопка «Скачать», прогресс-бар). См. `SettingsWindowController.swift` + `WhisperModelInfo` в `Settings.swift`.

### Backlog
- [ ] Возможно добавить **Metal-ускорение** whisper (требует установки Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`, затем пересобрать `build_whisper.sh` с `ggml-metal` и `use_gpu = true` в `LocalWhisperRecognizer`).
- [ ] Иконка приложения (сейчас системный символ `mic.fill`).
- [ ] Индикатор прогресса распознавания для длинных записей.
- [ ] Возможность настраивать сам хоткей в UI (сейчас фиксированно ⌘⌃, но в `Settings` уже есть поля `hotkeyRequires*`).

---

## 9. Правила работы (для AI)

- **Маленькие задачи/фиксы** → выдавай только код, без вступлений.
- **Сложные задачи/новые фичи** → сначала 2-3 варианта, дождись выбора, потом код.
- **Терминал** → по одной команде за раз, жди вывод.
- Не плоди over-engineering. Хардкод и «грязные» решения ОК, если работают.
- Тесты не пишем.
- Всё общение — на русском.
