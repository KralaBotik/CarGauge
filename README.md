# CarGauge

Нативное приложение SwiftUI для iPhone. Показывает температуру охлаждающей жидкости Hyundai Elantra HD G4FC через OBD-II PID `0105`, обороты `010C` и напряжение. Для подключения к Vgate iCar Pro BLE 4.0 используется CoreBluetooth. Начальный режим — симулятор.

На Linux нужен Swift 6.x и Python 3.9+.

```bash
swift test
swift run cargauge-simulator warmup
swift run cargauge-simulator overheat
swift run cargauge-simulator noVoltagePID
swift run cargauge-simulator disconnect
python3 scripts/validate_project.py
```

На вкладке **Приборы** выберите **Симулятор**, а в **Настройках** выберите сценарий. Для автомобиля включите зажигание, выберите **Автомобиль** на **Приборах**, затем в **Диагностике** нажмите **Найти Vgate по Bluetooth** и выберите адаптер. Переключатель **Автоподключение** в **Настройках** включает повторные попытки в текущем сеансе и подключение при следующем запуске. Кнопка **Остановить измерение** завершает текущий сеанс. В Full дождитесь свежей температуры и нажмите **Настройки → Начать Live Activity**. [Приборы и оформление](docs/DESIGN.md).

[GitHub Actions](.github/workflows/ci.yml) запускает Swift-тесты на Linux. На macOS он генерирует проект из [project.yml](project.yml), запускает XCTest на iPhone Simulator и собирает два Release-варианта. После прохождения тестов и сборок обоих вариантов на `main` артефакты `CarGauge-full-IPA` и `CarGauge-basic-IPA` содержат неподписанные IPA и файлы SHA-256. Снимки экранов, логи и отчёты `.xcresult` хранятся 14 дней.

Для первого теста на iPhone с бесплатным Apple ID используйте **CarGauge Basic**. Sideloadly на Windows подпишет его локально. Полный IPA включает WidgetKit и Live Activity. Для проверки общих данных подписывающий инструмент должен выдать приложению и виджету профили с одной App Group и сохранить соответствие bundle ID. Подробности и сценарии первой проверки находятся в [инструкции по установке](docs/SIDELOADLY.md).

Минимальная версия приложения — iOS 18. WidgetKit и Live Activity доступны на iPhone. Их отображение в CarPlay поддерживается с iOS 26. На GitHub runner используется Xcode 26.6, а iOS 27.2 beta и Linux-магнитола входят в приёмку на устройстве. См. [ограничения платформы](docs/PLATFORM.md), [архитектуру](docs/ARCHITECTURE.md), [план приёмки](docs/PLAN.md) и [ревью](docs/REVIEW.md).
