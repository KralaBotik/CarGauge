import CarGaugeCore
import PDFKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct MaintenanceRecordEditor: View {
    let components: [MaintenanceComponent]
    let commit: MaintenanceCommit
    @State private var draft: MaintenanceRecord
    @State private var isImporting = false
    @State private var photo: PhotosPickerItem?
    @State private var fileError: String?
    @State private var preview: MaintenanceAttachment?
    @State private var confirmsRemoval = false
    @State private var fileToRemove: MaintenanceAttachment?

    init(record: MaintenanceRecord?, components: [MaintenanceComponent], commit: @escaping MaintenanceCommit) {
        _draft = State(initialValue: record ?? .init(date: .init(.now), work: [.init(componentID: "")]))
        self.components = components
        self.commit = commit
    }

    var body: some View {
        MaintenanceEditorForm(title: "Обслуживание", identifier: "maintenance-record-editor",
                              saveIdentifier: "maintenance-save-record", save: { try await commit(.saveRecord(draft)) }) {
            Section("Общие сведения") {
                MaintenanceBasisDate(title: "Дата работы", value: $draft.date)
                MaintenanceBasisNumber(title: "Пробег, км", value: $draft.odometer)
                MaintenanceBasisNumber(title: "Моточасы, ч", value: $draft.engineHours)
                Picker("Где выполнено", selection: $draft.provider) {
                    ForEach(MaintenanceProvider.allCases) { Text($0.title).tag($0) }
                }
                TextField("Комментарий к записи", text: $draft.comment, axis: .vertical)
            }
            Section("Работы") {
                ForEach($draft.work) { $job in
                    MaintenanceWorkEditor(work: $job, components: components)
                }
                .onDelete { draft.work.remove(atOffsets: $0) }
                Button("Добавить ещё работу") { draft.work.append(.init(componentID: "")) }
                    .accessibilityIdentifier("maintenance-add-work")
                    .disabled(draft.work.count >= 64)
            }
            Section("Фото и чеки") {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Добавить фото", systemImage: "photo")
                }
                .disabled(draft.attachments.count >= 8)
                Button("Добавить файл") { isImporting = true }
                    .disabled(draft.attachments.count >= 8)
                ForEach(draft.attachments) { file in
                    HStack {
                        Button { preview = file } label: {
                            Label(file.filename, systemImage: file.mediaType == "application/pdf" ? "doc" : "photo")
                        }
                        Spacer()
                        Button(role: .destructive) {
                            fileToRemove = file
                            confirmsRemoval = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Удалить вложение")
                    }
                }
                Text("До 2 МиБ на файл и 8 МиБ на запись. Изображения и PDF остаются в устройстве.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let fileError { Text(fileError).font(.footnote).foregroundStyle(.red) }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.jpeg, .png, .heic, .heif, .pdf]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let content = try FileHandle(forReadingFrom: url)
                defer { try? content.close() }
                let bytes = try content.read(upToCount: MaintenanceLedger.fileByteLimit + 1) ?? Data()
                let media = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                guard let media else { throw MaintenanceValidationError.invalidFile }
                try addAttachment(.init(filename: url.lastPathComponent, mediaType: media, data: bytes))
            } catch {
                fileError = error.localizedDescription
            }
        }
        .task(id: photo) {
            guard let selected = photo else { return }
            do {
                guard let bytes = try await selected.loadTransferable(type: Data.self),
                      let image = UIImage(data: bytes) else { throw MaintenanceValidationError.invalidFile }
                guard !Task.isCancelled, selected == photo else { return }
                let size = image.size
                let ratio = min(1, 1800 / max(1, max(size.width, size.height)))
                let target = CGSize(width: size.width * ratio, height: size.height * ratio)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let renderer = UIGraphicsImageRenderer(size: target, format: format)
                let jpeg = renderer.jpegData(withCompressionQuality: 0.82) { _ in
                    image.draw(in: CGRect(origin: .zero, size: target))
                }
                try addAttachment(.init(filename: "Фото \(draft.attachments.count + 1).jpg", mediaType: "image/jpeg", data: jpeg))
            } catch is CancellationError {
                return
            } catch {
                guard selected == photo else { return }
                fileError = error.localizedDescription
            }
            if selected == photo { photo = nil }
        }
        .sheet(item: $preview) { file in
            MaintenanceAttachmentViewer(file: file)
        }
        .confirmationDialog("Удалить вложение?", isPresented: $confirmsRemoval,
                            titleVisibility: .visible, presenting: fileToRemove) { file in
            Button("Удалить", role: .destructive) { draft.attachments.removeAll { $0.id == file.id } }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func addAttachment(_ file: MaintenanceAttachment) throws {
        guard file.data.count <= MaintenanceLedger.fileByteLimit else { throw MaintenanceValidationError.fileLimit }
        guard draft.attachments.count < 8, draft.attachmentBytes + file.data.count <= MaintenanceLedger.recordFileByteLimit else {
            throw MaintenanceValidationError.recordFileLimit
        }
        guard !file.data.isEmpty, MaintenanceLedger.allowedMedia.contains(file.mediaType) else {
            throw MaintenanceValidationError.invalidFile
        }
        draft.attachments.append(file)
        fileError = nil
    }
}

@MainActor
private struct MaintenanceWorkEditor: View {
    @Binding var work: MaintenanceWork
    let components: [MaintenanceComponent]
    @State private var showDetails = true

    var body: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            Picker("Компонент", selection: $work.componentID) {
                Text("Выберите").tag("")
                ForEach(components) { Text($0.title).tag($0.id) }
            }
            .accessibilityIdentifier("maintenance-work-component")
            Picker("Вид работы", selection: $work.operation) {
                ForEach(MaintenanceOperation.allCases) { Text($0.title).tag($0) }
            }
            MaintenanceMoneyField(title: "Стоимость работ, ₽", value: $work.laborCostMinor)
            TextField("Комментарий к работе", text: $work.comment, axis: .vertical)
            if work.inspection != nil {
                MaintenanceInspectionEditor(inspection: Binding(
                    get: { work.inspection ?? .init() }, set: { work.inspection = $0 }
                ), componentID: work.componentID)
                Button("Убрать данные осмотра", role: .destructive) { work.inspection = nil }
            } else {
                Button("Добавить измерения и осмотр") { work.inspection = .init() }
            }
            ForEach($work.parts) { $part in
                MaintenancePartEditor(part: $part)
            }
            .onDelete { work.parts.remove(atOffsets: $0) }
            Button("Добавить запчасть или жидкость") { work.parts.append(.init()) }
                .disabled(work.parts.count >= 32)
        } label: {
            Text(components.first { $0.id == work.componentID }?.title ?? "Новая работа").font(.headline)
        }
    }
}

private struct MaintenancePartEditor: View {
    @Binding var part: MaintenancePart
    var body: some View {
        DisclosureGroup(part.maker.isEmpty ? "Запчасть или жидкость" : part.maker) {
            TextField("Производитель", text: $part.maker)
            TextField("Артикул", text: $part.partNumber)
            TextField("Характеристики и допуск", text: $part.specification, axis: .vertical)
            MaintenanceNumberField(title: "Количество или объём", value: $part.quantity)
            TextField("Единица измерения", text: $part.unit)
            MaintenanceMoneyField(title: "Стоимость, ₽", value: $part.costMinor)
        }
    }
}

private struct MaintenanceInspectionEditor: View {
    @Binding var inspection: MaintenanceInspection
    let componentID: String

    var body: some View {
        DisclosureGroup("Результат и измерения") {
            Picker("Место осмотра", selection: $inspection.position) {
                ForEach(MaintenancePosition.allCases) { Text($0.title).tag($0) }
            }
            Picker("Заключение осмотра", selection: $inspection.finding) {
                ForEach(MaintenanceFinding.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Назначить повторный осмотр", isOn: Binding(
                get: { inspection.nextCheck != nil },
                set: { inspection.nextCheck = $0 ? (Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now) : nil }
            ))
            if inspection.nextCheck != nil {
                DatePicker("Следующая проверка", selection: Binding(
                    get: { inspection.nextCheck ?? .now }, set: { inspection.nextCheck = $0 }
                ), displayedComponents: .date)
            }
            if componentID == "battery" || componentID.hasPrefix("tyre") {
                MaintenanceBasisDate(title: "Дата производства или установки", value: $inspection.manufactureOrInstallation)
            }
            if componentID.hasPrefix("tyre") {
                TextField("Размер", text: $inspection.dimensions)
                TextField("Сезон установки", text: $inspection.season)
            }
            TextField("Поверхность, повреждения, результат теста", text: $inspection.condition, axis: .vertical)
            ForEach($inspection.measurements) { $measurement in
                Picker("Параметр", selection: $measurement.kind) {
                    ForEach(MaintenanceMeasurementKind.allCases) { Text($0.title).tag($0) }
                }
                MaintenanceNumberField(title: measurement.kind.title, value: Binding(
                    get: { measurement.value.isFinite ? measurement.value : nil },
                    set: { measurement.value = $0 ?? .nan }
                ))
                TextField(measurement.kind == .discLimitMm ? "Источник минимума" : "Оборудование или источник",
                          text: $measurement.source)
            }
            .onDelete { inspection.measurements.remove(atOffsets: $0) }
            Button("Добавить измерение") {
                let defaults: [String: MaintenanceMeasurementKind] = [
                    "front-pads": .frictionMm, "rear-pads": .frictionMm,
                    "front-discs": .discMm, "rear-discs": .discMm, "battery": .batteryVoltage,
                    "tyres": .tyreTreadMm, "tyre-pressure": .tyrePressureKPa
                ]
                inspection.measurements.append(.init(kind: defaults[componentID] ?? .tyreTreadMm, value: .nan))
            }
            .disabled(inspection.measurements.count >= 24)
        }
    }
}

@MainActor
private struct MaintenanceAttachmentViewer: View {
    let file: MaintenanceAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if file.mediaType == "application/pdf", let document = PDFDocument(data: file.data) {
                    MaintenancePDFView(document: document)
                } else if let image = UIImage(data: file.data) {
                    ScrollView {
                        Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Фото обслуживания")
                    }
                } else {
                    ContentUnavailableView("Файл не открывается", systemImage: "doc")
                }
            }
            .navigationTitle(file.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Закрыть") { dismiss() } }
        }
    }
}

@MainActor
private struct MaintenancePDFView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) { uiView.document = document }
}
