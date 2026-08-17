import Foundation
import UIKit

struct LocalAppPersistence {
    enum PersistenceError: Error {
        case unsupportedSchema(Int)
    }

    struct Snapshot: Codable, Equatable {
        var schemaVersion: Int
        var diary: DailyDiary
        var nutritionTarget: Nutrition
        var targetWeight: Double
        var defaultMode: String
        var proxyBaseURLString: String
    }

    static let currentSchemaVersion = 1
    let fileURL: URL

    init(fileURL: URL = LocalAppPersistence.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try JSONDecoder.localApp.decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == Self.currentSchemaVersion else {
            throw PersistenceError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
    }

    func save(_ snapshot: Snapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.localApp.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("HeatCalMockApp", isDirectory: true)
            .appendingPathComponent("LocalData.json")
    }
}

@MainActor
final class AppStore: ObservableObject {
    enum Modal: String, Identifiable, Equatable {
        case recordMenu
        case analysisConfirmation
        case actualIntake
        case pendingRecovery
        case errorState
        case textRecordInput
        case photoAnalysisProgress
        case settings

        var id: String { rawValue }
    }

    @Published var diary: DailyDiary {
        didSet { saveLocalData() }
    }
    @Published var selectedDate: Date
    @Published var selectedTab: AppTab = .today
    @Published var activeModal: Modal?
    @Published var isCameraPresented = false
    @Published var draftEntry: MealEntry?
    @Published var editingEntryID: MealEntry.ID?
    @Published var correctionMessage: String?
    @Published var pendingFoodCorrection: PendingFoodCorrection?
    @Published var pendingMealWideRatio: Double?
    @Published var mealWideConfirmationMessage: String?
    @Published var mockErrorState: MockErrorState?
    @Published var toast: String?
    @Published var aiStatusMessage: String = "真实 AI：等待服务连接；FALLBACK 仅作故障兜底"
    @Published var defaultMode: String = "快速模式" {
        didSet { saveLocalData() }
    }
    @Published var textRecordDraft: String = ""
    @Published var isPhotoAnalysisInProgress = false
    @Published var isTextAnalysisInProgress = false
    @Published var isDraftCorrectionInProgress = false
    @Published var draftMealTypeWasManuallyChanged = false
    @Published var proxyBaseURLString: String {
        didSet { saveLocalData() }
    }
    @Published var proxyConnectionMessage: String?
    @Published var nutritionTarget: Nutrition = AppStore.defaultNutritionTarget {
        didSet { saveLocalData() }
    }
    @Published var targetWeight: Double = AppStore.defaultTargetWeight {
        didSet { saveLocalData() }
    }
    @Published var localDataMessage: String?

    private let analysisService = MockAnalysisService()
    private var proxyClient: AIProxyClient
    private var activePhotoAnalysisID: UUID?
    private let persistence: LocalAppPersistence?
    private var isApplyingLocalData = false
    private static let proxyBaseURLDefaultsKey = "HeatCalAIProxyBaseURL"
    static let defaultProxyBaseURLString = "http://127.0.0.1:8787"
    private static let legacyLocalProxyHosts = ["127.0.0.1", "localhost"]
    static let defaultNutritionTarget = Nutrition(calories: 1820, protein: 110, carbs: 210, fat: 60)
    static let defaultTargetWeight = 62.0

    init(
        diary: DailyDiary,
        selectedDate: Date = Date(),
        proxyClient: AIProxyClient? = nil,
        persistence: LocalAppPersistence? = nil,
        loadPersistedData: Bool = true
    ) {
        var initialDiary = diary
        var initialNutritionTarget = Self.defaultNutritionTarget
        var initialTargetWeight = Self.defaultTargetWeight
        var initialDefaultMode = "快速模式"
        var initialLocalDataMessage: String?
        var initialProxyBaseURLString: String

        if let proxyClient {
            initialProxyBaseURLString = proxyClient.baseURL.absoluteString
        } else {
            initialProxyBaseURLString = UserDefaults.standard.string(forKey: Self.proxyBaseURLDefaultsKey) ?? Self.defaultProxyBaseURLString
        }

        if loadPersistedData, let persistence {
            do {
                if let snapshot = try persistence.load() {
                    initialDiary = snapshot.diary
                    initialNutritionTarget = snapshot.nutritionTarget
                    initialTargetWeight = snapshot.targetWeight
                    initialDefaultMode = snapshot.defaultMode
                    initialProxyBaseURLString = snapshot.proxyBaseURLString
                }
            } catch {
                initialDiary = DailyDiary(entries: [], weights: [])
                initialNutritionTarget = Self.defaultNutritionTarget
                initialTargetWeight = Self.defaultTargetWeight
                initialDefaultMode = "快速模式"
                initialProxyBaseURLString = Self.defaultProxyBaseURLString
                initialLocalDataMessage = "本机数据无法读取，已使用空白数据启动。你可以在设置中清空本机数据重新开始。"
            }
        }

        self.diary = initialDiary
        self.selectedDate = selectedDate
        self.defaultMode = initialDefaultMode
        self.nutritionTarget = initialNutritionTarget
        self.targetWeight = initialTargetWeight
        self.persistence = persistence
        self.localDataMessage = initialLocalDataMessage
        if let proxyClient {
            self.proxyClient = proxyClient
            self.proxyBaseURLString = initialProxyBaseURLString
        } else {
            let resolvedProxyBaseURLString = Self.resolvedInitialProxyBaseURLString(initialProxyBaseURLString)
            let proxyURL = URL(string: resolvedProxyBaseURLString) ?? URL(string: Self.defaultProxyBaseURLString)!
            self.proxyClient = AIProxyClient(baseURL: proxyURL)
            self.proxyBaseURLString = proxyURL.absoluteString
            if proxyURL.absoluteString != initialProxyBaseURLString {
                UserDefaults.standard.removeObject(forKey: Self.proxyBaseURLDefaultsKey)
            }
        }
    }

    static func live() -> AppStore {
        AppStore(diary: DailyDiary(entries: [], weights: []), persistence: LocalAppPersistence())
    }

    static func seeded() -> AppStore {
        let now = Date()
        let breakfast = try! MealEntry.confirmed(
            date: now,
            mealType: .breakfast,
            items: [
                .recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10), confidence: "较高"),
                .recognized(name: "拿铁", amount: 1, unit: "杯", grams: 300, nutrition: Nutrition(calories: 180, protein: 9, carbs: 18, fat: 7), confidence: "一般")
            ],
            sourceDescription: "初始早餐",
            confidence: "较高",
            estimatedRange: 290...360
        )
        let lunch = try! MealEntry.confirmed(
            date: now,
            mealType: .lunch,
            items: [
                .recognized(name: "宫保鸡丁", amount: 1, unit: "份", grams: 260, nutrition: Nutrition(calories: 420, protein: 28, carbs: 24, fat: 24), confidence: "一般"),
                .recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1), confidence: "一般")
            ],
            sourceDescription: "初始午餐",
            confidence: "一般",
            estimatedRange: 520...760
        )
        let pending = MealEntry.pending(date: now, mealType: .dinner, description: "一份盖饭，米饭吃了一半")
        let weights = [
            WeightEntry(date: now.addingTimeInterval(-86400 * 28), weight: 69.6),
            WeightEntry(date: now.addingTimeInterval(-86400 * 20), weight: 69.2),
            WeightEntry(date: now.addingTimeInterval(-86400 * 12), weight: 68.9),
            WeightEntry(date: now.addingTimeInterval(-86400 * 5), weight: 68.6),
            WeightEntry(date: now, weight: 68.4)
        ]

        return AppStore(diary: DailyDiary(entries: [breakfast, lunch, pending], weights: weights), selectedDate: now)
    }

    var dailyTarget: Nutrition {
        nutritionTarget
    }

    var todayNutrition: Nutrition {
        diary.nutrition(on: selectedDate)
    }

    var selectedEntries: [MealEntry] {
        diary.entries(on: selectedDate)
    }

    func openRecordMenu() {
        activeModal = .recordMenu
    }

    func openCameraCapture() {
        guard !isPhotoAnalysisInProgress else {
            toast = "图片正在分析中，请稍候。"
            return
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            toast = "当前设备无法打开相机，可从相册选择照片或使用文字补记。"
            activeModal = .recordMenu
            return
        }
        activeModal = nil
        isCameraPresented = true
    }

    func applyProxyBaseURL(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            proxyConnectionMessage = "服务地址格式无效，请使用 http://地址:端口。"
            return
        }

        let normalized = Self.normalizedProxyBaseURL(url)
        proxyClient.baseURL = normalized
        proxyBaseURLString = normalized.absoluteString
        UserDefaults.standard.set(proxyBaseURLString, forKey: Self.proxyBaseURLDefaultsKey)
        proxyConnectionMessage = "服务地址已保存：\(proxyBaseURLString)"
        aiStatusMessage = "真实 AI：服务地址已更新"
    }

    func resetProxyBaseURLToSimulatorDefault() {
        let url = URL(string: Self.defaultProxyBaseURLString)!
        proxyClient.baseURL = url
        proxyBaseURLString = Self.defaultProxyBaseURLString
        UserDefaults.standard.removeObject(forKey: Self.proxyBaseURLDefaultsKey)
        proxyConnectionMessage = "已恢复默认服务地址：\(Self.defaultProxyBaseURLString)"
        aiStatusMessage = "真实 AI：使用默认服务地址"
    }

    func checkProxyHealth() {
        proxyConnectionMessage = "正在检查 AI 服务连接..."
        Task {
            do {
                let status = try await proxyClient.checkHealth()
                let configured = status.providers
                    .filter { $0.value.configured }
                    .map { userFacingProviderName($0.key) }
                    .sorted()
                    .joined(separator: "、")
                proxyConnectionMessage = configured.isEmpty
                    ? "连接检查通过：服务可访问，但暂未检测到可用 AI 能力。"
                    : "连接检查通过：服务可访问；可用能力 \(configured)。"
            } catch {
                proxyConnectionMessage = "连接检查失败：\(safeProxyErrorSummary(error))。请确认服务地址正确、手机与提供服务的电脑在同一网络，并且电脑端 AI 服务已启动。"
            }
        }
    }

    func startMockPhotoAnalysis(description: String = "宫保鸡丁盖饭") {
        clearTransientDraftState()
        mockErrorState = nil
        Task {
            let entry = await analysisService.analyze(.photo(description: description))
            aiStatusMessage = "FALLBACK：当前记录来自故障兜底分析"
            if entry.status == .confirmed {
                setNewDraftEntry(entry)
                activeModal = .analysisConfirmation
            } else {
                let pending = entry
                diary.entries.append(pending)
                saveLocalData()
                draftEntry = nil
                activeModal = .pendingRecovery
            }
        }
    }

    func startRealPhotoAnalysis(imageData: Data, mimeType: String = "image/jpeg", description: String = "用户选择的饮食照片") {
        guard !isPhotoAnalysisInProgress else {
            toast = "图片正在分析中，请稍候。"
            return
        }
        let requestID = UUID()
        let recordDate = defaultRecordDateForNewEntry()
        clearTransientDraftState()
        mockErrorState = nil
        isPhotoAnalysisInProgress = true
        activePhotoAnalysisID = requestID
        aiStatusMessage = "真实 AI：正在分析图片"
        activeModal = .photoAnalysisProgress
        Task {
            do {
                let entry = try await proxyClient.analyzePhoto(imageData: imageData, mimeType: mimeType, description: description)
                guard activePhotoAnalysisID == requestID else { return }
                setNewDraftEntry(entry, date: recordDate)
                isPhotoAnalysisInProgress = false
                activePhotoAnalysisID = nil
                aiStatusMessage = "真实 AI：图片分析结果"
                activeModal = .analysisConfirmation
            } catch {
                guard activePhotoAnalysisID == requestID else { return }
                draftEntry = nil
                isPhotoAnalysisInProgress = false
                activePhotoAnalysisID = nil
                mockErrorState = .realPhotoFailed
                aiStatusMessage = "真实 AI 图片分析失败，未生成示例食物结果：\(safeProxyErrorSummary(error))"
                activeModal = .errorState
            }
        }
    }

    func startMockTextAnalysis(_ text: String) {
        clearTransientDraftState()
        mockErrorState = nil
        Task {
            let entry = await analysisService.analyze(.text(text))
            setNewDraftEntry(entry)
            aiStatusMessage = "FALLBACK：当前记录来自故障兜底文字分析"
            activeModal = .analysisConfirmation
        }
    }

    func startRealTextAnalysis(_ text: String) {
        textRecordDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedText = textRecordDraft
        guard !submittedText.isEmpty, !isTextAnalysisInProgress else { return }
        clearTransientDraftState()
        mockErrorState = nil
        isTextAnalysisInProgress = true
        aiStatusMessage = "真实 AI：正在分析文字记录"
        Task {
            do {
                let entry = try await proxyClient.analyzeText(submittedText)
                setNewDraftEntry(entry)
                isTextAnalysisInProgress = false
                aiStatusMessage = "真实 AI：文字分析结果"
                activeModal = .analysisConfirmation
            } catch {
                draftEntry = nil
                isTextAnalysisInProgress = false
                mockErrorState = .realTextFailed
                aiStatusMessage = "真实 AI 文字分析失败，未生成示例食物结果：\(safeProxyErrorSummary(error))"
                activeModal = .errorState
            }
        }
    }

    func startMockHistoricalTextAnalysis() {
        clearTransientDraftState()
        mockErrorState = nil
        Task {
            let entry = await analysisService.analyze(.text("昨晚加餐：鸡蛋和拿铁"))
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? Date().addingTimeInterval(-86400)
            let historicalDate = Calendar.current.date(bySettingHour: 21, minute: 30, second: 0, of: yesterday) ?? yesterday
            setNewDraftEntry(entry, date: min(historicalDate, Date()))
            aiStatusMessage = "FALLBACK：历史补记来自故障兜底分析"
            activeModal = .analysisConfirmation
        }
    }

    func startDuplicateFoodClarificationDemo() {
        clearTransientDraftState()
        mockErrorState = nil
        let date = defaultRecordDateForNewEntry()
        let entry = try? MealEntry.confirmed(
            date: date,
            mealType: .lunch,
            items: [
                .recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1), note: "照片左侧"),
                .recognized(name: "米饭", amount: 1, unit: "份", grams: 160, nutrition: Nutrition(calories: 180, protein: 4, carbs: 40, fat: 1), note: "照片右侧"),
                .recognized(name: "宫保鸡丁", amount: 1, unit: "份", grams: 260, nutrition: Nutrition(calories: 420, protein: 28, carbs: 24, fat: 24), note: "照片上方")
            ],
            sourceDescription: "同名米饭澄清",
            confidence: "一般",
            estimatedRange: 720...880
        )
        if let entry {
            setNewDraftEntry(entry, date: date)
        }
        aiStatusMessage = "FALLBACK：同名项澄清来自故障兜底数据"
        activeModal = .actualIntake
        applyDraftLanguageCorrection("米饭吃了一半")
    }

    func startMockNutritionLabelAnalysis() {
        clearTransientDraftState()
        mockErrorState = nil
        Task {
            let entry = await analysisService.analyze(.nutritionLabel("包装食品营养成分表"))
            setNewDraftEntry(entry)
            aiStatusMessage = "FALLBACK：营养成分表来自故障兜底分析"
            activeModal = .analysisConfirmation
        }
    }

    func saveDraftEntry() {
        guard let draftEntry else { return }
        if draftEntry.hasUnconfirmedOverRecognizedAmount {
            correctionMessage = "存在超过识别份量的食物项，请在实际摄入页逐项确认后再保存。"
            activeModal = .actualIntake
            return
        }
        if let editingEntryID, let index = diary.entries.firstIndex(where: { $0.id == editingEntryID }) {
            diary.entries[index] = draftEntry
        } else {
            diary.entries.append(draftEntry)
        }
        let savedWasMock = draftEntry.isMockOnly
        saveLocalData()
        self.draftEntry = nil
        editingEntryID = nil
        draftMealTypeWasManuallyChanged = false
        clearTransientDraftState()
        activeModal = nil
        toast = savedWasMock ? "记录已保存；当前为 FALLBACK 结果" : "记录已保存；当前为真实 AI 结果"
    }

    func discardDraft() {
        draftEntry = nil
        editingEntryID = nil
        draftMealTypeWasManuallyChanged = false
        clearTransientDraftState()
        activeModal = nil
    }

    func editEntry(_ entry: MealEntry) {
        clearTransientDraftState()
        draftEntry = entry
        editingEntryID = entry.id
        draftMealTypeWasManuallyChanged = false
        activeModal = .analysisConfirmation
    }

    func deleteEntry(_ entry: MealEntry) {
        diary.entries.removeAll { $0.id == entry.id }
        saveLocalData()
    }

    func retryPending(_ entry: MealEntry) {
        clearTransientDraftState()
        Task {
            let analyzed = await analysisService.analyze(.photo(description: entry.sourceDescription))
            diary.entries.removeAll { $0.id == entry.id }
            saveLocalData()
            setNewDraftEntry(analyzed)
            aiStatusMessage = "FALLBACK：待分析重试当前使用故障兜底分析"
            activeModal = .analysisConfirmation
        }
    }

    func setDraftItemRatio(foodID: FoodItem.ID, ratio: Double) {
        do {
            try draftEntry?.setActualRatio(for: foodID, ratio: ratio, source: .itemAdjustment)
        } catch {
            correctionMessage = "未找到要调整的食物项"
        }
    }

    func setDraftCustomQuantity(foodID: FoodItem.ID, amount: Double, unit: String, grams: Double) {
        do {
            try draftEntry?.setCustomActualQuantity(for: foodID, amount: amount, unit: unit, grams: grams, source: .itemAdjustment)
        } catch {
            correctionMessage = "未找到要调整的食物项"
        }
    }

    func confirmDraftOverRecognizedAmount(foodID: FoodItem.ID) {
        do {
            try draftEntry?.confirmOverRecognizedAmount(for: foodID)
            correctionMessage = "已确认超过识别份量；可继续保存。"
        } catch {
            correctionMessage = "未找到要确认的食物项"
        }
    }

    func setDraftItemAmount(foodID: FoodItem.ID, amount: Double) {
        do {
            try draftEntry?.setActualAmount(for: foodID, amount: amount, source: .itemAdjustment)
        } catch {
            correctionMessage = "未找到要调整的食物项"
        }
    }

    func applyDraftMealRatio(_ ratio: Double) {
        guard var draftEntry else { return }
        let result = draftEntry.applyMealWideRatio(ratio)
        switch result {
        case .applied:
            self.draftEntry = draftEntry
            pendingMealWideRatio = nil
            mealWideConfirmationMessage = nil
        case .requiresConfirmation(let message):
            pendingMealWideRatio = ratio
            mealWideConfirmationMessage = message
        }
    }

    func confirmDraftMealRatioOverwrite() {
        guard var draftEntry, let pendingMealWideRatio else { return }
        _ = draftEntry.applyMealWideRatio(pendingMealWideRatio, confirmedOverwrite: true)
        self.draftEntry = draftEntry
        self.pendingMealWideRatio = nil
        mealWideConfirmationMessage = nil
    }

    func cancelDraftMealRatioOverwrite() {
        pendingMealWideRatio = nil
        mealWideConfirmationMessage = nil
    }

    func applyDraftLanguageCorrection(_ text: String) {
        guard var draftEntry else { return }
        pendingFoodCorrection = nil
        let result = draftEntry.applyLanguageCorrection(text)
        self.draftEntry = draftEntry

        switch result {
        case .applied(let foodNames):
            correctionMessage = "已应用到 \(foodNames.joined(separator: "、"))，保存前仍可修改。"
        case .needsClarification(let correction):
            pendingFoodCorrection = correction
            correctionMessage = "\(correction.foodName) 有多个候选，请选择目标项后应用。"
        case .noChange:
            correctionMessage = "未识别到可安全应用的逐项修正。"
        }
    }

    func applyRealDraftLanguageCorrection(_ text: String) {
        let submittedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedText.isEmpty, var draftEntry else { return }

        pendingFoodCorrection = nil
        let localNameCorrection = draftEntry.applyFoodNameCorrection(submittedText)
        if localNameCorrection != .noChange {
            self.draftEntry = draftEntry
            switch localNameCorrection {
            case .applied(let foodNames):
                correctionMessage = "已修正为 \(foodNames.joined(separator: "、"))；营养估算请保存前确认。"
            case .needsClarification(let correction):
                pendingFoodCorrection = correction
                correctionMessage = "\(correction.foodName) 有多个候选，请选择目标项后应用。"
            case .noChange:
                break
            }
            aiStatusMessage = "文字修正：已在本地安全应用食物名称纠错"
            return
        }

        aiStatusMessage = "真实 AI：正在解析修正"
        correctionMessage = "正在解析修正..."
        isDraftCorrectionInProgress = true
        Task {
            do {
                let response = try await proxyClient.parseCorrection(text: submittedText, items: draftEntry.items)
                applyProxyCorrection(response.correction, originalText: submittedText)
                isDraftCorrectionInProgress = false
                aiStatusMessage = "真实 AI：已解析修正"
            } catch {
                let previousMessage = correctionMessage
                applyDraftLanguageCorrection(submittedText)
                if correctionMessage == "未识别到可安全应用的逐项修正。" {
                    correctionMessage = "真实 AI 纠错请求失败，且本地规则未能安全应用。请编辑文字后重试，或手动调整食物项。"
                    aiStatusMessage = "真实 AI 纠错失败：\(safeProxyErrorSummary(error))"
                } else {
                    aiStatusMessage = "真实 AI 纠错失败，已本地应用可安全识别的修正：\(safeProxyErrorSummary(error))"
                }
                if previousMessage == correctionMessage {
                    correctionMessage = "真实 AI 纠错请求失败，请编辑文字后重试。"
                }
                isDraftCorrectionInProgress = false
            }
        }
    }

    func applyPendingFoodCorrection(to foodID: FoodItem.ID) {
        guard var draftEntry, let pendingFoodCorrection else { return }
        do {
            try draftEntry.applyClarifiedCorrection(pendingFoodCorrection, selectedFoodID: foodID)
            self.draftEntry = draftEntry
            correctionMessage = "已应用到所选 \(pendingFoodCorrection.foodName)，保存前仍可修改。"
            self.pendingFoodCorrection = nil
        } catch {
            correctionMessage = "未找到所选食物项"
        }
    }

    func updateDraftDate(_ date: Date) {
        guard var draftEntry else { return }
        do {
            let mealType = draftMealTypeWasManuallyChanged ? draftEntry.mealType : MealType.inferred(from: date)
            try draftEntry.updateSchedule(date: date, mealType: mealType)
            self.draftEntry = draftEntry
            correctionMessage = nil
        } catch MealEntryError.futureDateNotAllowed {
            correctionMessage = "不能创建未来日期的饮食记录。"
            toast = "未来日期不可保存"
        } catch {
            correctionMessage = "日期更新失败，请重试。"
        }
    }

    func updateDraftMealType(_ mealType: MealType) {
        guard var draftEntry else { return }
        do {
            try draftEntry.updateSchedule(date: draftEntry.date, mealType: mealType)
            self.draftEntry = draftEntry
            draftMealTypeWasManuallyChanged = true
        } catch {
            correctionMessage = "餐段更新失败，请重试。"
        }
    }

    var todayWeight: WeightEntry? {
        weight(on: Date())
    }

    var latestWeight: WeightEntry? {
        diary.weights.max { $0.date < $1.date }
    }

    func weight(on date: Date) -> WeightEntry? {
        diary.weights.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    func saveTodayWeight(_ weight: Double) {
        saveWeight(weight, on: Date())
    }

    @discardableResult
    func saveWeight(_ weight: Double, on date: Date) -> Bool {
        guard date <= Date() else {
            toast = "未来日期不可保存"
            return false
        }
        diary.weights.removeAll { Calendar.current.isDate($0.date, inSameDayAs: date) }
        diary.weights.append(WeightEntry(date: date, weight: weight))
        diary.weights.sort { $0.date < $1.date }
        saveLocalData()
        toast = Calendar.current.isDateInToday(date) ? "今日体重已更新" : "体重记录已保存"
        return true
    }

    func updateTargets(nutrition: Nutrition, targetWeight: Double) {
        nutritionTarget = nutrition
        self.targetWeight = targetWeight
        saveLocalData()
    }

    func clearAllLocalData() {
        isApplyingLocalData = true
        diary = DailyDiary(entries: [], weights: [])
        nutritionTarget = Self.defaultNutritionTarget
        targetWeight = Self.defaultTargetWeight
        defaultMode = "快速模式"
        let defaultProxyURL = URL(string: Self.defaultProxyBaseURLString)!
        proxyClient.baseURL = defaultProxyURL
        proxyBaseURLString = Self.defaultProxyBaseURLString
        UserDefaults.standard.removeObject(forKey: Self.proxyBaseURLDefaultsKey)
        draftEntry = nil
        editingEntryID = nil
        draftMealTypeWasManuallyChanged = false
        clearTransientDraftState()
        isApplyingLocalData = false
        saveLocalData()
        localDataMessage = "已清空本机数据，可重新开始记录。"
        toast = "本机数据已清空"
    }

    func saveLocalData() {
        guard !isApplyingLocalData, let persistence else { return }
        let snapshot = LocalAppPersistence.Snapshot(
            schemaVersion: LocalAppPersistence.currentSchemaVersion,
            diary: diary,
            nutritionTarget: nutritionTarget,
            targetWeight: targetWeight,
            defaultMode: defaultMode,
            proxyBaseURLString: proxyBaseURLString
        )
        do {
            try persistence.save(snapshot)
        } catch {
            localDataMessage = "本机数据保存失败，请稍后重试或清空本机数据重新开始。"
        }
    }

    func showPermissionDenied(_ permission: String) {
        toast = "\(permission)权限被拒绝：可改用其他记录方式或到系统设置开启。"
    }

    func showMockErrorState(_ state: MockErrorState) {
        mockErrorState = state
        activeModal = .errorState
    }

    func openTextRecordInput(prefill: String? = nil) {
        if let prefill {
            textRecordDraft = prefill
        }
        activeModal = .textRecordInput
    }

    func cancelPhotoAnalysis() {
        activePhotoAnalysisID = nil
        isPhotoAnalysisInProgress = false
        aiStatusMessage = "真实 AI：图片分析已取消"
        activeModal = .recordMenu
    }

    func retryTextRecordInput() {
        let text = textRecordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            openTextRecordInput()
            return
        }
        startRealTextAnalysis(text)
    }

    func continueFromMockErrorWithText() {
        startMockTextAnalysis("补充文字后继续：鸡蛋和拿铁")
    }

    func convertMockErrorToTextRecord() {
        startMockTextAnalysis("转文字记录：宫保鸡丁吃了一半，米饭全部吃完")
    }

    private func clearTransientDraftState() {
        correctionMessage = nil
        pendingFoodCorrection = nil
        pendingMealWideRatio = nil
        mealWideConfirmationMessage = nil
    }

    private func setNewDraftEntry(_ entry: MealEntry, date: Date? = nil) {
        var scheduledEntry = entry
        let finalDate = min(date ?? entry.date, Date())
        let inferredMealType = MealType.inferred(from: finalDate)
        try? scheduledEntry.updateSchedule(date: finalDate, mealType: inferredMealType)
        draftMealTypeWasManuallyChanged = false
        draftEntry = scheduledEntry
    }

    private func defaultRecordDateForNewEntry(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let selected = calendar.dateComponents([.year, .month, .day], from: selectedDate)
        let currentTime = calendar.dateComponents([.hour, .minute, .second], from: now)
        var components = DateComponents()
        components.year = selected.year
        components.month = selected.month
        components.day = selected.day
        components.hour = currentTime.hour
        components.minute = currentTime.minute
        components.second = currentTime.second
        let combined = calendar.date(from: components) ?? now
        return min(combined, now)
    }

    private func applyProxyCorrection(_ correction: AIProxyClient.CorrectionResponse.CorrectionPayload, originalText: String) {
        guard var draftEntry else { return }
        if correction.needsClarification {
            correctionMessage = "真实 AI 认为需要澄清目标食物，请改用同名项选择或手动调整。"
            return
        }
        var appliedNames: [String] = []
        for itemCorrection in correction.corrections where itemCorrection.match == "exact" {
            guard let index = draftEntry.items.firstIndex(where: { $0.name == itemCorrection.foodName }) else {
                continue
            }
            do {
                if let ratio = itemCorrection.ratio {
                    try draftEntry.setActualRatio(for: draftEntry.items[index].id, ratio: ratio, source: .languageCorrection)
                } else if let amount = itemCorrection.amount {
                    try draftEntry.setActualAmount(for: draftEntry.items[index].id, amount: amount, source: .languageCorrection)
                } else {
                    continue
                }
                appliedNames.append(itemCorrection.foodName)
            } catch {
                correctionMessage = "真实 AI 纠错结果无法应用到当前食物项。"
            }
        }
        self.draftEntry = draftEntry
        if appliedNames.isEmpty {
            applyDraftLanguageCorrection(originalText)
            if correctionMessage == "未识别到可安全应用的逐项修正。" {
                correctionMessage = "真实 AI 未返回可安全应用的修正。请编辑文字后重试，或手动调整食物项。"
            }
        } else {
            correctionMessage = "真实 AI 已应用到 \(appliedNames.joined(separator: "、"))，保存前仍可修改。"
        }
    }

    private func safeProxyErrorSummary(_ error: Error) -> String {
        if let proxyError = error as? AIProxyClient.ProxyError {
            return "\(proxyError.provider)/\(proxyError.code)"
        }
        if let urlError = error as? URLError {
            return "network/\(urlError.code.rawValue)"
        }
        return "proxy_error"
    }

    private func userFacingProviderName(_ key: String) -> String {
        switch key.lowercased() {
        case "dashscope":
            return "图片分析"
        case "deepseek":
            return "文字与纠错"
        case "openai":
            return "OpenAI"
        default:
            return key
        }
    }

    private static func resolvedInitialProxyBaseURLString(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host?.lowercased() else {
            return Self.defaultProxyBaseURLString
        }
        if legacyLocalProxyHosts.contains(host) {
            return Self.defaultProxyBaseURLString
        }
        return value
    }

    private static func normalizedProxyBaseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url ?? url
    }
}

private extension JSONEncoder {
    static var localApp: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var localApp: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum AppTab: String {
    case today
    case trend
}

enum MockErrorState: String, Identifiable, Equatable {
    case blurryPhoto
    case realPhotoFailed
    case realTextFailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blurryPhoto: "照片模糊，无法识别"
        case .realPhotoFailed: "图片分析失败"
        case .realTextFailed: "文字分析失败"
        }
    }

    var message: String {
        switch self {
        case .blurryPhoto:
            "照片过暗或主体不清晰。你可以补充文字后继续分析，或直接改用文字补记。"
        case .realPhotoFailed:
            "真实 AI 图片分析未返回可用结果。本次不会自动生成示例食物结果；你可以改用文字补记。"
        case .realTextFailed:
            "真实 AI 文字分析未返回可用结果。本次不会用示例食物替代你的输入；你可以重试，或编辑文字后重试。"
        }
    }
}
