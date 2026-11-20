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

На экране iPhone выберите **Симулятор** и запустите нужный сценарий. Для автомобиля включите зажигание, откройте **Автомобиль → Найти Vgate по Bluetooth** и выберите свой адаптер. Переключатель **Автоподключение** сохраняет выбор для следующего запуска и включает повторные попытки в текущем сеансе. Кнопка **Остановить измерение** завершает текущий сеанс. Для запуска Live Activity дождитесь свежей температуры и нажмите **Начать Live Activity** в CarGauge.

[GitHub Actions](.github/workflows/ci.yml) запускает Swift-тесты на Linux, а на macOS генерирует проект из [project.yml](project.yml), запускает XCTest на iPhone Simulator и собирает Release для iPhone. Логи и отчёты `.xcresult` доступны в артефактах диагностики 14 дней, в том числе при сбое тестов. После успешного задания iOS для `main` артефакт `CarGauge-iPhone-unsigned` содержит неподписанный `.app` с расширением WidgetKit.

Для установки на физический iPhone понадобятся подпись и профили для приложения и виджета с общей App Group. При подписи задайте свой `CARGAUGE_BUNDLE_ID`, зарегистрируйте идентификаторы `<id>` и `<id>.widgets`, а также группу `group.<id>`. Для установки через профиль разработки или Ad Hoc нужен зарегистрированный iPhone. В CI сертификаты не требуются.

Минимальная версия приложения — iOS 18. WidgetKit и Live Activity доступны на iPhone. Их отображение в CarPlay поддерживается с iOS 26. На GitHub runner используется Xcode 26.6, а iOS 27.2 beta и Linux-магнитола входят в приёмку на устройстве. См. [ограничения платформы](docs/PLATFORM.md), [архитектуру](docs/ARCHITECTURE.md), [план приёмки](docs/PLAN.md) и [ревью](docs/REVIEW.md).
