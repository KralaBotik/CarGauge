import CarGaugeCore
import SwiftUI
import UniformTypeIdentifiers

struct GaugeDiagnosticSurveyView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.gaugePalette) private var palette
    @State private var confirmSurvey = false
    @State private var includeRaw = false
    @State private var exporting = false
    @State private var export = SurveyExport.json
    @State private var document: SurveyDocument?
    @State private var exportError: String?

    var body: some View {
        GaugeSection(title: "Обследование автомобиля", headerID: "survey-section") {
            Text("Остановите автомобиль и включите зажигание. Опрос запускается вручную при подключении и работает, пока приложение открыто.")
                .font(.subheadline)
                .foregroundStyle(palette.muted)
            if model.surveyIsRunning {
                Button("Остановить обследование", action: model.cancelDiagnosticSurvey)
                    .buttonStyle(GaugeActionStyle())
                    .accessibilityIdentifier("survey-stop")
            } else {
                Button("Начать обследование") { confirmSurvey = true }
                    .buttonStyle(GaugeActionStyle())
                    .disabled(!model.canSurvey)
                    .accessibilityIdentifier("survey-start")
                if !model.canSurvey {
                    Text("Для обследования дождитесь показаний автомобиля.")
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                }
            }
            if let diagnosticStorageMessage = model.diagnosticStorageMessage {
                Text(diagnosticStorageMessage).font(.footnote)
            }
            if let report = model.diagnosticReport {
                reportContents(report)
            }
            if let exportError { Text(exportError).font(.footnote) }
        }
        .confirmationDialog("Автомобиль стоит?", isPresented: $confirmSurvey, titleVisibility: .visible) {
            Button("Начать чтение", action: model.startDiagnosticSurvey)
                .accessibilityIdentifier("survey-confirm")
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("CarGauge прочитает только стандартные параметры и сведения об ошибках.")
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: export.contentType,
                      defaultFilename: "CarGauge-\(export.suffix)") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
    }

    @ViewBuilder private func reportContents(_ report: DiagnosticReport) -> some View {
        GaugeRule()
        Text(reportTitle(report))
            .font(.headline)
            .accessibilityIdentifier("survey-state")
        if report.source != "vehicle" {
            Text("Тестовый отчёт").font(.footnote).accessibilityIdentifier("survey-test-source")
        }
        Text(report.startedAt.formatted(date: .abbreviated, time: .standard))
            .font(.footnote)
            .foregroundStyle(palette.muted)
        if let interruption = report.interruption { Text(interruption).font(.subheadline) }
        if let adapter = report.adapterName { row("Адаптер обследования", adapter) }
        if let identification = report.adapterIdentification { row("Ответ адаптера при инициализации", identification) }
        row("Протокол ELM", report.transportProtocol?.rawValue ?? "не подтверждён")
        row("Выполнено запросов", String(report.exchanges.count))
        Text("Ответы относятся к стандартному OBD. По ним нельзя судить о состоянии всех блоков.")
            .font(.footnote)
            .foregroundStyle(palette.muted)

        if report.state != .running {
            DisclosureGroup("Коды двигателя") {
                ForEach(DiagnosticCodeStatus.allCases, id: \.rawValue) { status in
                    row(status.title, codeSummary(status, in: report))
                }
            }
            DisclosureGroup("Freeze Frame и Readiness") {
                freezeAndReadiness(report)
            }
            DisclosureGroup("Блоки и поддержка PID") {
                ForEach(report.modules) { module in
                    row(module.name, moduleStatus(module.status))
                }
                let supported = Set(report.pages.filter { $0.mode == 1 }.flatMap(\.advertisedPIDs)).sorted()
                row("Объявленные PID", supported.isEmpty ? "маски недоступны" : supported.joined(separator: " "))
                Text("Перечень собран из анонимных ответов. Поддержка по маске и получение конкретного значения проверяются отдельно.")
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                ForEach(Array(report.measurements.enumerated()), id: \.offset) { _, sample in
                    if sample.freezeFrame == nil { measurement(sample) }
                }
            }
            DisclosureGroup("Журнал запросов") {
                ForEach(Array(report.exchanges.enumerated()), id: \.offset) { _, request in
                    row(request.command, "\(request.outcome.title) · \(request.elapsedMilliseconds) мс")
                    if let detail = request.detail { Text(detail).font(.caption) }
                }
            }
            GaugeRule()
            Toggle("Включить исходные ответы в JSON", isOn: $includeRaw)
                .tint(palette.operating)
                .accessibilityIdentifier("survey-include-raw")
            Menu {
                Button("Отчёт JSON") { makeExport(.json, report: report) }
                    .accessibilityIdentifier("survey-json")
                Button("Измерения CSV") { makeExport(.csv, report: report) }
                    .accessibilityIdentifier("survey-csv")
                Button("Текстовая сводка") { makeExport(.summary, report: report) }
                    .accessibilityIdentifier("survey-summary")
            } label: {
                Label("Экспорт обследования", systemImage: "square.and.arrow.up")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("survey-export")
        }
    }

    @ViewBuilder private func freezeAndReadiness(_ report: DiagnosticReport) -> some View {
        if report.freezeCauses.isEmpty {
            row("Срабатывание Freeze Frame", "нет достоверного ответа")
        } else {
            ForEach(Array(report.freezeCauses.enumerated()), id: \.offset) { _, code in
                row("Freeze Frame · кадр 00", code == "0000" ? "кадр не сообщён в ответе" : code)
            }
        }
        ForEach(Array(report.measurements.enumerated()), id: \.offset) { _, sample in
            if sample.freezeFrame != nil { measurement(sample) }
        }
        if report.readiness.isEmpty { row("Readiness", "нет достоверного ответа") }
        ForEach(Array(report.readiness.enumerated()), id: \.offset) { index, result in
            row("Ответ Readiness \(index + 1)", result.milOn ? "ЭБУ сообщает MIL" : "ЭБУ не сообщает MIL")
            row("Подтверждённые коды по PID 01", String(result.confirmedCodeCount))
            ForEach(result.monitors) { monitor in
                row(monitor.name, monitor.complete.map { $0 ? "готов" : "не готов" } ?? "не поддерживается")
            }
        }
    }

    private func measurement(_ sample: DiagnosticMeasurement) -> some View {
        let value = sample.value
            .map { "\($0.formatted(.number.precision(.fractionLength(0...3)))) \(sample.sensor.unit)" }
            ?? "Байты сохранены. Масштаб не подтверждён"
        return row("\(sample.sensor.name) · \(sample.sensor.pid)", value)
    }

    private func row(_ label: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(palette.muted)
            Text(content).font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }

    private func reportTitle(_ report: DiagnosticReport) -> String {
        switch report.state {
        case .running: "Чтение данных…"
        case .interrupted: "Обследование прервано"
        case .completed: "Обследование завершено"
        }
    }

    private func moduleStatus(_ status: DiagnosticReport.Module.Status) -> String {
        switch status {
        case .answeredGenericOBD: "Есть ответ стандартного OBD"
        case .notChecked: "Достоверного ответа нет"
        case .profileUnverified: "Не проверялся · профиль не подтверждён"
        }
    }

    private func codeSummary(_ status: DiagnosticCodeStatus, in report: DiagnosticReport) -> String {
        guard let group = report.codes.first(where: { $0.status == status }) else {
            return "Нет достоверного результата"
        }
        let codes = Array(Set(group.replyGroups.flatMap { $0 })).sorted()
        if codes.isEmpty { return "В полученных ответах коды не сообщены" }
        return codes.map { code in
            code == "P0133" ? "P0133 · медленный отклик цепи датчика кислорода, банк 1, датчик 1" : code
        }.joined(separator: "\n")
    }

    private func makeExport(_ kind: SurveyExport, report: DiagnosticReport) {
        do {
            let data: Data
            switch kind {
            case .json: data = try report.json(includeRaw: includeRaw)
            case .csv: data = Data(report.csv().utf8)
            case .summary: data = Data(report.summary().utf8)
            }
            document = SurveyDocument(bytes: data)
            export = kind
            exportError = nil
            exporting = true
        } catch {
            exportError = "Не удалось подготовить экспорт: \(error.localizedDescription)"
        }
    }
}

private enum SurveyExport {
    case json, csv, summary

    var contentType: UTType {
        switch self {
        case .json: .json
        case .csv: .commaSeparatedText
        case .summary: .utf8PlainText
        }
    }

    var suffix: String {
        switch self {
        case .json: "diagnostics"
        case .csv: "measurements"
        case .summary: "summary"
        }
    }
}

private struct SurveyDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json, .commaSeparatedText, .utf8PlainText]
    let bytes: Data

    init(bytes: Data) { self.bytes = bytes }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}
