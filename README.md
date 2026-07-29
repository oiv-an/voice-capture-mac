# VoiceCapture 3.2.1 — быстрый голосовой ввод для macOS

Нативное menu bar-приложение на **Swift + AppKit**: зажимаешь **⌘ + ⌃**, говоришь,
отпускаешь — готовый текст вставляется в активное приложение.

Главное обновление линейки 3.2 — локальный движок **FluidAudio / NVIDIA Parakeet TDT v3**.
Он работает на Apple Neural Engine, поддерживает русский и показывает распознанный
текст прямо во время речи.

## Что нового в 3.2.1

- Live-текст переносится по словам и отображается в несколько строк.
- Оверлей автоматически растёт на полную высоту транскрипта без программного ограничения.
- Компактные статусы записи, распознавания, результата и ошибок остались прежнего размера.

## Что появилось в 3.2

- **FluidAudio / Parakeet TDT v3** — новый локальный backend в выпадающем меню.
- **Live-транскрипт** — текст появляется в нижнем оверлее во время удержания хоткея.
- После отпускания выполняется финальный проход, текст копируется и автоматически вставляется.
- Parakeet поддерживает **25 европейских языков**, включая русский, и определяет язык автоматически.
- Модель размером около **500 MB** скачивается и компилируется прямо из настроек.
- Инференс работает локально через **Core ML + Apple Neural Engine** — без отправки голоса в облако.
- Добавлены статус скачивания, повторная загрузка, открытие папки и удаление FluidAudio-модели.
- FluidAudio SDK зафиксирован на версии **0.15.5**.
- Обычные backend-ы `whisper.cpp`, Groq и совместный режим сохранены без изменений.

## Как это работает

### FluidAudio live

1. Открой **Настройки…**.
2. Выбери **FluidAudio (Parakeet v3 — live)**.
3. Нажми **Скачать** и дождись загрузки/оптимизации модели.
4. Нажми **Сохранить**.
5. Зажми **⌘ + ⌃** и говори — live-текст появится в оверлее примерно через 0,5–1 секунду.
6. Отпусти клавиши — финальный текст вставится в активное поле.

### Другие режимы

- **Локально (whisper.cpp)** — полностью офлайн, распознавание после отпускания хоткея.
- **Groq (облако)** — быстрое облачное распознавание через пользовательский API-ключ.
- **Совместно** — Groq стартует сразу, локальный Whisper подключается с заданной задержкой;
  побеждает первый успешный результат.

## Быстрый старт

1. Скачай последний релиз:
   [VoiceCapture Releases](https://github.com/oiv-an/voice-capture-mac/releases/latest).
2. Распакуй `VoiceCapture-3.2.1-macOS-arm64.zip`.
3. Перетащи `VoiceCapture.app` в `/Applications`.
4. Сними карантин, так как приложение подписано ad-hoc:

```bash
xattr -dr com.apple.quarantine /Applications/VoiceCapture.app
```

5. Запусти приложение и выдай два разрешения:
   - **Микрофон**;
   - **Accessibility / Универсальный доступ**.
6. Выбери движок в **Настройки…**, скачай нужную локальную модель и начинай диктовку.

## Требования

| Требование                  | Значение                                               |
| --------------------------- | ------------------------------------------------------ |
| macOS                       | **14.0 Sonoma или новее**                              |
| Процессор                   | **Apple Silicon M1+** для готового релиза и FluidAudio |
| Права                       | Microphone + Accessibility                             |
| FluidAudio-модель           | ~500 MB                                                |
| Whisper-модель по умолчанию | large-v3-turbo, ~1.6 GB                                |

> Релизный ZIP собирается под `arm64`. FluidAudio/Parakeet рассчитан на Apple Silicon.

## Первый запуск и разрешения

### Микрофон

**Системные настройки → Конфиденциальность и безопасность → Микрофон → VoiceCapture**.

### Accessibility

Нужен для глобального хоткея и эмуляции `Cmd+V`:

**Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → VoiceCapture**.

После выдачи разрешения перезапусти приложение.

### Gatekeeper

Приложение пока не подписано Apple Developer ID и не нотаризовано. Если macOS блокирует запуск:

```bash
xattr -dr com.apple.quarantine /Applications/VoiceCapture.app
open /Applications/VoiceCapture.app
```

## Модели

### FluidAudio / Parakeet TDT v3

Скачивается из окна настроек. Файлы хранятся в:

```text
~/Library/Application Support/FluidAudio/Models/
```

В menu bar при активном FluidAudio появляется пункт **«Удалить модель FluidAudio»**.

### whisper.cpp

Whisper-модели хранятся в:

```text
~/Library/Application Support/VoiceCapture/Models/
```

Скачать модель можно из настроек или скриптом:

```bash
./download_model.sh large-v3-turbo
```

Доступные варианты: `tiny`, `base`, `small`, `medium`, `large-v3`, `large-v3-turbo`.

## Настройки

Файл настроек:

```text
~/Library/Application Support/VoiceCapture/settings.json
```

Основные параметры:

- `backend`: `local` | `fluidAudio` | `groq` | `both`;
- `localModel`: файл выбранной Whisper-модели;
- `language`: `ru` | `en` | `auto` для Whisper/Groq;
- `initialPrompt`: prompt для Whisper/Groq;
- `groqApiKey`, `groqModel`;
- `autoPaste`;
- `localStartDelay` для совместного режима.

FluidAudio определяет язык автоматически; `language` и `initialPrompt` для него не используются.

## Сборка из исходников

### Требования для разработки

- Xcode / Swift toolchain с поддержкой Swift 6 package dependencies;
- `clang++`;
- интернет для загрузки SwiftPM-зависимости FluidAudio.

`cmake` и Homebrew для сборки `whisper.cpp` не нужны.

### Сборка

```bash
git clone https://github.com/oiv-an/voice-capture-mac.git VoiceCapture
cd VoiceCapture
./build_whisper.sh
swift build -c release
./build_app.sh
```

Результат:

```text
dist/VoiceCapture.app
```

`build_app.sh`:

1. собирает `whisper.cpp`, если статической библиотеки ещё нет;
2. выполняет release-сборку SwiftPM;
3. создаёт `.app` bundle и `Info.plist`;
4. подписывает бинарник и bundle стабильной ad-hoc подписью;
5. перезапускает приложение.

## Архитектура

```text
VoiceCapture/
├── Package.swift
├── Package.resolved
├── build_whisper.sh
├── build_app.sh
├── download_model.sh
├── search.js
├── Sources/
│   ├── CWhisper/
│   └── VoiceCapture/
│       ├── main.swift
│       ├── AppDelegate.swift
│       ├── Settings.swift
│       ├── SettingsWindowController.swift
│       ├── GlobalHotkeyMonitor.swift
│       ├── AudioRecorder.swift
│       ├── Recognizer.swift
│       ├── LocalWhisperRecognizer.swift
│       ├── FluidAudioRecognizer.swift
│       ├── GroqRecognizer.swift
│       ├── ClipboardManager.swift
│       ├── StatusController.swift
│       └── RecognitionHistory.swift
├── Vendor/whisper.cpp/
└── dist/VoiceCapture.app
```

### Live-пайплайн FluidAudio

- [`AudioRecorder`](Sources/VoiceCapture/AudioRecorder.swift) пишет 16 kHz mono Float PCM.
- [`AppDelegate`](Sources/VoiceCapture/AppDelegate.swift) периодически берёт потокобезопасный snapshot записи.
- [`FluidAudioRecognizer`](Sources/VoiceCapture/FluidAudioRecognizer.swift) распознаёт snapshot через Parakeet TDT v3.
- [`StatusController`](Sources/VoiceCapture/StatusController.swift) показывает live-текст в многострочном `NSTextView`; оверлей растёт на полную высоту транскрипта.
- После отпускания хоткея выполняется финальный проход по полной записи.

Код FluidVoice не копировался. Архитектура live-preview реализована самостоятельно поверх публичного FluidAudio API.

## Troubleshooting

### FluidAudio скачан, но live-текста нет

Убедись, что в настройках выбран и сохранён именно:

```text
FluidAudio (Parakeet v3 — live)
```

Выбор модели в строке ниже сам по себе не переключает backend.

### После отпускания текст есть, но live-текст задерживается

Первый запуск загружает Core ML-модели в память. После прогрева последующие диктовки быстрее.
Для нормального preview говори дольше 0,5–1 секунды.

### Хоткей не работает

Проверь Accessibility и перезапусти приложение. В menu bar есть пункт
**«Проверить доступ (Accessibility)»**.

### Авто-вставка не работает

Проверь Accessibility. Распознанный текст всё равно остаётся в буфере обмена и истории.

### Whisper галлюцинирует на тишине

Приложение фильтрует тихие записи по RMS и нормализует громкость, но качество всё равно
зависит от микрофона и уровня входа.

## Распространение

Локальные модели не входят в release ZIP:

- Parakeet скачивается из настроек в кэш FluidAudio;
- Whisper скачивается отдельно в каталог VoiceCapture.

Это держит ZIP приложения компактным. Для распространения без Gatekeeper-предупреждений
потребуются Apple Developer ID и notarization.

## Лицензии и атрибуция

- `whisper.cpp` — MIT, см. `Vendor/whisper.cpp/LICENSE`.
- FluidAudio SDK — Apache License 2.0.
- NVIDIA Parakeet TDT 0.6B v3 и Core ML weights — CC BY 4.0:
  - https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
  - https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- FluidVoice использовался как референс поведения, его GPLv3-код в проект не переносился.
