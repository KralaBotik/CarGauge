import Foundation

public enum DTCUrgency: String, Codable, Sendable {
    case promptInspection
    case contextDependent

    public var title: String {
        switch self {
        case .promptInspection: "Приоритетная проверка"
        case .contextDependent: "Срочность зависит от симптомов"
        }
    }
}

public struct DTCDescription: Codable, Equatable, Sendable {
    public let code: String
    public let title: String
    public let causes: [String]
    public let recommendation: String
    public let urgency: DTCUrgency
    public let limits: String
    public let source: String
}

/// Original Russian descriptions of selected generic powertrain codes.
/// See DIAGNOSTIC_SOURCES.md for provenance and applicability of each source.
public enum DTCCatalog {
    private static let vwPassat = "https://static.nhtsa.gov/odi/tsbs/2014/MC-10241740-9999.pdf"
    private static let audiA8 = "https://static.nhtsa.gov/odi/tsbs/2013/MC-10243913-9999.pdf"
    private static let hyundaiP0128 = "https://static.nhtsa.gov/odi/tsbs/2020/MC-10178170-0001.pdf#page=1"

    public static func lookup(_ code: String) -> DTCDescription? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch normalized {
        case "P0117", "P0118":
            let signal = normalized == "P0117" ? "Низкий" : "Высокий"
            return DTCDescription(
                code: normalized,
                title: "\(signal) сигнал в цепи датчика температуры ОЖ",
                causes: ["Датчик температуры охлаждающей жидкости", "Разъём или проводка датчика"],
                recommendation: "Сохраните стоп-кадр. Проверьте цепь датчика и сопоставьте показание ЭБУ с независимым измерением температуры.",
                urgency: .promptInspection,
                limits: "Код относится к электрическому сигналу. Он не определяет фактическую температуру охлаждающей жидкости.",
                source: vwPassat + "#page=5"
            )
        case "P0128":
            return DTCDescription(
                code: normalized,
                title: "Охлаждающая жидкость не достигла ожидаемой температуры",
                causes: ["Слишком раннее открытие термостата", "Некорректное показание датчика температуры"],
                recommendation: "Сохраните стоп-кадр. Оцените прогрев с начала холодного пуска при известных условиях и проверьте показания датчика.",
                urgency: .contextDependent,
                limits: "Код отражает условие, заданное в ЭБУ. Он не подтверждает неисправность термостата. Заводской порог для этого G4FC не установлен по приведённому источнику.",
                source: hyundaiP0128
            )
        case "P0133":
            return DTCDescription(
                code: normalized,
                title: "Медленный отклик переднего кислородного датчика (банк 1)",
                causes: ["Датчик или его проводка", "Негерметичность выпуска перед датчиком"],
                recommendation: "Сопоставьте стоп-кадр с топливными коррекциями. Проверьте проводку и герметичность выпуска перед диагностикой датчика.",
                urgency: .contextDependent,
                limits: "Код отражает вывод ЭБУ. По редким опросам CarGauge нельзя измерить скорость отклика датчика.",
                source: vwPassat + "#page=6"
            )
        case "P0171", "P0172":
            let isLean = normalized == "P0171"
            return DTCDescription(
                code: normalized,
                title: isLean ? "Слишком бедная смесь (банк 1)" : "Слишком богатая смесь (банк 1)",
                causes: isLean
                    ? ["Подсос воздуха во впуске", "Недостаточная подача топлива", "Ошибочное показание датчика"]
                    : ["Избыточная подача топлива", "Негерметичная форсунка", "Ошибочное показание датчика"],
                recommendation: "Сопоставьте сохранённые условия, коррекции смеси и показания датчиков на прогретом двигателе. Оценивайте холостой ход и движение отдельно.",
                urgency: .contextDependent,
                limits: "Код указывает на вывод ЭБУ о смеси и не определяет неисправный компонент. Пределы коррекций зависят от калибровки ЭБУ.",
                source: audiA8 + "#page=220"
            )
        case "P0300": return misfire(normalized, cylinder: nil)
        case "P0301": return misfire(normalized, cylinder: 1)
        case "P0302": return misfire(normalized, cylinder: 2)
        case "P0303": return misfire(normalized, cylinder: 3)
        case "P0304": return misfire(normalized, cylinder: 4)
        case "P0420":
            return DTCDescription(
                code: normalized,
                title: "Эффективность катализатора ниже порога ЭБУ (банк 1)",
                causes: ["Снижение эффективности катализатора", "Негерметичность выпуска", "Сопутствующие отклонения смеси или сигнала кислородного датчика"],
                recommendation: "Оцените сопутствующие коды, стоп-кадр и герметичность выпуска перед выводом о состоянии катализатора.",
                urgency: .contextDependent,
                limits: "Связь кода с состоянием конкретной детали требует проверки. По частоте опроса CarGauge нельзя независимо подтвердить эффективность катализатора.",
                source: vwPassat + "#page=83"
            )
        default:
            return nil
        }
    }

    private static func misfire(_ code: String, cylinder: Int?) -> DTCDescription {
        DTCDescription(
            code: code,
            title: cylinder.map { "Пропуски воспламенения в цилиндре \($0)" } ?? "Случайные или множественные пропуски воспламенения",
            causes: ["Нарушение зажигания", "Нарушение подачи топлива", "Недостаточная компрессия"],
            recommendation: "Сохраните стоп-кадр и уточните, повторяются ли пропуски. При мигающей лампе неисправности или выраженной неровной работе двигателя нужна срочная очная диагностика.",
            urgency: .promptInspection,
            limits: "Даже код конкретного цилиндра не определяет неисправную деталь. Сохранённый код может относиться к прошлому эпизоду.",
            source: vwPassat + "#page=10"
        )
    }
}
