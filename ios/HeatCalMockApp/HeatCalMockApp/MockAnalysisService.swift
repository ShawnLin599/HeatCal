import Foundation

enum MockAnalysisRequest: Equatable {
    case photo(description: String)
    case text(String)
    case correction(String)
    case nutritionLabel(String)
}

struct MockAnalysisService {
    func analyze(_ request: MockAnalysisRequest) async -> MealEntry {
        switch request {
        case .photo(let description), .text(let description), .correction(let description), .nutritionLabel(let description):
            if description.contains("网络失败") || description.contains("离线") {
                return MealEntry.pending(date: Date(), mealType: .lunch, description: description, reason: "当前网络不可用")
            }

            if description.contains("鸡蛋") {
                return try! MealEntry.confirmed(
                    date: Date(),
                    mealType: .breakfast,
                    items: [
                        .recognized(name: "鸡蛋", amount: 2, unit: "个", grams: 100, nutrition: Nutrition(calories: 140, protein: 12, carbs: 1, fat: 10), confidence: "较高"),
                        .recognized(name: "拿铁", amount: 1, unit: "杯", grams: 300, nutrition: Nutrition(calories: 180, protein: 9, carbs: 18, fat: 7), confidence: "一般")
                    ],
                    sourceDescription: description,
                    confidence: "较高",
                    estimatedRange: 290...360
                )
            }

            if description.contains("营养成分表") || description.contains("包装") {
                return try! MealEntry.confirmed(
                    date: Date(),
                    mealType: .snack,
                    items: [
                        .recognized(name: "瓶装酸奶", amount: 1, unit: "瓶", grams: 250, nutrition: Nutrition(calories: 210, protein: 8, carbs: 28, fat: 7), confidence: "较高", note: "营养成分表 mock")
                    ],
                    sourceDescription: description,
                    confidence: "较高",
                    estimatedRange: 200...220
                )
            }

            return try! MealEntry.confirmed(
                date: Date(),
                mealType: .lunch,
                items: [
                    .recognized(name: "宫保鸡丁", amount: 1, unit: "份", grams: 260, nutrition: Nutrition(calories: 420, protein: 28, carbs: 24, fat: 24), confidence: "一般", note: "照片上方"),
                    .recognized(name: "米饭", amount: 1, unit: "碗", grams: 180, nutrition: Nutrition(calories: 200, protein: 4, carbs: 45, fat: 1), confidence: "一般", note: "照片下方")
                ],
                sourceDescription: description,
                confidence: "一般",
                estimatedRange: 520...760
            )
        }
    }
}

struct AIProxyClient {
    struct ProxyError: Error, Equatable, CustomStringConvertible {
        let code: String
        let message: String
        let recoverable: Bool
        let fallbackAllowed: Bool
        let provider: String

        var description: String {
            "\(provider): \(code) - \(message)"
        }
    }

    struct CorrectionResponse: Decodable, Equatable {
        struct CorrectionPayload: Decodable, Equatable {
            let corrections: [Correction]
            let needsClarification: Bool

            enum CodingKeys: String, CodingKey {
                case corrections
                case needsClarification = "needs_clarification"
            }
        }

        struct Correction: Decodable, Equatable {
            let foodName: String
            let match: String
            let amount: Double?
            let ratio: Double?
            let unit: String?
            let note: String?

            enum CodingKeys: String, CodingKey {
                case foodName = "food_name"
                case match
                case amount
                case ratio
                case unit
                case note
            }
        }

        let ok: Bool
        let source: String
        let correction: CorrectionPayload
    }

    var baseURL: URL = URL(string: "http://127.0.0.1:8787")!
    var timeout: TimeInterval = 120
    var session: URLSession = .shared

    func checkHealth() async throws -> ProxyStatus {
        let data = try await get(path: "/health")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ProxyStatus.self, from: data)
    }

    func analyzeText(_ text: String) async throws -> MealEntry {
        try await postMeal(path: "/v1/analyze/text", body: ["text": text])
    }

    func analyzePhoto(imageData: Data, mimeType: String, description: String) async throws -> MealEntry {
        try await postMeal(
            path: "/v1/analyze/photo",
            body: [
                "image_base64": imageData.base64EncodedString(),
                "image_mime_type": mimeType,
                "description": description
            ]
        )
    }

    func parseCorrection(text: String, items: [FoodItem]) async throws -> CorrectionResponse {
        let payloadItems = items.map { item in
            [
                "id": item.id.uuidString,
                "name": item.name,
                "amount": item.actualQuantity.amount,
                "unit": item.actualQuantity.unit,
                "grams": item.actualQuantity.grams,
                "note": item.note ?? ""
            ] as [String: Any]
        }
        let data = try await post(path: "/v1/corrections/parse", body: ["text": text, "items": payloadItems])
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(CorrectionResponse.self, from: data)
        } catch {
            throw try Self.proxyError(from: data) ?? error
        }
    }

    private func postMeal(path: String, body: [String: Any]) async throws -> MealEntry {
        let data = try await post(path: path, body: body)
        return try Self.mealEntry(from: data)
    }

    private func get(path: String) async throws -> Data {
        let endpoint = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = min(timeout, 10)
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw ProxyError(code: "http_error", message: "AI proxy returned HTTP \(httpResponse.statusCode).", recoverable: true, fallbackAllowed: true, provider: "proxy")
        }
        return data
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        let endpoint = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw try Self.proxyError(from: data) ?? ProxyError(code: "http_error", message: "AI proxy returned HTTP \(httpResponse.statusCode).", recoverable: true, fallbackAllowed: true, provider: "proxy")
        }
        return data
    }

    static func mealEntry(from data: Data) throws -> MealEntry {
        if let proxyError = try proxyError(from: data) {
            throw proxyError
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(MealEnvelope.self, from: data)
        guard envelope.ok, let meal = envelope.meal else {
            throw ProxyError(code: "invalid_response", message: "AI proxy response is missing meal.", recoverable: true, fallbackAllowed: true, provider: envelope.source ?? "proxy")
        }
        return try meal.toMealEntry(isMockOnly: false)
    }

    private static func proxyError(from data: Data) throws -> ProxyError? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
        guard let error = envelope?.error else {
            return nil
        }
        return ProxyError(
            code: error.code,
            message: error.message,
            recoverable: error.recoverable,
            fallbackAllowed: error.fallbackAllowed,
            provider: error.provider
        )
    }
}

struct ProxyStatus: Decodable, Equatable {
    struct Provider: Decodable, Equatable {
        let configured: Bool
        let model: String?
        let role: String
    }

    let ok: Bool
    let service: String
    let mode: String
    let providers: [String: Provider]
}

private struct MealEnvelope: Decodable {
    let ok: Bool
    let source: String?
    let model: String?
    let meal: ProxyMeal?
    let warnings: [String]?
}

private struct ErrorEnvelope: Decodable {
    let ok: Bool
    let error: ProxyErrorPayload?
}

private struct ProxyErrorPayload: Decodable {
    let code: String
    let message: String
    let recoverable: Bool
    let fallbackAllowed: Bool
    let provider: String
}

private struct ProxyMeal: Decodable {
    let date: String
    let mealType: MealType
    let sourceDescription: String
    let confidence: String
    let estimatedRange: ProxyRange
    let items: [ProxyFoodItem]

    func toMealEntry(isMockOnly: Bool) throws -> MealEntry {
        let parsedDate = Date.heatCalISO8601(from: date) ?? Date()
        return try MealEntry.confirmed(
            date: parsedDate,
            mealType: mealType,
            items: items.map(\.foodItem),
            sourceDescription: sourceDescription,
            confidence: confidence,
            estimatedRange: estimatedRange.lower...estimatedRange.upper,
            isMockOnly: isMockOnly
        )
    }
}

private struct ProxyRange: Decodable {
    let lower: Double
    let upper: Double
}

private struct ProxyFoodItem: Decodable {
    let name: String
    let quantity: ProxyQuantity
    let nutrition: Nutrition
    let confidence: String
    let note: String?

    var foodItem: FoodItem {
        .recognized(
            name: name,
            amount: quantity.amount,
            unit: quantity.unit,
            grams: quantity.grams,
            nutrition: nutrition,
            size: quantity.size,
            confidence: confidence,
            note: note
        )
    }
}

private struct ProxyQuantity: Decodable {
    let amount: Double
    let unit: String
    let grams: Double
    let size: String?
}

private extension Date {
    static func heatCalISO8601(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
