import XCTest
@testable import HeatCalMockApp

final class HeatCalMockAppTests: XCTestCase {
    func testDefaultFastPathUsesRecognizedQuantityWithoutExtraConfirmation() throws {
        let egg = FoodItem.recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10))
        let rice = FoodItem.recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1))

        let meal = try MealEntry.confirmed(date: .mockToday, mealType: .breakfast, items: [egg, rice])

        XCTAssertEqual(meal.items[0].actualQuantity.amount, 2)
        XCTAssertEqual(meal.items[1].actualQuantity.amount, 1)
        XCTAssertEqual(meal.nutrition.calories, 340, accuracy: 0.001)
        XCTAssertEqual(meal.requiresActualIntakeConfirmation, false)
    }

    func testSingleFoodActualIntakeScalesNutritionAndLeavesOtherItemsFull() throws {
        var meal = try MealEntry.confirmed(date: .mockToday, mealType: .lunch, items: [
            .recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10)),
            .recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1))
        ])

        try meal.setActualAmount(for: meal.items[0].id, amount: 1, source: .itemAdjustment)

        XCTAssertEqual(meal.items[0].actualNutrition.calories, 70, accuracy: 0.001)
        XCTAssertEqual(meal.items[1].actualNutrition.calories, 200, accuracy: 0.001)
        XCTAssertEqual(meal.nutrition.calories, 270, accuracy: 0.001)
    }

    func testMealWideRatioWritesEachFoodItemAndAllowsSingleItemOverride() throws {
        var meal = try MealEntry.confirmed(date: .mockToday, mealType: .dinner, items: [
            .recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1)),
            .recognized(name: "宫保鸡丁", amount: 1, unit: "份", grams: 260, nutrition: Nutrition(calories: 420, protein: 28, carbs: 24, fat: 24))
        ])

        meal.applyMealWideRatio(0.5)
        try meal.setActualAmount(for: meal.items[0].id, amount: 1, source: .itemAdjustment)

        XCTAssertEqual(meal.items[0].actualNutrition.calories, 200, accuracy: 0.001)
        XCTAssertEqual(meal.items[1].actualNutrition.calories, 210, accuracy: 0.001)
        XCTAssertEqual(meal.nutrition.calories, 410, accuracy: 0.001)
        XCTAssertEqual(meal.items[1].intakeSource, .mealWideRatio)
    }

    func testPendingEntriesDoNotContributeToDailyNutrition() throws {
        let confirmed = try MealEntry.confirmed(date: .mockToday, mealType: .lunch, items: [
            .recognized(name: "拿铁", amount: 1, unit: "杯", grams: 300, nutrition: Nutrition(calories: 180, protein: 9, carbs: 18, fat: 7))
        ])
        let pending = MealEntry.pending(date: .mockToday, mealType: .snack, description: "一份盖饭，米饭吃了一半")

        let diary = DailyDiary(entries: [confirmed, pending], weights: [])

        XCTAssertEqual(pending.nutrition, .zero)
        XCTAssertEqual(diary.nutrition(on: .mockToday).calories, 180, accuracy: 0.001)
    }

    func testDuplicateFoodNamesRequireClarificationBeforeLanguageCorrection() throws {
        var meal = try MealEntry.confirmed(date: .mockToday, mealType: .lunch, items: [
            .recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1), note: "照片左侧"),
            .recognized(name: "米饭", amount: 1, unit: "份", grams: 160, nutrition: Nutrition(calories: 180, protein: 4, carbs: 40, fat: 1), note: "照片右侧")
        ])

        let result = meal.applyLanguageCorrection("米饭吃了一半")

        XCTAssertEqual(
            result,
            .needsClarification(
                PendingFoodCorrection(
                    foodName: "米饭",
                    candidates: [
                        FoodCorrectionCandidate(id: meal.items[0].id, label: "照片左侧"),
                        FoodCorrectionCandidate(id: meal.items[1].id, label: "照片右侧")
                    ],
                    action: .ratio(0.5),
                    originalText: "米饭吃了一半"
                )
            )
        )
        XCTAssertEqual(meal.nutrition.calories, 380, accuracy: 0.001)

        try meal.applyClarifiedCorrection(result.pendingCorrection!, selectedFoodID: meal.items[1].id)

        XCTAssertEqual(meal.items[0].actualNutrition.calories, 200, accuracy: 0.001)
        XCTAssertEqual(meal.items[1].actualNutrition.calories, 90, accuracy: 0.001)
        XCTAssertEqual(meal.nutrition.calories, 290, accuracy: 0.001)
    }

    func testLanguageCorrectionAppliesMultipleExplicitFoodItemsAndLeavesUnmentionedItems() throws {
        var meal = try MealEntry.confirmed(date: .mockToday, mealType: .lunch, items: [
            .recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10)),
            .recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1)),
            .recognized(name: "拿铁", amount: 1, unit: "杯", grams: 300, nutrition: Nutrition(calories: 180, protein: 9, carbs: 18, fat: 7))
        ])

        let result = meal.applyLanguageCorrection("鸡蛋吃了一个，米饭全部吃完")

        XCTAssertEqual(result, .applied(foodNames: ["鸡蛋", "米饭"]))
        XCTAssertEqual(meal.items[0].actualNutrition.calories, 70, accuracy: 0.001)
        XCTAssertEqual(meal.items[1].actualNutrition.calories, 200, accuracy: 0.001)
        XCTAssertEqual(meal.items[2].actualNutrition.calories, 180, accuracy: 0.001)
        XCTAssertEqual(meal.nutrition.calories, 450, accuracy: 0.001)
    }

    func testLanguageCorrectionRenamesMisidentifiedFoodToCorn() throws {
        var meal = try MealEntry.confirmed(date: .mockToday, mealType: .dinner, items: [
            .recognized(name: "馒头", amount: 1, unit: "个", grams: 100, nutrition: Nutrition(calories: 235, protein: 7, carbs: 48, fat: 1), confidence: "一般")
        ])

        let result = meal.applyLanguageCorrection("把馒头改成玉米")

        XCTAssertEqual(result, .applied(foodNames: ["玉米"]))
        XCTAssertEqual(meal.items[0].name, "玉米")
        XCTAssertEqual(meal.items[0].recognizedQuantity.displayText, "1 根，中等")
        XCTAssertEqual(meal.items[0].actualNutrition.calories, 165, accuracy: 0.001)
        XCTAssertEqual(meal.items[0].confidence, "需确认")
        XCTAssertTrue(meal.items[0].note?.contains("营养按常见份量估算") == true)
    }

    func testLanguageCorrectionRenamesSingleItemWhenUserSaysThisActuallyIs() throws {
        var meal = try MealEntry.confirmed(date: .mockToday, mealType: .dinner, items: [
            .recognized(name: "原麦山丘面包", amount: 1, unit: "个", grams: 120, nutrition: Nutrition(calories: 320, protein: 10, carbs: 58, fat: 5), confidence: "一般")
        ])

        let result = meal.applyLanguageCorrection("这个其实是玉米")

        XCTAssertEqual(result, .applied(foodNames: ["玉米"]))
        XCTAssertEqual(meal.items[0].name, "玉米")
        XCTAssertEqual(meal.items[0].recognizedQuantity.unit, "根")
        XCTAssertEqual(meal.items[0].actualNutrition.calories, 165, accuracy: 0.001)
    }

    func testSingleFoodSupportsRatioAndCustomQuantityWithoutChangingOtherItems() throws {
        var meal = try MealEntry.confirmed(date: .mockToday, mealType: .lunch, items: [
            .recognized(name: "宫保鸡丁", amount: 1, unit: "份", grams: 260, nutrition: Nutrition(calories: 420, protein: 28, carbs: 24, fat: 24)),
            .recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1))
        ])

        try meal.setActualRatio(for: meal.items[0].id, ratio: 0.5, source: .itemAdjustment)
        try meal.setCustomActualQuantity(for: meal.items[1].id, amount: 120, unit: "克", grams: 120, source: .itemAdjustment)

        XCTAssertEqual(meal.items[0].actualNutrition.calories, 210, accuracy: 0.001)
        XCTAssertEqual(meal.items[0].actualQuantity.amount, 0.5, accuracy: 0.001)
        XCTAssertEqual(meal.items[1].actualNutrition.calories, 133.333, accuracy: 0.01)
        XCTAssertEqual(meal.items[1].actualQuantity.displayText, "120 克")
        XCTAssertEqual(meal.nutrition.calories, 343.333, accuracy: 0.01)
    }

    func testMealWideOverwriteAndOverRecognizedAmountRequireExplicitConfirmation() throws {
        var meal = try MealEntry.confirmed(date: .mockToday, mealType: .dinner, items: [
            .recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10)),
            .recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1))
        ])

        try meal.setActualAmount(for: meal.items[0].id, amount: 1, source: .itemAdjustment)
        let caloriesBeforeOverwrite = meal.nutrition.calories
        let overwriteResult = meal.applyMealWideRatio(0.5)

        XCTAssertEqual(overwriteResult, .requiresConfirmation(message: "整餐比例会覆盖当前各食物项的实际摄入调整。"))
        XCTAssertEqual(meal.nutrition.calories, caloriesBeforeOverwrite, accuracy: 0.001)

        XCTAssertEqual(meal.applyMealWideRatio(0.5, confirmedOverwrite: true), .applied)
        XCTAssertEqual(meal.nutrition.calories, 170, accuracy: 0.001)

        try meal.setActualAmount(for: meal.items[0].id, amount: 3, source: .itemAdjustment)
        XCTAssertTrue(meal.hasUnconfirmedOverRecognizedAmount)

        try meal.confirmOverRecognizedAmount(for: meal.items[0].id)
        XCTAssertFalse(meal.hasUnconfirmedOverRecognizedAmount)
    }

    func testMealScheduleSupportsHistoricalEntryAndBlocksFutureDate() throws {
        var meal = try MealEntry.confirmed(date: .mockToday, mealType: .lunch, items: [
            .recognized(name: "拿铁", amount: 1, unit: "杯", grams: 300, nutrition: Nutrition(calories: 180, protein: 9, carbs: 18, fat: 7))
        ])

        try meal.updateSchedule(date: .mockToday.addingTimeInterval(-86400), mealType: .snack, now: .mockToday)

        XCTAssertEqual(meal.mealType, .snack)
        XCTAssertTrue(Calendar(identifier: .gregorian).isDate(meal.date, inSameDayAs: .mockToday.addingTimeInterval(-86400)))
        XCTAssertThrowsError(try meal.updateSchedule(date: .mockToday.addingTimeInterval(3600), mealType: .dinner, now: .mockToday)) { error in
            XCTAssertEqual(error as? MealEntryError, .futureDateNotAllowed)
        }
    }

    func testMealTypeInferenceUsesRecordTime() {
        XCTAssertEqual(MealType.inferred(from: .mockTodayAt(hour: 8, minute: 0)), .breakfast)
        XCTAssertEqual(MealType.inferred(from: .mockTodayAt(hour: 12, minute: 0)), .lunch)
        XCTAssertEqual(MealType.inferred(from: .mockTodayAt(hour: 19, minute: 0)), .dinner)
        XCTAssertEqual(MealType.inferred(from: .mockTodayAt(hour: 23, minute: 30)), .snack)
    }

    @MainActor
    func testDraftMealTypeFollowsTimeUntilUserOverrides() throws {
        let item = FoodItem.recognized(name: "香蕉", amount: 1, unit: "根", grams: 120, nutrition: Nutrition(calories: 105, protein: 1, carbs: 27, fat: 0))
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday)
        store.draftEntry = try MealEntry.confirmed(date: .mockTodayAt(hour: 8, minute: 0), mealType: .breakfast, items: [item])
        store.draftMealTypeWasManuallyChanged = false

        store.updateDraftDate(.mockTodayAt(hour: 23, minute: 30))

        XCTAssertEqual(store.draftEntry?.mealType, .snack)

        store.updateDraftMealType(.dinner)
        store.updateDraftDate(.mockTodayAt(hour: 8, minute: 0))

        XCTAssertEqual(store.draftEntry?.mealType, .dinner)
    }

    @MainActor
    func testStoreBlocksSavingOverRecognizedDraftUntilExplicitlyConfirmed() throws {
        let item = FoodItem.recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10))
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday)
        store.draftEntry = try MealEntry.confirmed(date: .mockToday, mealType: .breakfast, items: [item])

        store.setDraftItemAmount(foodID: item.id, amount: 3)
        store.saveDraftEntry()

        XCTAssertEqual(store.diary.entries.count, 0)
        XCTAssertEqual(store.activeModal, .actualIntake)

        store.confirmDraftOverRecognizedAmount(foodID: item.id)
        store.saveDraftEntry()

        XCTAssertEqual(store.diary.entries.count, 1)
    }

    func testMockAnalysisServiceReturnsPredictableMockOnlyResultsAndPendingNetworkState() async throws {
        let service = MockAnalysisService()

        let analyzed = await service.analyze(.photo(description: "宫保鸡丁盖饭"))
        let failed = await service.analyze(.photo(description: "网络失败"))

        XCTAssertEqual(analyzed.status, .confirmed)
        XCTAssertEqual(analyzed.isMockOnly, true)
        XCTAssertEqual(analyzed.items.map(\.name), ["宫保鸡丁", "米饭"])
        XCTAssertEqual(failed.status, .pendingAnalysis(reason: "当前网络不可用"))
        XCTAssertEqual(failed.nutrition, .zero)
    }

    @MainActor
    func testRealTextFailureDoesNotCreateUnrelatedMockMeal() async throws {
        let proxyClient = AIProxyClient(baseURL: URL(string: "http://127.0.0.1:1")!, timeout: 0.1)
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, proxyClient: proxyClient)

        store.startRealTextAnalysis("晚上吃了香蕉一个")

        XCTAssertTrue(store.isTextAnalysisInProgress)

        let deadline = Date().addingTimeInterval(3)
        while store.activeModal != .errorState && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(store.textRecordDraft, "晚上吃了香蕉一个")
        XCTAssertFalse(store.isTextAnalysisInProgress)
        XCTAssertEqual(store.activeModal, .errorState)
        XCTAssertEqual(store.mockErrorState, .realTextFailed)
        XCTAssertNil(store.draftEntry)
        XCTAssertFalse(store.aiStatusMessage.contains("已使用 mock 兜底"))
        XCTAssertFalse(store.aiStatusMessage.contains("宫保鸡丁"))
    }

    @MainActor
    func testRealPhotoAnalysisShowsProgressAndBlocksDuplicateSubmission() async throws {
        let proxyClient = AIProxyClient(baseURL: URL(string: "http://127.0.0.1:1")!, timeout: 0.1)
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, proxyClient: proxyClient)
        let imageData = Data([0x01, 0x02, 0x03])

        store.startRealPhotoAnalysis(imageData: imageData)

        XCTAssertEqual(store.activeModal, .photoAnalysisProgress)
        XCTAssertTrue(store.isPhotoAnalysisInProgress)

        store.startRealPhotoAnalysis(imageData: imageData)

        XCTAssertEqual(store.toast, "图片正在分析中，请稍候。")
        XCTAssertEqual(store.activeModal, .photoAnalysisProgress)
    }

    @MainActor
    func testRealPhotoSuccessUsesSelectedRecordDateInsteadOfProviderDate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhotoSuccessURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let proxyClient = AIProxyClient(baseURL: URL(string: "http://heatcal.test")!, timeout: 1, session: session)
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, proxyClient: proxyClient)

        store.startRealPhotoAnalysis(imageData: Data([0x01, 0x02, 0x03]), mimeType: "image/jpeg", description: "测试照片")

        let deadline = Date().addingTimeInterval(3)
        while store.activeModal != .analysisConfirmation && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let draft = try XCTUnwrap(store.draftEntry)
        XCTAssertEqual(store.activeModal, .analysisConfirmation)
        XCTAssertTrue(Calendar.current.isDate(draft.date, inSameDayAs: .mockToday))
        XCTAssertNotEqual(Calendar.current.component(.year, from: draft.date), 2035)
    }

    func testAIProxyClientDecodesRealMealResponseAsNonMockEntry() throws {
        let data = """
        {
          "ok": true,
          "mode": "real",
          "source": "deepseek",
          "model": "deepseek-v4-flash",
          "meal": {
            "date": "2026-06-19T12:20:00+08:00",
            "meal_type": "lunch",
            "source_description": "真实 AI 文字补记",
            "confidence": "一般",
            "estimated_range": {"lower": 520, "upper": 760},
            "items": [
              {
                "name": "宫保鸡丁",
                "quantity": {"amount": 1, "unit": "份", "grams": 260, "size": "中份"},
                "nutrition": {"calories": 420, "protein": 28, "carbs": 24, "fat": 24},
                "confidence": "一般",
                "note": "真实 AI 估算"
              }
            ]
          },
          "warnings": []
        }
        """.data(using: .utf8)!

        let entry = try AIProxyClient.mealEntry(from: data)

        XCTAssertEqual(entry.isMockOnly, false)
        XCTAssertEqual(entry.mealType, .lunch)
        XCTAssertEqual(entry.sourceDescription, "真实 AI 文字补记")
        XCTAssertEqual(entry.items[0].name, "宫保鸡丁")
        XCTAssertEqual(entry.items[0].recognizedQuantity.size, "中份")
        XCTAssertEqual(entry.nutrition.calories, 420, accuracy: 0.001)
    }

    func testAIProxyClientDecodesRecoverableErrorWithoutLeakingSecrets() throws {
        let data = """
        {
          "ok": false,
          "mode": "error",
          "error": {
            "code": "missing_key",
            "message": "deepseek API key is not configured.",
            "recoverable": true,
            "fallback_allowed": true,
            "provider": "deepseek"
          }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try AIProxyClient.mealEntry(from: data)) { error in
            let proxyError = error as? AIProxyClient.ProxyError
            XCTAssertEqual(proxyError?.code, "missing_key")
            XCTAssertEqual(proxyError?.fallbackAllowed, true)
            XCTAssertFalse(String(describing: error).contains("s" + "k-"))
        }
    }

    func testAIProxyClientHealthCheckDecodesProviderStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let proxyClient = AIProxyClient(baseURL: URL(string: "http://heatcal.test")!, timeout: 1, session: session)

        let status = try await proxyClient.checkHealth()

        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.service, "HeatCalAIProxy")
        XCTAssertEqual(status.providers["dashscope"]?.configured, true)
        XCTAssertEqual(status.providers["deepseek"]?.configured, true)
    }

    func testAIProxyClientDecodesCorrectionSnakeCaseResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CorrectionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let proxyClient = AIProxyClient(baseURL: URL(string: "http://heatcal.test")!, timeout: 1, session: session)
        let item = FoodItem.recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10))

        let response = try await proxyClient.parseCorrection(text: "鸡蛋吃了一半", items: [item])

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.source, "deepseek")
        XCTAssertEqual(response.correction.needsClarification, false)
        XCTAssertEqual(response.correction.corrections.first?.foodName, "鸡蛋")
        XCTAssertEqual(response.correction.corrections.first?.ratio, 0.5)
    }

    @MainActor
    func testDraftCorrectionRenamesCurrentDraftFoodItem() throws {
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday)
        store.draftEntry = try MealEntry.confirmed(date: .mockToday, mealType: .dinner, items: [
            .recognized(name: "馒头", amount: 1, unit: "个", grams: 100, nutrition: Nutrition(calories: 235, protein: 7, carbs: 48, fat: 1))
        ])

        store.applyRealDraftLanguageCorrection("把馒头改成玉米")

        XCTAssertEqual(store.draftEntry?.items.first?.name, "玉米")
        XCTAssertEqual(store.draftEntry?.items.first?.recognizedQuantity.displayText, "1 根，中等")
        XCTAssertEqual(store.draftEntry?.items.first?.actualNutrition.calories ?? 0, 165, accuracy: 0.001)
        XCTAssertEqual(store.correctionMessage, "已修正为 玉米；营养估算请保存前确认。")
    }

    @MainActor
    func testDraftCorrectionAppliesProxyRatioToCurrentDraft() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CorrectionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let proxyClient = AIProxyClient(baseURL: URL(string: "http://heatcal.test")!, timeout: 1, session: session)
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, proxyClient: proxyClient)
        store.draftEntry = try MealEntry.confirmed(date: .mockToday, mealType: .breakfast, items: [
            .recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10))
        ])

        store.applyRealDraftLanguageCorrection("鸡蛋吃了一半")

        let deadline = Date().addingTimeInterval(3)
        while store.isDraftCorrectionInProgress && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(store.isDraftCorrectionInProgress)
        XCTAssertEqual(store.draftEntry?.items.first?.name, "鸡蛋")
        XCTAssertEqual(store.draftEntry?.items.first?.actualQuantity.amount ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(store.draftEntry?.items.first?.actualNutrition.calories ?? 0, 70, accuracy: 0.001)
        XCTAssertEqual(store.correctionMessage, "真实 AI 已应用到 鸡蛋，保存前仍可修改。")
    }

    @MainActor
    func testProxyBaseURLSavePersistsAndReloadsWithoutDefaultOverwrite() throws {
        let customURL = "http://192.168.1.138:8787"
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday)

        store.resetProxyBaseURLToSimulatorDefault()
        store.applyProxyBaseURL(customURL)

        XCTAssertEqual(store.proxyBaseURLString, customURL)
        XCTAssertFalse(store.proxyBaseURLString.contains("127.0.0.1"))

        let reloadedStore = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday)
        XCTAssertEqual(reloadedStore.proxyBaseURLString, customURL)

        reloadedStore.resetProxyBaseURLToSimulatorDefault()
    }

    @MainActor
    func testLegacyLocalProxyDefaultMigratesToCloudDefault() throws {
        let persistence = try makeTemporaryPersistence()
        let snapshot = LocalAppPersistence.Snapshot(
            schemaVersion: LocalAppPersistence.currentSchemaVersion,
            diary: DailyDiary(entries: [], weights: []),
            nutritionTarget: AppStore.defaultNutritionTarget,
            targetWeight: AppStore.defaultTargetWeight,
            defaultMode: "快速模式",
            proxyBaseURLString: "http://127.0.0.1:8787"
        )
        try persistence.save(snapshot)

        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, persistence: persistence)

        XCTAssertEqual(store.proxyBaseURLString, AppStore.defaultProxyBaseURLString)
    }

    @MainActor
    func testLocalPersistenceRestoresSavedMealAndEditedDraftFields() throws {
        let persistence = try makeTemporaryPersistence()
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, persistence: persistence, loadPersistedData: false)
        store.draftEntry = try MealEntry.confirmed(date: .mockTodayAt(hour: 19, minute: 0), mealType: .dinner, items: [
            .recognized(name: "馒头", amount: 1, unit: "个", grams: 100, nutrition: Nutrition(calories: 235, protein: 7, carbs: 48, fat: 1))
        ], isMockOnly: false)

        store.saveDraftEntry()

        var reloadedStore = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, persistence: persistence)
        var savedEntry = try XCTUnwrap(reloadedStore.selectedEntries.first)
        XCTAssertEqual(savedEntry.isMockOnly, false)
        XCTAssertEqual(savedEntry.mealType, .dinner)
        XCTAssertEqual(savedEntry.items.first?.name, "馒头")

        reloadedStore.editEntry(savedEntry)
        reloadedStore.applyDraftLanguageCorrection("把馒头改成玉米")
        reloadedStore.updateDraftDate(.mockTodayAt(hour: 23, minute: 30))
        reloadedStore.saveDraftEntry()

        reloadedStore = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, persistence: persistence)
        savedEntry = try XCTUnwrap(reloadedStore.selectedEntries.first)
        XCTAssertEqual(savedEntry.items.first?.name, "玉米")
        XCTAssertEqual(savedEntry.mealType, .snack)
        XCTAssertEqual(savedEntry.items.first?.actualNutrition.calories ?? 0, 165, accuracy: 0.001)
        XCTAssertEqual(reloadedStore.todayNutrition.calories, 165, accuracy: 0.001)
    }

    @MainActor
    func testLocalPersistenceRestoresWeightHistoryAndTargets() throws {
        let persistence = try makeTemporaryPersistence()
        let today = Date()
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: today, persistence: persistence, loadPersistedData: false)

        store.updateTargets(nutrition: Nutrition(calories: 1900, protein: 120, carbs: 210, fat: 55), targetWeight: 63.5)
        store.saveWeight(68.2, on: today)

        let reloadedStore = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: today, persistence: persistence)

        XCTAssertEqual(reloadedStore.latestWeight?.weight, 68.2)
        XCTAssertEqual(reloadedStore.todayWeight?.weight, 68.2)
        XCTAssertEqual(reloadedStore.diary.weights.count, 1)
        XCTAssertEqual(reloadedStore.dailyTarget.calories, 1900)
        XCTAssertEqual(reloadedStore.targetWeight, 63.5)
    }

    @MainActor
    func testWeightRecordCanBeSavedForSelectedPastDateAndBlocksFutureDate() throws {
        let selectedPastDate = Date().addingTimeInterval(-86400 * 3)
        let futureDate = Date().addingTimeInterval(86400)
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), persistence: nil)

        XCTAssertTrue(store.saveWeight(67.8, on: selectedPastDate))
        XCTAssertEqual(store.diary.weights.count, 1)
        XCTAssertTrue(Calendar.current.isDate(store.diary.weights[0].date, inSameDayAs: selectedPastDate))
        XCTAssertEqual(store.diary.weights[0].weight, 67.8)

        XCTAssertFalse(store.saveWeight(80.0, on: futureDate))
        XCTAssertEqual(store.diary.weights.count, 1)
        XCTAssertFalse(store.diary.weights.contains { Calendar.current.isDate($0.date, inSameDayAs: futureDate) })
        XCTAssertEqual(store.toast, "未来日期不可保存")
    }

    @MainActor
    func testLocalPersistenceDeletesSingleMealAndRecalculatesHistoricalSummary() throws {
        let persistence = try makeTemporaryPersistence()
        let historicalDate = Date.mockToday.addingTimeInterval(-86400)
        let breakfast = try MealEntry.confirmed(date: historicalDate, mealType: .breakfast, items: [
            .recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10))
        ])
        let lunch = try MealEntry.confirmed(date: historicalDate, mealType: .lunch, items: [
            .recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1))
        ])
        let store = AppStore(diary: DailyDiary(entries: [breakfast, lunch], weights: []), selectedDate: historicalDate, persistence: persistence, loadPersistedData: false)
        store.saveLocalData()

        store.deleteEntry(breakfast)

        let reloadedStore = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: historicalDate, persistence: persistence)

        XCTAssertEqual(reloadedStore.selectedEntries.map { $0.id }, [lunch.id])
        XCTAssertEqual(reloadedStore.todayNutrition.calories, 200, accuracy: 0.001)
    }

    @MainActor
    func testClearAllLocalDataRemovesDiaryWeightsTargetsAndResettableSettings() throws {
        let persistence = try makeTemporaryPersistence()
        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, persistence: persistence, loadPersistedData: false)
        store.draftEntry = try MealEntry.confirmed(date: .mockToday, mealType: .breakfast, items: [
            .recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10))
        ])
        store.saveDraftEntry()
        store.saveWeight(68.2, on: .mockToday)
        store.updateTargets(nutrition: Nutrition(calories: 1900, protein: 120, carbs: 210, fat: 55), targetWeight: 63.5)
        store.defaultMode = "精确模式"
        store.applyProxyBaseURL("http://192.168.1.138:8787")

        store.clearAllLocalData()

        let reloadedStore = AppStore(diary: DailyDiary(entries: [try MealEntry.confirmed(date: .mockToday, mealType: .snack, items: [])], weights: [WeightEntry(date: .mockToday, weight: 70)]), selectedDate: .mockToday, persistence: persistence)
        XCTAssertTrue(reloadedStore.diary.entries.isEmpty)
        XCTAssertTrue(reloadedStore.diary.weights.isEmpty)
        XCTAssertEqual(reloadedStore.dailyTarget, AppStore.defaultNutritionTarget)
        XCTAssertEqual(reloadedStore.targetWeight, AppStore.defaultTargetWeight)
        XCTAssertEqual(reloadedStore.defaultMode, "快速模式")
        XCTAssertEqual(reloadedStore.proxyBaseURLString, AppStore.defaultProxyBaseURLString)
    }

    @MainActor
    func testCorruptLocalDataFallsBackWithoutCrashAndCanBeCleared() throws {
        let persistence = try makeTemporaryPersistence()
        try Data("not-json".utf8).write(to: persistence.fileURL)

        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, persistence: persistence)

        XCTAssertTrue(store.diary.entries.isEmpty)
        XCTAssertTrue(store.diary.weights.isEmpty)
        XCTAssertTrue(store.localDataMessage?.contains("本机数据无法读取") == true)

        store.clearAllLocalData()

        XCTAssertTrue(store.diary.entries.isEmpty)
        XCTAssertTrue(store.diary.weights.isEmpty)
        XCTAssertTrue(store.localDataMessage?.contains("已清空") == true)
    }

    @MainActor
    func testUnsupportedLocalDataVersionFallsBackWithoutUsingStaleContent() throws {
        let persistence = try makeTemporaryPersistence()
        let unsupportedSnapshot = LocalAppPersistence.Snapshot(
            schemaVersion: 999,
            diary: DailyDiary(entries: [
                try MealEntry.confirmed(date: .mockToday, mealType: .breakfast, items: [
                    .recognized(name: "旧数据", amount: 1, unit: "份", grams: 100, nutrition: Nutrition(calories: 999, protein: 0, carbs: 0, fat: 0))
                ])
            ], weights: [WeightEntry(date: .mockToday, weight: 99)]),
            nutritionTarget: Nutrition(calories: 999, protein: 1, carbs: 1, fat: 1),
            targetWeight: 99,
            defaultMode: "精确模式",
            proxyBaseURLString: "http://192.168.1.138:8787"
        )
        try JSONEncoder().encode(unsupportedSnapshot).write(to: persistence.fileURL)

        let store = AppStore(diary: DailyDiary(entries: [], weights: []), selectedDate: .mockToday, persistence: persistence)

        XCTAssertTrue(store.diary.entries.isEmpty)
        XCTAssertTrue(store.diary.weights.isEmpty)
        XCTAssertEqual(store.dailyTarget, AppStore.defaultNutritionTarget)
        XCTAssertEqual(store.targetWeight, AppStore.defaultTargetWeight)
        XCTAssertEqual(store.defaultMode, "快速模式")
        XCTAssertEqual(store.proxyBaseURLString, AppStore.defaultProxyBaseURLString)
        XCTAssertTrue(store.localDataMessage?.contains("本机数据无法读取") == true)
    }

    func testRecentRepeatCandidatesDeduplicateRealMealsAndExcludeMockEntries() throws {
        let olderDate = Date.mockToday.addingTimeInterval(-86400 * 5)
        let newerDate = Date.mockToday.addingTimeInterval(-86400)
        let olderBreakfast = try MealEntry.confirmed(
            date: olderDate,
            mealType: .breakfast,
            items: [.recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10))],
            isMockOnly: false
        )
        let newerBreakfast = try MealEntry.confirmed(
            date: newerDate,
            mealType: .breakfast,
            items: [.recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10))],
            isMockOnly: false
        )
        let mockLunch = try MealEntry.confirmed(
            date: Date.mockToday,
            mealType: .lunch,
            items: [.recognized(name: "宫保鸡丁", amount: 1, unit: "份", grams: 260, nutrition: Nutrition(calories: 420, protein: 28, carbs: 24, fat: 24))]
        )

        let candidates = DailyDiary(entries: [olderBreakfast, mockLunch, newerBreakfast], weights: []).recentRepeatCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].entry.id, newerBreakfast.id)
        XCTAssertEqual(candidates[0].timesRecorded, 2)
        XCTAssertEqual(candidates[0].entry.items.map(\.name), ["鸡蛋"])
    }

    @MainActor
    func testStartRepeatEntryCreatesNewEditableDraftForSelectedDate() throws {
        let original = try MealEntry.confirmed(
            date: Date.mockToday.addingTimeInterval(-86400 * 2),
            mealType: .dinner,
            items: [.recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10))],
            sourceDescription: "真实 AI 图片分析",
            isMockOnly: false
        )
        let selectedDate = Date.mockTodayAt(hour: 8, minute: 30)
        let store = AppStore(diary: DailyDiary(entries: [original], weights: []), selectedDate: selectedDate, persistence: nil)

        store.startRepeatEntry(original, now: selectedDate)

        XCTAssertEqual(store.activeModal, .analysisConfirmation)
        XCTAssertNotEqual(store.draftEntry?.id, original.id)
        XCTAssertNotEqual(store.draftEntry?.items.first?.id, original.items.first?.id)
        XCTAssertEqual(store.draftEntry?.items.first?.name, "鸡蛋")
        XCTAssertEqual(store.draftEntry?.mealType, .breakfast)
        XCTAssertTrue(Calendar.current.isDate(store.draftEntry!.date, inSameDayAs: selectedDate))
        XCTAssertEqual(store.draftEntry?.sourceDescription, "复记：鸡蛋")
    }
}

private func makeTemporaryPersistence() throws -> LocalAppPersistence {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HeatCalMockAppTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return LocalAppPersistence(fileURL: directory.appendingPathComponent("LocalData.json"))
}

private extension LanguageCorrectionResult {
    var pendingCorrection: PendingFoodCorrection? {
        if case .needsClarification(let correction) = self {
            return correction
        }
        return nil
    }
}

private extension Date {
    static let mockToday = Date(timeIntervalSince1970: 1_781_702_400)

    static func mockTodayAt(hour: Int, minute: Int) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.dateComponents([.year, .month, .day], from: mockToday)
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
    }
}

private final class PhotoSuccessURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let data = """
        {
          "ok": true,
          "mode": "real",
          "source": "dashscope",
          "model": "qwen3.6-flash",
          "meal": {
            "date": "2035-01-02T08:00:00+08:00",
            "meal_type": "breakfast",
            "source_description": "真实 AI 图片分析",
            "confidence": "一般",
            "estimated_range": {"lower": 80, "upper": 120},
            "items": [
              {
                "name": "香蕉",
                "quantity": {"amount": 1, "unit": "根", "grams": 120, "size": "中等"},
                "nutrition": {"calories": 105, "protein": 1, "carbs": 27, "fat": 0},
                "confidence": "一般",
                "note": "测试桩"
              }
            ]
          },
          "warnings": []
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class HealthURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let data = """
        {
          "ok": true,
          "service": "HeatCalAIProxy",
          "mode": "real",
          "providers": {
            "dashscope": {"configured": true, "model": "qwen3.6-flash", "role": "vision"},
            "deepseek": {"configured": true, "model": "deepseek-v4-flash", "role": "text"}
          }
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CorrectionURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let data = """
        {
          "ok": true,
          "mode": "real",
          "source": "deepseek",
          "correction": {
            "corrections": [
              {
                "food_name": "鸡蛋",
                "match": "exact",
                "amount": null,
                "ratio": 0.5,
                "unit": null,
                "note": "用户说吃了一半"
              }
            ],
            "needs_clarification": false
          }
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
