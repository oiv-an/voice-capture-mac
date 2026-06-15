# AI_INSTRUCTIONS — VoiceCapture 3.0 (macOS / Swift)

> **ПРОЧИТАЙ ЭТОТ ФАЙЛ ПЕРВЫМ.** Это стартовая инструкция для AI-ассистента по проекту.
> Язык общения: **русский**. Тон: инженер-инженеру, без воды.

---

## 1. Что это за проект

**VoiceCapture 3.0** — нативное macOS-приложение на **Swift + AppKit**.
Распознаёт речь и вставляет текст в активное приложение (hold-to-talk).

- Это **полностью отдельный проект**, переписанный с нуля на Swift.
- Старый проект — Python/PyQt6 (Windows) — лежит в соседней папке `../voice2.0`. **Его не трогаем.** Это был источник бизнес-логики.
- Владелец: Ivan Olyansky (Solo Founder). Приоритет: **скорость и работающий результат**, не академический код.

### Принцип работы (hold-to-talk)
1. Пользователь зажимает **⌘ + ⌃ (Cmd+Ctrl)**.
2. Идёт запись с микрофона.
3. Отпустил клавиши → аудио распознаётся → текст копируется в буфер → авто-вставка Cmd+V.

---

## 2. Ключевые решения (КОНТЕКСТ — почему так)

| Решение                                        | Причина                                                                                 |
| ---------------------------------------------- | --------------------------------------------------------------------------------------- |
| **Swift + AppKit**, не Python                  | Нативность, надёжные хоткеи, лёгкий .app                                                |
| **SwiftPM**, не Xcode-проект                   | Собирается из CLI (`swift build`), Xcode не обязателен для повседневной разработки      |
| **whisper.cpp локально**                       | Офлайн, приватно, бесплатно. Backend по умолчанию                                       |
| **Groq** как опция                             | Облачное распознавание, если нужно                                                      |
| **Корректор/постобработка УБРАНЫ**             | По требованию владельца — не нужен LLM-корректор                                        |
| **whisper.cpp собран на CPU+Accelerate**       | Metal Toolchain не ставился. CPU быстр для коротких диктовок. Metal — будущее улучшение |
| **Хоткеи через CGEventTap**                    | Нативно, надёжно, требует только Accessibility (не root)                                |
| Backend распознавания: только **Local + Groq** | OpenAI/OpenRouter из старого проекта НЕ переносим                                       |

---

## 3. Структура проекта

```
VoiceCapture/
├── AI_INSTRUCTIONS.md          # ← ЭТОТ ФАЙЛ
├── README.md                   # инструкция пользователя
├── Package.swift               # SwiftPM манифест
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

## 5. Модели whisper

Скачиваются скриптом в `~/Library/Application Support/VoiceCapture/Models/`:

```bash
./download_model.sh tiny|base|small|medium|large-v3
```

- Для русского лучше **large-v3** (точнее всего) или medium/small (баланс).
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
- `backend`: `local` | `groq`
- `localModel`: имя файла модели (напр. `ggml-large-v3.bin`)
- `language`: `ru` | `en` | `auto`
- `groqApiKey`, `groqModel`
- `autoPaste`: bool
- `hotkeyRequiresCommand/Control/Option/Shift`: какие модификаторы держать

---

## 8. ТЕКУЩИЕ ЗАДАЧИ / TODO (на момент написания)

- [x] **Выбор модели в UI** + скачивание прямо из настроек (список каталога, кнопка «Скачать», прогресс-бар). См. `SettingsWindowController.swift` + `WhisperModelInfo` в `Settings.swift`.
- [x] Дефолтная модель — **large-v3** (`Settings.swift`).
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
