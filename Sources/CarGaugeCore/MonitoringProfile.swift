import Foundation

public struct MonitoringProfile: Identifiable, Sendable {
    public let id: String
    public let version: Int
    public let vehicle: String
    public let rules: [MonitoringRule]

    public static let g4fc = MonitoringProfile(id: "hyundai.elantra-hd.g4fc-mt", version: 1,
                                              vehicle: "Hyundai Elantra HD 2011 · G4FC 1.6 · МКПП",
                                              rules: G4FCMonitoringRules.all)
}

private enum G4FCMonitoringRules {
    private static let annex = "https://saemobilus.sae.org/standards/j1979da_201110-j1979-da-digital-annex-e-e-diagnostic-test-modes"
    private static let elm = "https://www.elmelectronics.com/wp-content/uploads/2016/07/ELM327L_Data_Sheet.pdf"
    private static let epa = "https://www.epa.gov/system/files/documents/2022-09/epa-approved-compiled-sip-california-code-of-regulations-title-13-div-3-chapt-1.pdf"
    private static let coolantPolicy = "https://github.com/KralaBotik/CarGauge/blob/7d6e89c/Sources/CarGaugeCore/Telemetry.swift"
    private static let gsw = "https://gsw.hyundai.com/"
    private static let engineSignals = [sample(.coolant, 5), sample(.rpm, 5), sample(.speed, 6)]
    private static let environment = [sample(.ambient, 75), sample(.intake, 35), sample(.load, 25)]
    private static let mixture = [sample(.shortTrim, 35), sample(.longTrim, 35), sample(.map, 6), sample(.throttle, 35),
                                  sample(.fuelStatus, 8)]

    static var all: [MonitoringRule] {
        [
            temperatureLimit("coolant.critical", title: "Критическая температура ОЖ", limit: .critical, severity: .critical),
            temperatureLimit("coolant.warning", title: "Высокая температура ОЖ", limit: .warning, severity: .warning),
            warmup,
            coolantAfterWarmup(dropping: true),
            coolantAfterWarmup(dropping: false),
            fuelMode,
            trim(idle: true, positive: true), trim(idle: true, positive: false),
            trim(idle: false, positive: true), trim(idle: false, positive: false),
            oxygen(signal: .oxygen1), oxygen(signal: .oxygen2),
            oxygenComparison,
            catalyst,
            idleObservation(warm: false), idleObservation(warm: true),
            idleDeviation,
            voltageObservation(parked: true), voltageObservation(parked: false),
            voltageDeviation,
        ]
    }

    private static func sample(_ signal: DriveSignal, _ age: Double) -> MonitoringMetric {
        .reading(signal, maximumAge: age)
    }

    private static func roll(_ signal: DriveSignal, _ aggregate: MonitoringAggregate, _ duration: Double,
                             count: Int, span: Double, gap: Double, age: Double,
                             closedLoopOnly: Bool = false, scope: MonitoringWindow.Scope = .regime) -> MonitoringMetric {
        .aggregate(.init(signal, aggregate, duration: duration, minimumSamples: count,
                         minimumSpan: span, maximumGap: gap, maximumAge: age, closedLoopOnly: closedLoopOnly, scope: scope))
    }

    private static func temperatureLimit(_ id: String, title: String, limit: MonitoringThermalLimit,
                                         severity: MonitoringSeverity) -> MonitoringRule {
        MonitoringRule(id: id, version: 1, title: title, severity: severity, origin: .userThreshold,
                       sourceURL: coolantPolicy, applicability: "Достоверное значение датчика ОЖ 0105.",
                       rationale: "Порог CarGauge настраивается владельцем. Восстановление ниже порога на 3 °C.",
                       possibleCauses: ["Ограниченная циркуляция или теплоотдача", "Недостаток ОЖ или ошибка измерения"],
                       limitations: "Обращайте внимание на штатные предупреждения и руководство автомобиля. По температуре причина не устанавливается.",
                       correlationKey: "cooling.heat", relevantDTCs: ["P0115", "P0116", "P0128"],
                       applicableWhen: .available(sample(.coolant, 5)),
                       trigger: .compare(sample(.coolant, 5), .atLeast, .thermalLimit(limit, offset: 0)),
                       recovery: .compare(sample(.coolant, 5), .atMost, .thermalLimit(limit, offset: -3)),
                       minimumViolation: severity == .critical ? 0 : 5, minimumRecovery: 15,
                       context: engineSignals + environment)
    }

    private static var warmup: MonitoringRule {
        MonitoringRule(id: "coolant.warmup", version: 1, title: "Долгая работа ниже выбранной температуры",
                       severity: .info, origin: .experimental, sourceURL: gsw,
                       applicability: "Наблюдавшийся холодный запуск и непрерывная сопоставимая телеметрия.",
                       rationale: "900 секунд — исследовательское окно. Оно не описывает исправность термостата.",
                       possibleCauses: ["Низкая наружная температура", "Малая нагрузка или обогрев салона",
                                         "Возможная особенность циркуляции ОЖ"],
                       limitations: "Для позднего подключения и после разрыва расчёт недоступен. Состояние отопителя неизвестно.",
                       correlationKey: "cooling.warmup", relevantDTCs: ["P0128"], enabledByDefault: false,
                       opensIssue: false,
                       applicableWhen: .all([.witnessedColdStart, .available(.witnessedRuntime), .available(sample(.load, 25))]),
                       trigger: .all([.compare(.witnessedRuntime, .atLeast, .constant(900)),
                                      .compare(sample(.coolant, 5), .below, .thermalLimit(.operating, offset: 0))]),
                       recovery: .always(false), minimumViolation: 0, minimumRecovery: 0,
                       context: engineSignals + environment + [.initialCoolant])
    }

    private static func coolantAfterWarmup(dropping: Bool) -> MonitoringRule {
        let maximum = roll(.coolant, .maximum, 120, count: 12, span: 60, gap: 6, age: 5, scope: .continuousRun)
        let change = dropping
            ? MonitoringMetric.difference(maximum, sample(.coolant, 5))
            : roll(.coolant, .spread, 120, count: 12, span: 60, gap: 6, age: 5, scope: .continuousRun)
        return MonitoringRule(id: dropping ? "coolant.drop" : "coolant.variation", version: 1,
                              title: dropping ? "Снижение температуры после прогрева" : "Размах температуры после прогрева",
                              severity: .info, origin: .experimental, sourceURL: gsw,
                              applicability: "Рабочая температура была наблюдаема в текущем сеансе. Скорость и нагрузка доступны.",
                              rationale: "Разность 10/12 °C в 120-секундном окне — критерий наблюдения для проверки на машине.",
                              possibleCauses: ["Изменение нагрузки, скорости или наружной температуры",
                                               "Отопитель салона или работа системы охлаждения"],
                              limitations: "Наблюдение не определяет исправность термостата. Режим отопителя неизвестен.",
                              correlationKey: "cooling.warmup", relevantDTCs: ["P0128"], enabledByDefault: false,
                              opensIssue: false, applicableWhen: .all([.reachedOperating, .available(sample(.speed, 6)),
                                                                       .available(sample(.load, 25))]),
                              trigger: .compare(change, .atLeast, .constant(dropping ? 10 : 12)),
                              recovery: .always(false), minimumViolation: 15, minimumRecovery: 0,
                              context: engineSignals + environment)
    }

    private static var fuelMode: MonitoringRule {
        observation(id: "fuel.mode", title: "Режим топливной системы", origin: .engineering, sourceURL: annex,
                    applicability: "Режим и коррекции по стандартным PID.",
                    rationale: "Код 0103 сохраняет состояние контура. Значения коррекций интерпретируются с учётом контура.",
                    limitations: "Открытый контур при движении не позволяет отличить обогащение от прекращения подачи топлива.",
                    group: "fuel.trim", availability: sample(.fuelStatus, 8),
                    context: engineSignals + mixture + environment)
    }

    private static func trim(idle: Bool, positive: Bool) -> MonitoringRule {
        let median = roll(.shortTrim, .median, 180, count: 4, span: 36, gap: 45, age: 35, closedLoopOnly: true)
        let adjustment = MonitoringMetric.sum(median, sample(.longTrim, 35))
        let id = "fuel.trim.\(idle ? "idle" : "moving").\(positive ? "positive" : "negative")"
        let movement: Set<MonitoringRegime> = idle ? [.warmIdle] : [.moving, .higherLoad]
        return MonitoringRule(id: id, version: 1,
                              title: "Длительная \(positive ? "добавка" : "убавка") топлива · \(idle ? "холостой ход" : "движение")",
                              severity: .info, origin: .experimental, sourceURL: annex,
                              applicability: "Отдельное окно в одном прогретом режиме и замкнутом контуре; согласованные STFT/LTFT, MAP, RPM, нагрузка и дроссель.",
                              rationale: "Сумма медианы STFT и LTFT сравнивается с исследовательским порогом ±20 п.п.",
                              possibleCauses: ["Изменение состава смеси, подачи топлива или измерений воздуха",
                                               "Компенсация условий работы ЭБУ"],
                              limitations: "Коррекции описывают действия контроллера, а не измеренную смесь. Порог не заводской.",
                              correlationKey: "fuel.trim", relevantDTCs: ["P0171", "P0172"], enabledByDefault: false,
                              opensIssue: false, applicableWhen: .all([
                                .regimes(movement), .closedLoop, .available(sample(.map, 6)),
                                .available(sample(.load, 25)), .available(sample(.throttle, 35)),
                                .readingsNear(.shortTrim, .longTrim, maximumSeparation: 25, maximumAge: 35),
                              ]),
                              trigger: .compare(adjustment, positive ? .atLeast : .atMost, .constant(positive ? 20 : -20)),
                              recovery: .always(false), minimumViolation: 45, minimumRecovery: 0,
                              context: engineSignals + mixture + environment)
    }

    private static func oxygen(signal: DriveSignal) -> MonitoringRule {
        let span = roll(signal, .spread, 240, count: 5, span: 100, gap: 85, age: 75, closedLoopOnly: true)
        return MonitoringRule(id: signal == .oxygen1 ? "oxygen.b1s1" : "oxygen.b1s2", version: 1,
                              title: "Малый размах отсчётов · \(signal.title)", severity: .info, origin: .experimental,
                              sourceURL: epa, applicability: "Прогретый двигатель, замкнутый контур и пять раздельных отсчётов.",
                              rationale: "Размах до 0,01 В описывает только записанные точки. Каденция Vgate редкая.",
                              possibleCauses: ["Недостаточно частый опрос или стабильные условия в моменты измерений"],
                              limitations: "Время реакции, реальные переключения и исправность датчика этим способом недоступны.",
                              correlationKey: "exhaust.oxygen", relevantDTCs: ["P0130", "P0133", "P0134", "P0136", "P0140", "P0420"],
                              enabledByDefault: false, opensIssue: false,
                              applicableWhen: .all([.closedLoop, .regimes([.warmIdle, .moving, .higherLoad])]),
                              trigger: .compare(span, .atMost, .constant(0.01)), recovery: .always(false),
                              minimumViolation: 0, minimumRecovery: 0,
                              context: [sample(.oxygen1, 75), sample(.oxygen2, 75)] + mixture + engineSignals)
    }

    private static var oxygenComparison: MonitoringRule {
        let paired = MonitoringCondition.readingsNear(.oxygen1, .oxygen2, maximumSeparation: 35, maximumAge: 75)
        let found = MonitoringMetric.difference(sample(.oxygen1, 75), sample(.oxygen2, 75))
        return observation(id: "oxygen.readings", title: "Сопоставление кислородных датчиков", origin: .engineering,
                           sourceURL: annex, applicability: "Близкие по времени отсчёты B1S1 и B1S2 при замкнутом контуре.",
                           rationale: "Показывает два напряжения и сопутствующие коррекции. При включении анализа виден размах отдельных выборок.",
                           limitations: "Это узкополосные напряжения. Сравнение не определяет состав смеси или эффективность катализатора.",
                           group: "exhaust.oxygen", availability: found, condition: .all([.closedLoop, paired]),
                           context: [sample(.oxygen1, 75), sample(.oxygen2, 75)] + mixture,
                           relatedDTCs: ["P0133", "P0420"])
    }

    private static var catalyst: MonitoringRule {
        observation(id: "catalyst.temperature", title: "Температура катализатора", origin: .engineering,
                    sourceURL: annex, applicability: "Достоверное значение PID 013C.",
                    rationale: "Ряд 013C используется как контекст диагностики выбросов.",
                    limitations: "Температура может быть оценкой ЭБУ; пороги данной калибровки и КПД катализатора не подтверждены.",
                    group: "exhaust.oxygen", availability: sample(.catalyst, 75),
                    context: [sample(.oxygen1, 75), sample(.oxygen2, 75)] + engineSignals, relatedDTCs: ["P0420"])
    }

    private static func idleObservation(warm: Bool) -> MonitoringRule {
        observation(id: warm ? "idle.warm" : "idle.warming", title: warm ? "Прогретый холостой ход" : "Обороты на прогреве",
                    origin: .engineering, sourceURL: annex,
                    applicability: "Свежие RPM, нулевая скорость и отдельное окно выбранного режима.",
                    rationale: "Среднее, минимум, максимум и размах по непрерывному окну. Температура и нагрузка видны как условия.",
                    limitations: "Команды ЭБУ, режим кондиционера и нагрузки потребителей могут изменять RPM.",
                    group: "idle", availability: idleMetric(.average),
                    condition: .all([.regimes(warm ? [.warmIdle] : [.coldStart, .warmingUp]),
                                     .compare(sample(.speed, 6), .equal, .constant(0))]),
                    context: [idleMetric(.minimum), idleMetric(.maximum), idleMetric(.spread)] + engineSignals + environment)
    }

    private static func idleMetric(_ aggregate: MonitoringAggregate) -> MonitoringMetric {
        roll(.rpm, aggregate, 75, count: 8, span: 24, gap: 6, age: 5)
    }

    private static var idleDeviation: MonitoringRule {
        MonitoringRule(id: "idle.relative", version: 1, title: "Отклонение от истории прогретого холостого хода",
                       severity: .info, origin: .individual, sourceURL: annex,
                       applicability: "Прогретый двигатель и достаточная статистика того же режима, нагрузки и температуры воздуха.",
                       rationale: "Отклонение от медианы больше 4 MAD и 100 об/мин в течение 30 секунд.",
                       possibleCauses: ["Смена нагрузки на двигатель или контекста измерения", "Нестабильное регулирование оборотов"],
                       limitations: "Индивидуальная история может содержать отклонения. Заводской норматив RPM здесь не применяется.",
                       correlationKey: "idle", enabledByDefault: false, opensIssue: false,
                       applicableWhen: .regimes([.warmIdle]),
                       trigger: relative(.rpm, absoluteFloor: 100, age: 5),
                       recovery: .always(false), minimumViolation: 30, minimumRecovery: 0,
                       context: [idleMetric(.average), idleMetric(.spread)] + engineSignals + environment)
    }

    private static func voltageObservation(parked: Bool) -> MonitoringRule {
        let voltage = sample(.adapterVoltage, 8)
        let running: Set<MonitoringRegime> = [.coldStart, .warmingUp, .warmIdle, .moving, .higherLoad, .decelerationCandidate]
        return observation(id: parked ? "voltage.ignition" : "voltage.running",
                           title: parked ? "Питание при включённом зажигании" : "Питание при работающем двигателе",
                           origin: .engineering, sourceURL: elm, applicability: "Свежее ATRV, отдельно по работе двигателя.",
                           rationale: "Хранится напряжение на входе адаптера; пользовательская поправка отображается отдельным показанием.",
                           limitations: "Падение напряжения до адаптера, температура и фактическая электрическая нагрузка неизвестны.",
                           group: "voltage", availability: voltage, condition: .regimes(parked ? [.ignitionOn] : running),
                           context: [.adapterVoltageReference(maximumAge: 8),
                                     roll(.adapterVoltage, .median, 90, count: 6, span: 20, gap: 12, age: 8)] + engineSignals + environment)
    }

    private static var voltageDeviation: MonitoringRule {
        MonitoringRule(id: "voltage.relative", version: 1, title: "Изменение напряжения адаптера на холостом ходу",
                       severity: .info, origin: .individual, sourceURL: elm,
                       applicability: "Тёплый холостой ход и достаточно сопоставимых прошлых измерений ATRV.",
                       rationale: "Отклонение от медианы больше 4 MAD и 0,6 В в течение 30 секунд.",
                       possibleCauses: ["Изменение внешних нагрузок, температуры или напряжения сети"],
                       limitations: "Сравнение не заменяет измерение на клеммах и не определяет источник отклонения.",
                       correlationKey: "voltage", relevantDTCs: ["P0560", "P0562", "P0563"],
                       enabledByDefault: false, opensIssue: false, applicableWhen: .regimes([.warmIdle]),
                       trigger: relative(.adapterVoltage, absoluteFloor: 0.6, age: 8),
                       recovery: .always(false), minimumViolation: 30, minimumRecovery: 0,
                       context: [sample(.adapterVoltage, 8), .adapterVoltageReference(maximumAge: 8)] + engineSignals)
    }

    private static func relative(_ signal: DriveSignal, absoluteFloor: Double, age: Double) -> MonitoringCondition {
        let delta = MonitoringMetric.baselineDifference(signal, maximumAge: age)
        let mad = MonitoringMetric.baselineMAD(signal)
        let twice = MonitoringMetric.sum(mad, mad)
        let band = MonitoringMetric.sum(twice, twice)
        let negative = MonitoringMetric.difference(.constant(0), band)
        return .any([.all([.compare(delta, .above, band), .compare(delta, .above, .constant(absoluteFloor))]),
                     .all([.compare(delta, .below, negative), .compare(delta, .below, .constant(-absoluteFloor))])])
    }

    private static func observation(id: String, title: String, origin: MonitoringOrigin, sourceURL: String,
                                    applicability: String, rationale: String, limitations: String, group: String,
                                    availability: MonitoringMetric, condition: MonitoringCondition = .always(true),
                                    context: [MonitoringMetric], relatedDTCs: Set<String> = []) -> MonitoringRule {
        MonitoringRule(id: id, version: 1, title: title, severity: .info, origin: origin, sourceURL: sourceURL,
                       applicability: applicability, rationale: rationale, possibleCauses: [], limitations: limitations,
                       correlationKey: group, relevantDTCs: relatedDTCs, opensIssue: false,
                       applicableWhen: .all([condition, .available(availability)]), trigger: .always(false),
                       recovery: .always(false), minimumViolation: 0, minimumRecovery: 0, context: context)
    }
}
