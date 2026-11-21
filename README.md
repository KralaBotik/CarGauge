# CarGauge

Нативное приложение SwiftUI для iPhone. Показывает температуру охлаждающей жидкости Hyundai Elantra HD G4FC через OBD-II PID `0105`, обороты `010C` и напряжение. Для подключения к Vgate iCar Pro BLE 4.0 используется CoreBluetooth. До выбора адаптера при запуске открывается симулятор.

На Linux нужен Swift 6.x и Python 3.9+.

```bash
swift test
swift run cargauge-simulator warmup
swift run cargauge-simulator overheat
swift run cargauge-simulator noVoltagePID
swift run cargauge-simulator disconnect
python3 scripts/validate_project.py
```

Для первой поездки включите зажигание, выберите **Приборы → Автомобиль**, затем **Диагностика → Найти Vgate по Bluetooth** и выберите свой адаптер. При следующих запусках CarGauge использует сохранённый адаптер. **Настройки → Автоматически при запуске** также включает ограниченные повторы при обрыве. Кнопка **Остановить измерение** завершает текущий сеанс. В Full можно включить автоматическую Live Activity в **Настройки → Экран блокировки и CarPlay**. [Приборы и оформление](docs/DESIGN.md).

GitHub Actions запускает Swift-тесты на Linux. На macOS он генерирует проект, запускает XCTest на iPhone Simulator и собирает два Release-варианта. После успешных проверок обоих вариантов на `main` или при push в `release/0.3.0-rc` артефакты `CarGauge-full-IPA` и `CarGauge-basic-IPA` содержат неподписанные IPA и файлы SHA-256. Снимки, логи и отчёты `.xcresult` хранятся 14 дней. [GitHub Actions](.github/workflows/ci.yml).

Для первого теста на iPhone с бесплатным Apple ID используйте **CarGauge Basic**. Sideloadly на Windows подпишет его локально. Полный IPA включает WidgetKit и Live Activity. Для проверки общих данных подписывающий инструмент должен выдать приложению и виджету профили с одной App Group и сохранить соответствие bundle ID. Подробности и сценарии первой проверки находятся в [инструкции по установке](docs/SIDELOADLY.md).

Минимальная версия приложения — iOS 18. WidgetKit и Live Activity доступны на iPhone. Их отображение в CarPlay поддерживается с iOS 26. На GitHub runner используется Xcode 26.6, а iOS 27.2 beta и Linux-магнитола входят в приёмку на устройстве. См. [ограничения платформы](docs/PLATFORM.md), [архитектуру](docs/ARCHITECTURE.md), [план приёмки](docs/PLAN.md) и [ревью](docs/REVIEW.md).
