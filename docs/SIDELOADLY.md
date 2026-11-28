# Установка и обновление CarGauge 0.8.0 с Windows

Выпускается один неподписанный `CarGauge.ipa` с WidgetKit и Live Activity. Нужен iPhone arm64 с iOS 18.0 или новее. Bundle ID до подписи приложения `com.cargauge.prototype`, расширения `com.cargauge.prototype.widgets`. Владелец подтвердил показ Live Activity на физическом iPhone для предыдущей версии. Обмен с виджетом зависит от подписи App Groups.

## Обновление установленного CarGauge

1. Откройте [успешный CI ветки 0.8](https://github.com/KralaBotik/CarGauge/actions/workflows/ci.yml?query=branch%3Afeature%2Ftelemetry-0.8.0+is%3Asuccess), скачайте `CarGauge-IPA` и распакуйте ZIP. Сверьте контрольную сумму командой `Get-FileHash .\CarGauge.ipa -Algorithm SHA256` в PowerShell.
2. Используйте прежний Apple ID, итоговый bundle ID и прежние параметры подписи Sideloadly. У старой Basic был отдельный ID и контейнер.
3. Подключите разблокированный iPhone кабелем, подтвердите доверие компьютеру. Откройте `CarGauge.ipa` в Sideloadly, выберите **Apple ID Sideload**, сохраните расширение и запустите установку. Учётные данные вводите только в Sideloadly.
4. При первом запуске включите Developer Mode и доверьте профилю разработчика, если iOS это запрашивает. После обновления проверьте сохранённый адаптер, тему, пороги и Live Activity.
5. Выполните [процедуру замера топлива](FUEL_CHECK.md).

## Виджет и подписанные App Groups

В Full приложению и `CarGaugeWidgets.appex` нужна одна группа в обоих Info.plist, подписях и provisioning profiles. Шаблон CarGauge использует `group.com.cargauge.prototype`. В диагностике CarGauge проверяет доступ приложения к контейнеру. Показ свежих данных в виджете отдельно подтверждает доступ расширения. [Настройка групп у Apple](https://developer.apple.com/documentation/xcode/configuring-app-groups).

Сбой обмена в переподписанном Full 0.3.0 подтверждён пользователем по поведению на iPhone. Подписанный экземпляр для проверки entitlements пока недоступен. Если используемая версия инструмента позволяет сохранить **переподписанный** Full IPA, проверьте его локально на Windows или Linux с Python 3.9+ и OpenSSL в PATH. Скрипт выводит совпадения App Group для обоих бинарников и профилей. Исходный неподписанный IPA закономерно имеет статус UNVERIFIED.

```powershell
python scripts/inspect_app_groups.py .\CarGauge-Full-signed.ipa
```

На macOS значения можно сверить через `codesign --display --entitlements :-` для `.app` и `.appex` и через `security cms -D -i` для их `embedded.mobileprovision`. Оставляйте профили и подписанные IPA локально. [Apple Entitlements Troubleshooting](https://developer.apple.com/library/archive/technotes/tn2415/).

Для поддерживаемого использования виджета зарегистрируйте оба App ID и одну группу, назначьте её обеим целям, подпишите Full профилями для iPhone и сохраните значение группы в Info.plist. Для сборки можно использовать Xcode с соответствующей командой подписи. Sideloadly указывает Apple Developer Program и Patreon как требования ручной настройки entitlements. Настройки виджета показывают доступ к группе. Приборы и Live Activity используют собственные данные приложения. [Матрица Apple](https://developer.apple.com/help/account/reference/supported-capabilities-ios/), [журнал Sideloadly](https://sideloadly.io/changelog.html).

## Приёмка на автомобиле

| Условия | Проверка |
| --- | --- |
| Первое подключение Vgate | Разрешение Bluetooth, вероятные устройства и расширенный поиск. Убедиться, что после неудачного ELM-сеанса адаптер не сохраняется. Записать GATT UUID и свойства характеристик. |
| Холодный запуск и обновление | Открытие 0.8.0 поверх 0.7.0 на iPhone с тем же Sideloadly ID. Проверить настройки, автоматическое подключение, отмену или замену адаптера и сброс. |
| Прогрев Hyundai G4FC | Сверить температуру, RPM и источник напряжения `0142` или `ATRV` с доступным эталоном. Прогнать предупреждения в Debug отдельно. |
| Обрыв и сон | Отключить и вернуть питание Vgate, проверить скрытие старых значений, ограниченные повторы, возврат приложения и подключение после нового зажигания. Отличить потерю связи от нулевых оборотов. |
| iPhone 11 | Проверить блокировку, устаревание и завершение Live Activity, отсутствие дубликатов, VoiceOver, крупный текст и safe area. |
| Linux-магнитола | Проверить Live Activity рядом с картой, виджет с корректной подписью, отображение давности и метку устаревания. Записать поведение с блокировкой и персональной автоматизацией **Команды → CarPlay**. |

Физический Vgate, экран магнитолы и установка 0.8.0 остаются **UNVERIFIED** до фактической проверки.

[Матрица CarPlay и сценарии блокировки](CARPLAY.md) описывают отдельно проверку Live Activity, виджета и действия «Открыть приборы».
