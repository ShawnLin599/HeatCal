import Foundation

struct Nutrition: Equatable, Codable {
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double

    static let zero = Nutrition(calories: 0, protein: 0, carbs: 0, fat: 0)

    func scaled(by ratio: Double) -> Nutrition {
        Nutrition(
            calories: calories * ratio,
            protein: protein * ratio,
            carbs: carbs * ratio,
            fat: fat * ratio
        )
    }

    static func + (lhs: Nutrition, rhs: Nutrition) -> Nutrition {
        Nutrition(
            calories: lhs.calories + rhs.calories,
            protein: lhs.protein + rhs.protein,
            carbs: lhs.carbs + rhs.carbs,
            fat: lhs.fat + rhs.fat
        )
    }
}

enum MealType: String, CaseIterable, Identifiable, Codable {
    case breakfast
    case lunch
    case dinner
    case snack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakfast: "早餐"
        case .lunch: "午餐"
        case .dinner: "晚餐"
        case .snack: "加餐"
        }
    }

    static func inferred(from date: Date, calendar: Calendar = .current) -> MealType {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5...10: return .breakfast
        case 11...14: return .lunch
        case 17...21: return .dinner
        default: return .snack
        }
    }
}

struct Quantity: Equatable, Codable {
    var amount: Double
    var unit: String
    var grams: Double
    var size: String?

    var displayText: String {
        let amountText = amount.rounded(.down) == amount ? String(Int(amount)) : String(format: "%.1f", amount)
        if let size {
            return "\(amountText) \(unit)，\(size)"
        }
        return "\(amountText) \(unit)"
    }

    func withAmount(_ newAmount: Double) -> Quantity {
        let ratio = amount == 0 ? 0 : newAmount / amount
        return Quantity(amount: newAmount, unit: unit, grams: grams * ratio, size: size)
    }

    func custom(amount: Double, unit: String, grams: Double) -> Quantity {
        Quantity(amount: max(0, amount), unit: unit, grams: max(0, grams), size: nil)
    }

    func scaled(by ratio: Double) -> Quantity {
        Quantity(amount: amount * ratio, unit: unit, grams: grams * ratio, size: size)
    }
}

enum IntakeSource: String, Equatable, Codable {
    case defaultFull
    case mealWideRatio
    case itemAdjustment
    case languageCorrection
}

struct FoodItem: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var recognizedQuantity: Quantity
    var actualQuantity: Quantity
    var recognizedNutrition: Nutrition
    var intakeSource: IntakeSource
    var confidence: String
    var note: String?
    var overRecognizedAmountConfirmed: Bool

    var actualNutrition: Nutrition {
        guard recognizedQuantity.grams > 0 else { return .zero }
        return recognizedNutrition.scaled(by: actualQuantity.grams / recognizedQuantity.grams)
    }

    var isOverRecognizedAmount: Bool {
        actualQuantity.grams > recognizedQuantity.grams
    }

    static func recognized(
        id: UUID = UUID(),
        name: String,
        amount: Double,
        unit: String,
        grams: Double,
        nutrition: Nutrition,
        size: String? = nil,
        confidence: String = "一般",
        note: String? = nil
    ) -> FoodItem {
        let quantity = Quantity(amount: amount, unit: unit, grams: grams, size: size)
        return FoodItem(
            id: id,
            name: name,
            recognizedQuantity: quantity,
            actualQuantity: quantity,
            recognizedNutrition: nutrition,
            intakeSource: .defaultFull,
            confidence: confidence,
            note: note,
            overRecognizedAmountConfirmed: false
        )
    }

    mutating func setActualAmount(_ amount: Double, source: IntakeSource) {
        actualQuantity = recognizedQuantity.withAmount(max(0, amount))
        intakeSource = source
        overRecognizedAmountConfirmed = false
    }

    mutating func setCustomActualQuantity(amount: Double, unit: String, grams: Double, source: IntakeSource) {
        actualQuantity = recognizedQuantity.custom(amount: amount, unit: unit, grams: grams)
        intakeSource = source
        overRecognizedAmountConfirmed = false
    }

    mutating func applyRatio(_ ratio: Double, source: IntakeSource) {
        actualQuantity = recognizedQuantity.scaled(by: max(0, ratio))
        intakeSource = source
        overRecognizedAmountConfirmed = false
    }

    mutating func confirmOverRecognizedAmount() {
        overRecognizedAmountConfirmed = isOverRecognizedAmount
    }

    mutating func applyNameCorrection(to newName: String) {
        let originalName = name
        name = newName
        intakeSource = .languageCorrection
        overRecognizedAmountConfirmed = false

        if let estimate = FoodItem.commonEstimate(for: newName) {
            recognizedQuantity = estimate.quantity
            actualQuantity = estimate.quantity
            recognizedNutrition = estimate.nutrition
            confidence = "需确认"
            note = "已由文字修正为\(newName)，营养按常见份量估算，请保存前确认。"
        } else {
            confidence = "需确认"
            note = "原识别为\(originalName)；营养估算暂保留，请保存前确认。"
        }
    }

    private static func commonEstimate(for name: String) -> (quantity: Quantity, nutrition: Nutrition)? {
        let normalizedName = name.replacingOccurrences(of: " ", with: "")
        if normalizedName.contains("玉米") {
            return (
                Quantity(amount: 1, unit: "根", grams: 150, size: "中等"),
                Nutrition(calories: 165, protein: 5, carbs: 35, fat: 2)
            )
        }
        return nil
    }
}

enum AnalysisStatus: Equatable, Codable {
    case confirmed
    case pendingAnalysis(reason: String)

    var title: String {
        switch self {
        case .confirmed: "已确认"
        case .pendingAnalysis: "待分析"
        }
    }
}

enum MealEntryError: Error, Equatable {
    case foodItemNotFound
    case futureDateNotAllowed
}

enum LanguageCorrectionResult: Equatable {
    case applied(foodNames: [String])
    case needsClarification(PendingFoodCorrection)
    case noChange
}

enum IntakeAdjustmentAction: Equatable {
    case amount(Double)
    case ratio(Double)
}

struct FoodCorrectionCandidate: Identifiable, Equatable {
    let id: FoodItem.ID
    let label: String
}

struct PendingFoodCorrection: Equatable {
    let foodName: String
    let candidates: [FoodCorrectionCandidate]
    let action: IntakeAdjustmentAction
    let originalText: String
}

enum MealWideRatioResult: Equatable {
    case applied
    case requiresConfirmation(message: String)
}

struct MealEntry: Identifiable, Equatable, Codable {
    let id: UUID
    var date: Date
    var mealType: MealType
    var sourceDescription: String
    var status: AnalysisStatus
    var items: [FoodItem]
    var isMockOnly: Bool
    var confidence: String
    var estimatedRange: ClosedRange<Double>?
    var errorHint: String?
    var createdAt: Date

    var nutrition: Nutrition {
        guard status == .confirmed else { return .zero }
        return items.reduce(.zero) { $0 + $1.actualNutrition }
    }

    var requiresActualIntakeConfirmation: Bool {
        false
    }

    var hasUnconfirmedOverRecognizedAmount: Bool {
        items.contains { $0.isOverRecognizedAmount && !$0.overRecognizedAmountConfirmed }
    }

    static func confirmed(
        id: UUID = UUID(),
        date: Date,
        mealType: MealType,
        items: [FoodItem],
        sourceDescription: String = "mock 分析结果",
        confidence: String = "一般",
        estimatedRange: ClosedRange<Double>? = nil,
        isMockOnly: Bool = true
    ) throws -> MealEntry {
        MealEntry(
            id: id,
            date: date,
            mealType: mealType,
            sourceDescription: sourceDescription,
            status: .confirmed,
            items: items,
            isMockOnly: isMockOnly,
            confidence: confidence,
            estimatedRange: estimatedRange,
            errorHint: nil,
            createdAt: date
        )
    }

    static func pending(
        id: UUID = UUID(),
        date: Date,
        mealType: MealType,
        description: String,
        reason: String = "当前网络不可用"
    ) -> MealEntry {
        MealEntry(
            id: id,
            date: date,
            mealType: mealType,
            sourceDescription: description,
            status: .pendingAnalysis(reason: reason),
            items: [],
            isMockOnly: true,
            confidence: "待分析",
            estimatedRange: nil,
            errorHint: reason,
            createdAt: date
        )
    }

    mutating func setActualAmount(for foodID: FoodItem.ID, amount: Double, source: IntakeSource) throws {
        guard let index = items.firstIndex(where: { $0.id == foodID }) else {
            throw MealEntryError.foodItemNotFound
        }
        items[index].setActualAmount(amount, source: source)
    }

    mutating func setActualRatio(for foodID: FoodItem.ID, ratio: Double, source: IntakeSource) throws {
        guard let index = items.firstIndex(where: { $0.id == foodID }) else {
            throw MealEntryError.foodItemNotFound
        }
        items[index].applyRatio(ratio, source: source)
    }

    mutating func setCustomActualQuantity(for foodID: FoodItem.ID, amount: Double, unit: String, grams: Double, source: IntakeSource) throws {
        guard let index = items.firstIndex(where: { $0.id == foodID }) else {
            throw MealEntryError.foodItemNotFound
        }
        items[index].setCustomActualQuantity(amount: amount, unit: unit, grams: grams, source: source)
    }

    mutating func confirmOverRecognizedAmount(for foodID: FoodItem.ID) throws {
        guard let index = items.firstIndex(where: { $0.id == foodID }) else {
            throw MealEntryError.foodItemNotFound
        }
        items[index].confirmOverRecognizedAmount()
    }

    @discardableResult
    mutating func applyMealWideRatio(_ ratio: Double, confirmedOverwrite: Bool = false) -> MealWideRatioResult {
        if !confirmedOverwrite && items.contains(where: { $0.intakeSource != .defaultFull }) {
            return .requiresConfirmation(message: "整餐比例会覆盖当前各食物项的实际摄入调整。")
        }
        for index in items.indices {
            items[index].applyRatio(ratio, source: .mealWideRatio)
        }
        return .applied
    }

    mutating func applyLanguageCorrection(_ text: String) -> LanguageCorrectionResult {
        let nameCorrectionResult = applyFoodNameCorrection(text)
        if nameCorrectionResult != .noChange {
            return nameCorrectionResult
        }

        let normalized = text.replacingOccurrences(of: " ", with: "")
        let foodNames = Array(Set(items.map(\.name))).sorted { $0.count > $1.count }
        let fragments = normalized
            .split { "，,。；;、\n".contains($0) }
            .map(String.init)

        var plannedCorrections: [(foodName: String, index: Array<FoodItem>.Index, action: IntakeAdjustmentAction)] = []

        for fragment in fragments {
            for foodName in foodNames where fragment.contains(foodName) {
                guard let action = MealEntry.adjustmentAction(from: fragment) else {
                    continue
                }

                let matchingIndices = items.indices.filter { items[$0].name == foodName }
                guard !matchingIndices.isEmpty else {
                    continue
                }

                if matchingIndices.count > 1 {
                    let candidates = matchingIndices.map {
                        FoodCorrectionCandidate(
                            id: items[$0].id,
                            label: items[$0].note ?? items[$0].recognizedQuantity.displayText
                        )
                    }
                    return .needsClarification(
                        PendingFoodCorrection(
                            foodName: foodName,
                            candidates: candidates,
                            action: action,
                            originalText: text
                        )
                    )
                }

                plannedCorrections.append((foodName: foodName, index: matchingIndices[0], action: action))
            }
        }

        guard !plannedCorrections.isEmpty else {
            return .noChange
        }

        var appliedNames: [String] = []
        for correction in plannedCorrections {
            apply(correction.action, to: correction.index, source: .languageCorrection)
            if !appliedNames.contains(correction.foodName) {
                appliedNames.append(correction.foodName)
            }
        }

        return .applied(foodNames: appliedNames)
    }

    mutating func applyFoodNameCorrection(_ text: String) -> LanguageCorrectionResult {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        guard let request = MealEntry.foodNameCorrectionRequest(from: normalized) else {
            return .noChange
        }

        let matchingIndices = foodNameCorrectionTargetIndices(sourceName: request.sourceName, normalizedText: normalized)
        guard matchingIndices.count == 1, let index = matchingIndices.first else {
            return .noChange
        }

        items[index].applyNameCorrection(to: request.newName)
        return .applied(foodNames: [request.newName])
    }

    mutating func applyClarifiedCorrection(_ correction: PendingFoodCorrection, selectedFoodID: FoodItem.ID) throws {
        guard let index = items.firstIndex(where: { $0.id == selectedFoodID }) else {
            throw MealEntryError.foodItemNotFound
        }
        apply(correction.action, to: index, source: .languageCorrection)
    }

    mutating func updateSchedule(date: Date, mealType: MealType, now: Date = Date()) throws {
        if date > now {
            throw MealEntryError.futureDateNotAllowed
        }
        self.date = date
        self.mealType = mealType
    }

    private mutating func apply(_ action: IntakeAdjustmentAction, to index: Array<FoodItem>.Index, source: IntakeSource) {
        switch action {
        case .amount(let amount):
            items[index].setActualAmount(amount, source: source)
        case .ratio(let ratio):
            items[index].applyRatio(ratio, source: source)
        }
    }

    private func foodNameCorrectionTargetIndices(sourceName: String?, normalizedText: String) -> [Array<FoodItem>.Index] {
        if let sourceName, !sourceName.isEmpty {
            return items.indices.filter {
                let itemName = items[$0].name.replacingOccurrences(of: " ", with: "")
                return itemName == sourceName || itemName.contains(sourceName) || sourceName.contains(itemName)
            }
        }

        if items.count == 1 {
            return [items.startIndex]
        }

        return items.indices.filter {
            let itemName = items[$0].name.replacingOccurrences(of: " ", with: "")
            return normalizedText.contains(itemName)
        }
    }

    private static func foodNameCorrectionRequest(from text: String) -> (sourceName: String?, newName: String)? {
        let sourceTargetPatterns = [
            "把(.+?)(?:改成|改为|换成|换为|修正为)(.+)",
            "不是(.+?)(?:而是|是)(.+)",
            "(.+?)其实是(.+)",
            "(.+?)(?:改成|改为|换成|换为|修正为)(.+)"
        ]

        for pattern in sourceTargetPatterns {
            if let match = regexGroups(pattern: pattern, in: text), match.count == 2 {
                let sourceName = cleanedFoodName(match[0])
                let newName = cleanedFoodName(match[1])
                if !sourceName.isEmpty, !newName.isEmpty {
                    return (sourceName, newName)
                }
            }
        }

        let targetOnlyPatterns = [
            "(?:这个|这项|它|识别结果|识别的食物)(?:其实是|是)(.+)"
        ]
        for pattern in targetOnlyPatterns {
            if let match = regexGroups(pattern: pattern, in: text), let rawName = match.first {
                let newName = cleanedFoodName(rawName)
                if !newName.isEmpty {
                    return (nil, newName)
                }
            }
        }

        return nil
    }

    private static func regexGroups(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }

        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: text) else {
                return nil
            }
            groups.append(String(text[range]))
        }
        return groups
    }

    private static func cleanedFoodName(_ rawName: String) -> String {
        var name = rawName
        if let separatorRange = name.rangeOfCharacter(from: CharacterSet(charactersIn: "，,。；;、\n")) {
            name = String(name[..<separatorRange.lowerBound])
        }

        let removablePrefixes = ["这个", "这项", "它", "识别结果", "识别的食物", "其实是", "是"]
        for prefix in removablePrefixes where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }

        let removableSuffixes = ["了", "吧", "就行", "可以", "即可", "谢谢"]
        for suffix in removableSuffixes where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }

        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func adjustmentAction(from fragment: String) -> IntakeAdjustmentAction? {
        if fragment.contains("没吃") || fragment.contains("未吃") || fragment.contains("没动") || fragment.contains("不吃") {
            return .amount(0)
        }
        if fragment.contains("1/4") || fragment.contains("1／4") || fragment.contains("四分之一") {
            return .ratio(0.25)
        }
        if fragment.contains("一半") || fragment.contains("半份") || fragment.contains("半碗") || fragment.contains("半个") || fragment.contains("半") {
            return .ratio(0.5)
        }
        if fragment.contains("全部") || fragment.contains("吃完") || fragment.contains("喝完") || fragment.contains("全吃") {
            return .ratio(1)
        }
        if fragment.contains("三个") || fragment.contains("3个") || fragment.contains("三份") || fragment.contains("3份") || fragment.contains("三杯") || fragment.contains("3杯") {
            return .amount(3)
        }
        if fragment.contains("两个") || fragment.contains("2个") || fragment.contains("两份") || fragment.contains("2份") || fragment.contains("两杯") || fragment.contains("2杯") {
            return .amount(2)
        }
        if fragment.contains("一个") || fragment.contains("1个") || fragment.contains("一份") || fragment.contains("1份") || fragment.contains("一杯") || fragment.contains("1杯") {
            return .amount(1)
        }
        return nil
    }
}

struct WeightEntry: Identifiable, Equatable, Codable {
    let id: UUID
    var date: Date
    var weight: Double

    init(id: UUID = UUID(), date: Date, weight: Double) {
        self.id = id
        self.date = date
        self.weight = weight
    }
}

struct DailyDiary: Equatable, Codable {
    var entries: [MealEntry]
    var weights: [WeightEntry]

    func nutrition(on date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Nutrition {
        entries
            .filter { calendar.isDate($0.date, inSameDayAs: date) }
            .reduce(.zero) { $0 + $1.nutrition }
    }

    func entries(on date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> [MealEntry] {
        entries.filter { calendar.isDate($0.date, inSameDayAs: date) }
    }
}
