# Установка и обновление CarGauge 0.6.0 с Windows

**Рекомендуемый вариант — Full.** Live Activity и расширение WidgetKit подтверждены пользователем на физическом iPhone для Full 0.3.0. У той подписи Sideloadly обмен с виджетом через App Groups не работает. Основные приборы и Live Activity не зависят от доступа к группе.

| Артефакт CI | Файл | Идентификаторы до подписи |
| --- | --- | --- |
| CarGauge-full-IPA | `CarGauge-Full-unsigned.ipa` | `com.cargauge.prototype`, `com.cargauge.prototype.widgets` |
| CarGauge-basic-IPA | `CarGauge-Basic-unsigned.ipa` | `com.cargauge.prototype.basic` |

Оба файла — неподписанные Release для arm64 и iOS 18.0 или новее. Basic оставлен для случая, когда Sideloadly не устанавливает Full с расширением. У Basic отдельный контейнер настроек.

## Обновление уже установленного Full

1. Откройте успешный [выпускной CI ветки 0.6.0](https://github.com/KralaBotik/CarGauge/actions/workflows/ci.yml?query=branch%3Arelease%2F0.6.0+is%3Asuccess) и скачайте `CarGauge-full-IPA`. Распакуйте ZIP. Запустите `Get-FileHash .\CarGauge-Full-unsigned.ipa -Algorithm SHA256` в PowerShell и сверьте результат с `.ipa.sha256`.
2. Для обновления используйте ту же установку Sideloadly, Apple ID, итоговый bundle ID и параметры подписи, что были у вашего установленного Full. Оставьте установленный Full на iPhone до обновления. Если Sideloadly создаёт вторую запись приложения, проверьте совпадение итогового bundle ID.
3. Подключите разблокированный iPhone кабелем, подтвердите доверие компьютеру и выберите его в Sideloadly. Откройте IPA, выберите **Apple ID Sideload**, сохраните расширение и нажмите **Start**. Вводите Apple ID, пароль и 2FA только локально. Для первой установки используйте инструкции Sideloadly по драйверам и локальной Anisette. [Sideloadly](https://sideloadly.io/), [FAQ](https://sideloadly.io/faq).
4. Если требуется, включите **Настройки → Конфиденциальность и безопасность → Режим разработчика**, перезагрузите iPhone и подтвердите включение. При запросе iOS подтвердите доверие профилю в **Основные → VPN и управление устройством**. [Developer Mode у Apple](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).
5. Откройте 0.6.0. Тема, пороги, разрешение на автоматическую Live Activity и настройка автоподключения должны сохраниться. Проверенный UUID из 0.5.0 сохраняется. При обновлении со старой версии без проверенного UUID первый валидный замер подтверждает выбор. При отсутствии UUID откроется экран подключения.
6. Для бесплатного Personal Team проверяйте срок подписи и обновляйте приложение с тем же аккаунтом и идентификатором. Профили Personal Team обычно действуют 7 дней. [Ограничения Apple](https://developer.apple.com/help/account/basics/about-your-developer-account/), [FAQ Sideloadly](https://sideloadly.io/faq).

## Виджет и подписанные App Groups

В Full приложению и `CarGaugeWidgets.appex` нужна одна группа в обоих Info.plist, подписях и provisioning profiles. Шаблон CarGauge использует `group.com.cargauge.prototype`. В диагностике CarGauge проверяет доступ приложения к контейнеру. Показ свежих данных в виджете отдельно подтверждает доступ расширения. [Настройка групп у Apple](https://developer.apple.com/documentation/xcode/configuring-app-groups).

Сбой обмена в переподписанном Full 0.3.0 подтверждён пользователем по поведению на iPhone. Подписанный экземпляр для проверки entitlements пока недоступен. Если используемая версия инструмента позволяет сохранить **переподписанный** Full IPA, проверьте его локально на Windows или Linux с Python 3.9+ и OpenSSL в PATH. Скрипт выводит совпадения App Group для обоих бинарников и профилей. Исходный неподписанный IPA закономерно имеет статус UNVERIFIED.

```powershell
python scripts/inspect_app_groups.py .\CarGauge-Full-signed.ipa
```

На macOS значения можно сверить через `codesign --display --entitlements :-` для `.app` и `.appex` и через `security cms -D -i` для их `embedded.mobileprovision`. Оставляйте профили и подписанные IPA локально. [Apple Entitlements Troubleshooting](https://developer.apple.com/library/archive/technotes/tn2415/).

Для поддерживаемого использования виджета зарегистрируйте оба App ID и одну группу, назначьте её обеим целям, подпишите Full профилями для iPhone и сохраните значение группы в Info.plist. Для сборки можно использовать Xcode с соответствующей командой подписи. Sideloadly указывает Apple Developer Program и Patreon как требования ручной настройки entitlements. Для обычной установки пока используйте Full c Live Activity либо Basic, если расширение блокирует установку. [Матрица Apple](https://developer.apple.com/help/account/reference/supported-capabilities-ios/), [журнал Sideloadly](https://sideloadly.io/changelog.html).

## Приёмка 26 ноября

| Условия | Проверка |
| --- | --- |
| Первое подключение Vgate | Разрешение Bluetooth, вероятные устройства и расширенный поиск. Убедиться, что после неудачного ELM-сеанса адаптер не сохраняется. Записать GATT UUID и свойства характеристик. |
| Холодный запуск и обновление | Открытие 0.6.0 поверх 0.5.0 на iPhone с тем же Sideloadly ID. Проверить настройки, автоматическое подключение, отмену или замену адаптера и сброс. |
| Прогрев Hyundai G4FC | Сверить температуру, RPM и источник напряжения `0142` или `ATRV` с доступным эталоном. Прогнать предупреждения в Debug отдельно. |
| Обрыв и сон | Отключить и вернуть питание Vgate, проверить скрытие старых значений, ограниченные повторы, возврат приложения и подключение после нового зажигания. Отличить потерю связи от нулевых оборотов. |
| iPhone 11 | Проверить блокировку, устаревание и завершение Live Activity, отсутствие дубликатов, VoiceOver, крупный текст и safe area. |
| Linux-магнитола | Проверить Live Activity рядом с картой, виджет с корректной подписью, отображение давности и метку устаревания. Записать поведение с блокировкой и персональной автоматизацией **Команды → CarPlay**. |

Физический Vgate, экран магнитолы и установка 0.6.0 остаются **UNVERIFIED** до фактической проверки.

[Матрица CarPlay и сценарии блокировки](CARPLAY.md) описывают отдельно проверку Live Activity, виджета и действия «Открыть приборы».
