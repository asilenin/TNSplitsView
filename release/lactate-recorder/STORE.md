# Lactate Recorder — первая загрузка в магазин

Это новое приложение, не обновление TN Splits View. Поле кругов в магазине не трогать. Номер версии в кабинете — 1.0.0. Загрузка обычная, не «for testing»: тестовая загрузка получает другой app id.

Пакет: `Lactate-Recorder.iq`, 1 784 730 байт. SHA-256 `ebefdd2a4b7c3aaab5b9fc279b63c5dd1d37d0d052381e727a2253bd15c9c7d1`. Внутри 82 прошивочных варианта, подписи на месте, app id `2b241dea-ad65-4ba7-ad89-aff113dfd2ac`. Кабинет: https://apps.garmin.com/en-US/developer/upload

Снимки экрана и Hero собраны из тех же шрифтов и координат, что рисует поле. Это не фотография часов и не кадр симулятора: симулятор тап этого поля не показывает. Цифры на снимках учебные. Если нужны кадры с часов, их можно подменить.

- `screenshots/01-list-dark.png` и `02-list-light.png` — 454×454, список.
- `screenshots/03-entry-dark.png` и `04-entry-light.png` — 454×454, ввод. Буквы здесь шрифт Golos; на часах ввод рисуется системным шрифтом, раскладка та же.
- `hero/Lactate-Recorder-Cover.png` — обложка кабинета 500×500, 58 275 байт, меньше предела 300 КБ. Это круглый список на чёрном поле.
- `hero/Lactate-Recorder-Hero.png` — 1440×720, 256 137 байт. Корпус — официальная картинка Forerunner 965 из SDK, ремешок на ней жёлтый. В текущей форме кабинета этого поля нет: там просят обложку 500×500.

Категория — Running, как у поля кругов. В приватность: приложение не собирает и не передаёт персональные данные, замер пишется только в файл тренировки на часах.

## Текст в описание

Lactate Recorder is a touch data field. During a run it keeps blood lactate samples in the workout you are already recording.

Tap the drop to enter a value. Change it by 1 or 0.1 mmol/L and tap OK. Each sample is stored with the time since the timer started and written into the workout file.

The selected sample is shown large in the center. Tap the upper part of the screen for older samples and the lower part for newer ones. Light and dark themes are in the settings.

The field does not start its own activity and does not send data off the watch. Lactate stays in the workout file on the device.

## После публикации

Первая тренировка, записанная уже магазинной сборкой, покажет в файле app id. Ожидаемый — `2b241dea-ad65-4ba7-ad89-aff113dfd2ac`. Его добавляет задача RUN-65 коннектора Runner MCP. Старый id поля кругов оттуда убирать нельзя: прошлые тренировки читаются по нему.

На часах список держит 30 последних замеров, более ранние уже лежат в файле. Повторный OK, пока прошлый замер ещё десять секунд пишется в поток, подменяет это значение в файле; в списке на часах остаются оба.
