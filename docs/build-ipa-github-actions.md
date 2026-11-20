# Сборка IPA через GitHub Actions

Workflow: [.github/workflows/build-ipa.yml](../.github/workflows/build-ipa.yml). Он собирает приложение на
macOS-раннере GitHub, упаковывает `.ipa` и кладёт его артефактом запуска. Никакой публикации и никакого Apple ID не
нужно: сборка подписывается самоподписанным сертификатом из `build-system/fake-codesigning`, а на устройство
устанавливается только после переподписи своим сертификатом (Sideloadly, AltStore, Xcode).

## Что нужно один раз

1. Пустой репозиторий на GitHub (можно приватный).
2. Локальный клон этого дерева с полной историей — shallow-клон пушить нельзя:

   ```sh
   cd ayugram_ios
   git fetch --unshallow                 # один раз, ~1 ГБ
   git remote rename origin upstream     # чтобы случайно не пушить в TelegramMessenger
   git remote add origin git@github.com:<user>/<repo>.git
   git checkout -B master
   git add -A
   git commit -m "AyuGram iOS: kept deleted messages, fake premium, renamed app, CI"
   git push -u origin master
   ```

   Подмодули пушить не нужно: в репозитории лежат только gitlink-и, а сам workflow забирает их с upstream-URL из
   `.gitmodules` (поэтому `../tgcalls.git` там заменён на абсолютный адрес — иначе на форке он резолвился бы в
   несуществующий репозиторий).

## Запуск

Actions → **Build IPA** → Run workflow. Параметры:

- `configuration` — `release_arm64` (обычная сборка) или `debug_arm64`;
- `runner` — `xcode-27` по умолчанию; `xcode-27-xlarge` если на стандартном не хватит диска.

Готовый файл — внизу страницы запуска, раздел **Artifacts**: `AyuGram-release_arm64-<номер>.zip`, внутри `.ipa` и
`SHA256SUMS.txt`. Артефакты хранятся 7 дней.

## Установка на iPhone

1. Скачать артефакт, распаковать, получить `AyuGram-release_arm64-<номер>.ipa`.
2. Подписать своим сертификатом: **Sideloadly** (Windows/macOS), **AltStore**, **ESign** или Xcode.
   - бесплатный Apple ID: сертификат живёт 7 дней, не больше 3 приложений;
   - платный аккаунт разработчика: сертификат на год.
3. Приложение ставится рядом с официальным Telegram, если переподписать с другим bundle id (Sideloadly спрашивает
   это сам); с тем же `ph.telegra.Telegraph` официальное приложение будет заменено.

## Ограничения и что делать, если не собирается

- **Время.** Холодная сборка Telegram-iOS — это часы; задание ограничено 6 часами (`timeout-minutes: 355`).
  Кэш Bazel сохраняется только после успешного запуска, поэтому упавший по таймауту запуск не ускоряет следующий.
  Практика: первый прогон — `debug_arm64` на стандартном раннере (компилируется заметно быстрее, для личной сборки
  этого достаточно), `release_arm64` — на `xcode-27-xlarge`; либо self-hosted Mac, где кэш живёт между запусками.
- **Диск.** Стандартный macOS-раннер даёт ~14 ГБ; workflow удаляет лишние версии Xcode и симуляторы, но если
  сборка падает с `No space left on device` — запускать на `xcode-27-xlarge` (платные минуты, больше диск и ядра)
  или на своём Mac как self-hosted runner.
- **Xcode.** `versions.json` требует Xcode 27.1 / macOS 27 — это preview-label `xcode-27`. Если GitHub уберёт
  label, workflow возьмёт Xcode образа по умолчанию (флаг `--overrideXcodeVersion`), но сборка может упасть на
  SDK/Swift, если версия младше 27.
- **Подпись.** Самоподписанный `.ipa` не устанавливается сам по себе — только после переподписи (см. выше).
- **Старый workflow.** `.github/workflows/build.yml` — upstream-версия с `runs-on: macos-13` (этот образ больше не
  существует) и публикацией в Release: он не работает, его лучше удалить или не запускать.
