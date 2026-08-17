import SwiftUI
import PhotosUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch store.selectedTab {
                case .today:
                    NavigationStack {
                        TodayView()
                    }
                case .trend:
                    NavigationStack {
                        TrendView()
                    }
                }
            }
            RecordDock()
        }
        .background(Color.cream.ignoresSafeArea())
        .sheet(item: $store.activeModal) { modal in
            switch modal {
            case .recordMenu:
                RecordMenuView()
                    .presentationDetents([.height(380)])
            case .analysisConfirmation:
                RecordDraftFlowView(initialPage: .confirmation)
            case .actualIntake:
                RecordDraftFlowView(initialPage: .actualIntake)
            case .pendingRecovery:
                PendingRecoveryView()
            case .errorState:
                MockErrorStateView()
            case .textRecordInput:
                TextRecordInputView()
                    .presentationDetents([.medium])
            case .photoAnalysisProgress:
                PhotoAnalysisProgressView()
                    .interactiveDismissDisabled()
                    .presentationDetents([.height(300)])
            case .settings:
                SettingsView()
            }
        }
        .fullScreenCover(isPresented: $store.isCameraPresented) {
            CameraCaptureView { imageData in
                store.startRealPhotoAnalysis(imageData: imageData, mimeType: "image/jpeg", description: "拍照饮食照片")
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.mintText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.mint)
                    .clipShape(Capsule())
                    .padding(.top, 12)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        store.toast = nil
                    }
            }
        }
    }
}

struct RecordDraftFlowView: View {
    enum Page {
        case confirmation
        case actualIntake
    }

    @State private var page: Page

    init(initialPage: Page = .confirmation) {
        self._page = State(initialValue: initialPage)
    }

    var body: some View {
        Group {
            switch page {
            case .confirmation:
                AnalysisConfirmationView {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        page = .actualIntake
                    }
                }
            case .actualIntake:
                ActualIntakeView {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        page = .confirmation
                    }
                }
            }
        }
    }
}

struct TodayView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderView(title: "今天吃得怎么样？", subtitle: store.selectedDate.chineseDateText)

                MockOnlyBanner()

                Card {
                    ChineseDatePickerRow(title: "查看日期", selection: $store.selectedDate, range: ...Date(), components: .date)
                    Text("可切换到历史日期查看或补记；未来日期不可创建饮食记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SummaryCard(nutrition: store.todayNutrition, target: store.dailyTarget)

                ForEach(MealType.allCases) { mealType in
                    MealSectionView(mealType: mealType, entries: store.selectedEntries.filter { $0.mealType == mealType })
                }

                Spacer(minLength: 128)
            }
            .padding()
        }
        .background(Color.cream)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.activeModal = .settings
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("设置")
            }
        }
    }
}

struct HeaderView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChineseDatePickerRow: View {
    let title: String
    @Binding var selection: Date
    let range: PartialRangeThrough<Date>
    let components: DatePickerComponents
    @State private var showingPicker = false
    @State private var draftSelection = Date()

    private var displayText: String {
        components == .date ? selection.chineseDateText : selection.chineseDateTimeText
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                draftSelection = selection
                showingPicker = true
            } label: {
                Text(displayText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.cream)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .accessibilityLabel("\(title)，\(displayText)")
        }
        .sheet(isPresented: $showingPicker) {
            ChineseDatePickerSheet(
                title: title,
                selection: $draftSelection,
                range: range,
                components: components,
                onCancel: { showingPicker = false },
                onConfirm: {
                    selection = draftSelection
                    showingPicker = false
                }
            )
            .presentationDetents([.height(components == .date ? 380 : 460)])
        }
    }
}

struct ChineseDatePickerSheet: View {
    let title: String
    @Binding var selection: Date
    let range: PartialRangeThrough<Date>
    let components: DatePickerComponents
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var year: Int
    @State private var month: Int
    @State private var day: Int
    @State private var hour: Int
    @State private var minute: Int

    init(
        title: String,
        selection: Binding<Date>,
        range: PartialRangeThrough<Date>,
        components: DatePickerComponents,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self._selection = selection
        self.range = range
        self.components = components
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        let initial = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: selection.wrappedValue)
        self._year = State(initialValue: initial.year ?? Calendar.current.component(.year, from: Date()))
        self._month = State(initialValue: initial.month ?? 1)
        self._day = State(initialValue: initial.day ?? 1)
        self._hour = State(initialValue: initial.hour ?? 0)
        self._minute = State(initialValue: initial.minute ?? 0)
    }

    private var includesTime: Bool {
        components != .date
    }

    private var currentYear: Int {
        Calendar.current.component(.year, from: range.upperBound)
    }

    private var allowedYears: [Int] {
        Array(2000...currentYear)
    }

    private var daysInSelectedMonth: Int {
        let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        return Calendar.current.range(of: .day, in: .month, for: date)?.count ?? 31
    }

    private var candidateDate: Date {
        var candidate = DateComponents()
        candidate.year = year
        candidate.month = month
        candidate.day = min(day, daysInSelectedMonth)
        candidate.hour = includesTime ? hour : 0
        candidate.minute = includesTime ? minute : 0
        return min(Calendar.current.date(from: candidate) ?? selection, range.upperBound)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.ink)
                .padding(.top, 24)
            Text(includesTime ? "请选择年份、月份、日期和时间" : "请选择年份、月份和日期")
                .font(.system(size: 13))
                .foregroundStyle(Color.readableSecondary)
                .lineLimit(1)
                .padding(.top, 6)
                .padding(.bottom, 14)

            if includesTime {
                VStack(spacing: 10) {
                    dateWheelRow
                    timeWheelRow
                }
            } else {
                dateWheelRow
            }

            HStack(spacing: 14) {
                Button("取消", action: onCancel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.readableSecondary)
                    .frame(minWidth: 86, minHeight: 46)

                Button("确定") {
                    selection = candidateDate
                    onConfirm()
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .onChange(of: year) { _, _ in clampDay() }
        .onChange(of: month) { _, _ in clampDay() }
    }

    private var dateWheelRow: some View {
        HStack(spacing: 8) {
            wheelColumn(width: 100) {
                Picker("年份", selection: $year) {
                    ForEach(allowedYears, id: \.self) { value in
                        Text(verbatim: String(format: "%04d", value)).tag(value)
                    }
                }
            }
            wheelColumn(width: 74) {
                Picker("月份", selection: $month) {
                    ForEach(1...12, id: \.self) { value in
                        Text("\(value)月").tag(value)
                    }
                }
            }
            wheelColumn(width: 74) {
                Picker("日期", selection: $day) {
                    ForEach(1...daysInSelectedMonth, id: \.self) { value in
                        Text("\(value)日").tag(value)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var timeWheelRow: some View {
        HStack(spacing: 12) {
            wheelColumn(width: 84) {
                Picker("小时", selection: $hour) {
                    ForEach(0...23, id: \.self) { value in
                        Text(String(format: "%02d时", value)).tag(value)
                    }
                }
            }
            wheelColumn(width: 84) {
                Picker("分钟", selection: $minute) {
                    ForEach(0...59, id: \.self) { value in
                        Text(String(format: "%02d分", value)).tag(value)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func wheelColumn<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .pickerStyle(.wheel)
            .frame(width: width, height: includesTime ? 124 : 150)
            .clipped()
    }

    private func clampDay() {
        day = min(day, daysInSelectedMonth)
    }
}

struct MockOnlyBanner: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Label(store.aiStatusMessage, systemImage: "sparkles")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.amberText)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.amber)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SummaryCard: View {
    let nutrition: Nutrition
    let target: Nutrition

    var remainingCalories: Double {
        max(0, target.calories - nutrition.calories)
    }

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("今日剩余")
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(remainingCalories.rounded()))")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("千卡")
                            .foregroundStyle(.secondary)
                    }
                    Text("已摄入 \(Int(nutrition.calories)) / 目标 \(Int(target.calories))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ZStack {
                    Circle()
                        .stroke(Color.coral.opacity(0.15), lineWidth: 13)
                    Circle()
                        .trim(from: 0, to: min(1.2, nutrition.calories / target.calories))
                        .stroke(Color.coral, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((nutrition.calories / target.calories * 100).rounded()))%")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .frame(width: 92, height: 92)
            }

            VStack(spacing: 10) {
                MacroProgress(name: "蛋白质", value: nutrition.protein, target: target.protein, color: .protein)
                MacroProgress(name: "碳水", value: nutrition.carbs, target: target.carbs, color: .carb)
                MacroProgress(name: "脂肪", value: nutrition.fat, target: target.fat, color: .fat)
            }
            .padding(.top, 12)
        }
    }
}

struct MacroProgress: View {
    let name: String
    let value: Double
    let target: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text("\(Int(value)) / \(Int(target))g")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            ProgressView(value: min(value / target, 1))
                .tint(color)
        }
    }
}

struct MealSectionView: View {
    @EnvironmentObject private var store: AppStore
    let mealType: MealType
    let entries: [MealEntry]

    var total: Nutrition {
        entries.reduce(.zero) { $0 + $1.nutrition }
    }

    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mealType.title)
                        .font(.headline)
                    Text(entries.isEmpty ? "还没有记录" : "\(entries.count) 条记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(total.calories)) 千卡")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
            }

            if entries.isEmpty {
                Text("点击底部“记录”按钮开始记录饮食。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                VStack(spacing: 10) {
                    ForEach(entries) { entry in
                        MealEntryRow(entry: entry)
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

struct MealEntryRow: View {
    @EnvironmentObject private var store: AppStore
    let entry: MealEntry

    var body: some View {
        HStack(spacing: 12) {
            Sticker(status: entry.status)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.items.map(\.name).prefix(2).joined(separator: "、"))
                        .font(.subheadline.weight(.semibold))
                    Text(entry.isMockOnly ? "FALLBACK" : "REAL AI")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(entry.isMockOnly ? Color.coral : Color.mintText)
                        .clipShape(Capsule())
                }
                Text(entry.status == .confirmed ? "约 \(Int(entry.nutrition.calories)) 千卡 · \(entry.confidence)可信" : "待分析，不计入汇总")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.status == .confirmed {
                HStack {
                    Button("编辑") {
                        store.editEntry(entry)
                    }
                    .font(.caption.weight(.semibold))
                    Button("删除") {
                        store.deleteEntry(entry)
                    }
                    .font(.caption)
                    .foregroundStyle(Color.red)
                }
            } else {
                HStack {
                    Button("重试") {
                        store.retryPending(entry)
                    }
                    .font(.caption.weight(.semibold))
                    Button("删除") {
                        store.deleteEntry(entry)
                    }
                    .font(.caption)
                    .foregroundStyle(Color.red)
                }
            }
        }
        .padding(10)
        .background(Color.cream)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct Sticker: View {
    let status: AnalysisStatus

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(status == .confirmed ? Color.coral.opacity(0.16) : Color.amber)
            Image(systemName: status == .confirmed ? "fork.knife.circle.fill" : "clock.badge.exclamationmark")
                .foregroundStyle(status == .confirmed ? Color.coral : Color.amberText)
                .font(.title2)
        }
        .frame(width: 54, height: 54)
    }
}

struct RecordDock: View {
    @EnvironmentObject private var store: AppStore
    @Namespace private var selectionNamespace
    @State private var longPressOpenedMenu = false
    @GestureState private var isPreviewingLongPress = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    selectTab(.today)
                } label: {
                    DockTabLabel(
                        title: "今日",
                        systemImage: "calendar",
                        selected: store.selectedTab == .today,
                        namespace: selectionNamespace
                    )
                }
                .buttonStyle(DockTabButtonStyle())
                .contentShape(Capsule())
                .accessibilityLabel("今日")

                Button {
                    selectTab(.trend)
                } label: {
                    DockTabLabel(
                        title: "趋势",
                        systemImage: "chart.line.uptrend.xyaxis",
                        selected: store.selectedTab == .trend,
                        namespace: selectionNamespace
                    )
                }
                .buttonStyle(DockTabButtonStyle())
                .contentShape(Capsule())
                .accessibilityLabel("趋势")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(width: 244)
            .frame(height: 68)
            .background(Color.surface)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.black.opacity(0.06))
            }
            .shadow(color: Color.black.opacity(0.08), radius: 18, y: 8)

            VStack(spacing: 4) {
                Text("长按更多")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.coral)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.coral.opacity(0.14), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.coral.opacity(0.22))
                    }

                Button {
                    if longPressOpenedMenu {
                        longPressOpenedMenu = false
                    } else {
                        store.openCameraCapture()
                    }
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 24, weight: .bold))
                        .frame(width: 62, height: 62)
                }
                .buttonStyle(PrimaryDockButtonStyle(highlighted: isPreviewingLongPress))
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.18)
                        .updating($isPreviewingLongPress) { _, state, _ in
                            state = true
                        }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in
                            longPressOpenedMenu = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            store.openRecordMenu()
                        }
                )
                .accessibilityLabel("拍照记录饮食")
                .accessibilityHint("单击打开相机，长按查看更多记录方式")
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func selectTab(_ tab: AppTab) {
        guard store.selectedTab != tab else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeInOut(duration: 0.22)) {
            store.selectedTab = tab
        }
    }
}

struct DockTabLabel: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .scaleEffect(selected ? 1.12 : 1)
                .animation(.easeInOut(duration: 0.18), value: selected)
            Text(title)
        }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(selected ? Color.coral : Color.readableSecondary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .padding(.horizontal, 14)
            .background {
                if selected {
                    Capsule()
                        .fill(Color.coral.opacity(0.16))
                        .matchedGeometryEffect(id: "dock-tab-selection", in: namespace)
                        .overlay {
                            Capsule()
                                .stroke(Color.coral.opacity(0.10), lineWidth: 1)
                        }
                }
            }
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.22), value: selected)
    }
}

struct DockTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .background(configuration.isPressed ? Color.coral.opacity(0.08) : Color.clear)
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RecordMenuView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("记录饮食")
                    .font(.title3.bold())
                Text("默认使用拍照记录；这里也可以从相册选择照片，或用文字补记。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ButtonRow(icon: "camera.fill", title: "拍照记录", subtitle: "打开相机拍摄饮食照片并进行 AI 分析") {
                    store.openCameraCapture()
                }
                .disabled(store.isPhotoAnalysisInProgress)
                .opacity(store.isPhotoAnalysisInProgress ? 0.55 : 1)

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    PickerLikeRow(icon: "photo.on.rectangle", title: "从相册选择", subtitle: "选择已有饮食照片进行 AI 分析")
                }
                .disabled(store.isPhotoAnalysisInProgress)
                .opacity(store.isPhotoAnalysisInProgress ? 0.55 : 1)
                .onChange(of: selectedPhotoItem) { _, newItem in
                    guard let newItem else { return }
                    guard !store.isPhotoAnalysisInProgress else {
                        selectedPhotoItem = nil
                        return
                    }
                    Task {
                        if let data = try? await newItem.loadTransferable(type: Data.self) {
                            await MainActor.run {
                                store.startRealPhotoAnalysis(imageData: data, mimeType: "image/jpeg", description: "相册饮食照片")
                                selectedPhotoItem = nil
                            }
                        } else {
                            await MainActor.run {
                                store.toast = "照片读取失败，请重试或改用文字补记。"
                                selectedPhotoItem = nil
                            }
                        }
                    }
                }

                ButtonRow(icon: "text.bubble.fill", title: "文字补记", subtitle: "输入饮食描述进行 AI 分析") {
                    store.openTextRecordInput()
                }
            }
            .padding()
        }
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (Data) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss, onCapture: onCapture)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let dismiss: DismissAction
        let onCapture: (Data) -> Void

        init(dismiss: DismissAction, onCapture: @escaping (Data) -> Void) {
            self.dismiss = dismiss
            self.onCapture = onCapture
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard
                let image = info[.originalImage] as? UIImage,
                let data = image.jpegData(compressionQuality: 0.86)
            else {
                dismiss()
                return
            }
            dismiss()
            DispatchQueue.main.async {
                self.onCapture(data)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

struct PhotoAnalysisProgressView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.cream
                    .opacity(0.96)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    Text("正在分析")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .padding(.bottom, 16)
                    ProgressView()
                        .scaleEffect(1.25)
                        .padding(.bottom, 16)
                    Text("可能需要 10–30 秒，请保持应用打开。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.readableSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.bottom, 22)
                    Button("取消分析") {
                        store.cancelPhotoAnalysis()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.readableSecondary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Color.surface.opacity(0.72))
                    .clipShape(Capsule())
                }
                .frame(maxWidth: 280)
                .frame(maxWidth: .infinity)
                .padding(.top, proxy.size.height * 0.42)
            }
        }
    }
}

struct TextRecordInputView: View {
    @EnvironmentObject private var store: AppStore
    @State private var text = ""
    @State private var showsSlowAnalysisHint = false

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAnalyzing: Bool {
        store.isTextAnalysisInProgress
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("描述这餐吃了什么，AI 会帮你生成待确认记录。")
                    .font(.footnote)
                    .foregroundStyle(Color.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .padding(10)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .disabled(isAnalyzing)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("输入饮食描述")
                                .font(.body)
                                .foregroundStyle(.secondary.opacity(0.7))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                Text("分析失败时会明确标记兜底状态。")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)

                if isAnalyzing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在调用 AI 分析，通常需要几秒，请稍候。")
                        if showsSlowAnalysisHint {
                            Text("仍在分析中，网络或模型响应可能较慢。")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                }

                Button {
                    showsSlowAnalysisHint = false
                    store.startRealTextAnalysis(trimmedText)
                } label: {
                    HStack(spacing: 8) {
                        if isAnalyzing {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isAnalyzing ? "正在分析..." : "开始分析")
                    }
                }
                .disabled(trimmedText.isEmpty || isAnalyzing)
                .buttonStyle(PrimaryActionButtonStyle())
                .padding(.top, 4)

                Spacer()
            }
            .padding()
            .background(Color.cream)
            .navigationTitle("文字补记")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                text = store.textRecordDraft
            }
            .onChange(of: store.isTextAnalysisInProgress) { _, isInProgress in
                if isInProgress {
                    showsSlowAnalysisHint = false
                    Task {
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        if store.isTextAnalysisInProgress {
                            showsSlowAnalysisHint = true
                        }
                    }
                } else {
                    showsSlowAnalysisHint = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        store.activeModal = .recordMenu
                    }
                    .fontWeight(.regular)
                    .foregroundStyle(Color.readableSecondary)
                }
            }
        }
    }
}

struct ButtonRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.coral)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct PickerLikeRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.coral)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct AnalysisConfirmationView: View {
    @EnvironmentObject private var store: AppStore
    let onShowActualIntake: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                if let draft = store.draftEntry {
                    VStack(alignment: .leading, spacing: 16) {
                        MockOnlyBanner()

                        Card {
                            Text("整餐估算")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("约")
                                    .foregroundStyle(.secondary)
                                Text("\(Int(draft.nutrition.calories))")
                                    .font(.system(size: 40, weight: .bold, design: .rounded))
                                Text("千卡")
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(draft.confidence)可信 · 可能范围 \(Int(draft.estimatedRange?.lowerBound ?? draft.nutrition.calories))-\(Int(draft.estimatedRange?.upperBound ?? draft.nutrition.calories)) 千卡")
                                .font(.footnote)
                                .padding(10)
                                .background(Color.amber)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        Card {
                            Text("识别到 \(draft.items.count) 项食物")
                                .font(.headline)
                            ForEach(draft.items) { item in
                                FoodSummaryRow(item: item)
                            }
                        }

                        Card {
                            Button {
                                onShowActualIntake()
                            } label: {
                                HStack {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.title3)
                                    VStack(alignment: .leading) {
                                        Text("有剩余？进入实际摄入调整")
                                            .font(.headline)
                                        Text("默认全部计入；不进入也可直接保存")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .foregroundStyle(Color.ink)
                            }
                            Divider()
                            ChineseDatePickerRow(
                                title: "日期和时间",
                                selection: Binding(
                                    get: { store.draftEntry?.date ?? draft.date },
                                    set: { store.updateDraftDate($0) }
                                ),
                                range: ...Date(),
                                components: [.date, .hourAndMinute]
                            )
                            Text("照片记录默认使用当前/所选日期和发起记录时的时间；餐段会按记录时间自动预选，可手动修改。AI 返回日期仅作参考。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker(
                                "餐段",
                                selection: Binding(
                                    get: { store.draftEntry?.mealType ?? draft.mealType },
                                    set: { store.updateDraftMealType($0) }
                                )
                            ) {
                                ForEach(MealType.allCases) { mealType in
                                    Text(mealType.title).tag(mealType)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text("支持历史补记；未来日期会被拦截，不能保存。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if draft.hasUnconfirmedOverRecognizedAmount {
                            Card {
                                Label("有食物项超过识别份量，需在实际摄入页逐项确认后保存。", systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.amberText)
                            }
                        }
                    }
                    .padding()
                }
            }
            .background(Color.cream)
            .navigationTitle("确认这次记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") {
                        store.discardDraft()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(store.editingEntryID == nil ? "保存记录" : "保存修改") {
                    store.saveDraftEntry()
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .padding()
                .background(Color.cream)
            }
        }
    }
}

struct FoodSummaryRow: View {
    let item: FoodItem

    var body: some View {
        HStack {
            Circle()
                .fill(Color.coral.opacity(0.25))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                Text("识别 \(item.recognizedQuantity.displayText) · 实际 \(item.actualQuantity.displayText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("约 \(Int(item.actualNutrition.calories)) 千卡")
                .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 8)
    }
}

struct ActualIntakeView: View {
    @EnvironmentObject private var store: AppStore
    let onReturnToConfirmation: () -> Void
    @State private var showingCorrectionInput = false
    @State private var correctionDraft = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let draft = store.draftEntry {
                        Card {
                            Text("整餐汇总已更新")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("约")
                                Text("\(Int(draft.nutrition.calories))")
                                    .font(.system(size: 38, weight: .bold, design: .rounded))
                                Text("千卡")
                                Spacer()
                                Text("以食物项实际摄入为准")
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.mint)
                                    .clipShape(Capsule())
                            }
                        }

                        Text("先应用到草稿，确认页再保存。")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        Card {
                            DisclosureGroup {
                                HStack(spacing: 8) {
                                    RatioButton(title: "全部", ratio: 1)
                                    RatioButton(title: "1/2", ratio: 0.5)
                                    RatioButton(title: "1/4", ratio: 0.25)
                                    RatioCapsuleButton(title: "自定义", isEnabled: false) {}
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)

                                if store.mealWideConfirmationMessage != nil {
                                    MealWideOverwriteConfirmationBlock()
                                        .padding(.top, 12)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("整餐一起调整", systemImage: "slider.horizontal.3")
                                        .font(.headline)
                                    Text("会应用到全部食物，可再单独修改")
                                        .font(.caption)
                                        .foregroundStyle(Color.readableSecondary)
                                }
                            }
                        }

                        ForEach(draft.items) { item in
                            ActualFoodEditor(item: item)
                        }

                        Card {
                            CorrectionEntryButton(
                                isLoading: store.isDraftCorrectionInProgress,
                                example: languageCorrectionExample(for: draft)
                            ) {
                                correctionDraft = ""
                                showingCorrectionInput = true
                            }
                            if let correctionMessage = store.correctionMessage {
                                Text(correctionMessage)
                                    .font(.footnote)
                                    .foregroundStyle(Color.amberText)
                                    .padding(.top, 8)
                            }
                            if let correction = store.pendingFoodCorrection {
                                ClarificationSelectionView(correction: correction)
                            }
                        }
                        .sheet(isPresented: $showingCorrectionInput) {
                            DraftCorrectionInputSheet(
                                text: $correctionDraft,
                                example: languageCorrectionExample(for: draft)
                            ) { text in
                                store.applyRealDraftLanguageCorrection(text)
                            }
                            .environmentObject(store)
                            .presentationDetents([.medium])
                            .presentationDragIndicator(.visible)
                        }
                    }
                }
                .padding()
            }
            .background(Color.cream)
            .navigationTitle("调整实际摄入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") {
                        onReturnToConfirmation()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("摄入调整并返回") {
                    onReturnToConfirmation()
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .padding()
                .background(Color.cream)
            }
        }
    }

    private func languageCorrectionExample(for entry: MealEntry) -> String {
        let names = entry.items.map(\.name)
        if names.filter({ $0 == "米饭" }).count > 1 {
            return "米饭吃了一半"
        }
        if names.contains("宫保鸡丁") && names.contains("米饭") {
            return "宫保鸡丁吃了一半，米饭全部吃完"
        }
        if names.contains("鸡蛋") && names.contains("拿铁") {
            return "鸡蛋吃了一个，拿铁全部喝完"
        }
        return "\(names.first ?? "食物")吃了一半"
    }
}

struct CorrectionEntryButton: View {
    let isLoading: Bool
    let example: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.coral.opacity(0.12))
                    Image(systemName: "mic.and.signal.meter.fill")
                        .foregroundStyle(Color.coral)
                        .font(.headline)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text("文字 / 语音修正食物项")
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.72)
                        }
                        Text(isLoading ? "正在解析修正..." : "例如：\(example)。语音输入暂未开放，请先用文字。")
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()
                Text("去修正")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.coral)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.coral.opacity(0.12))
                    .clipShape(Capsule())
            }
            .padding(12)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.coral.opacity(0.12))
            }
        }
        .buttonStyle(CorrectionEntryButtonStyle())
        .accessibilityLabel("文字或语音修正食物项")
    }
}

struct CorrectionEntryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .brightness(configuration.isPressed ? -0.02 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DraftCorrectionInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @Binding var text: String
    let example: String
    let onSubmit: (String) -> Void

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("输入你想修正的内容，AI 会尝试匹配当前草稿中的食物项。")
                    .font(.footnote)
                    .foregroundStyle(Color.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $text)
                    .frame(minHeight: 130)
                    .padding(10)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("例如：把馒头改成玉米，或米饭吃了一半")
                                .font(.body)
                                .foregroundStyle(.secondary.opacity(0.7))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                Text("语音输入暂未开放，请先使用文字修正。代理失败时会显示失败提示，可编辑后重试。")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)

                Button("提交修正") {
                    onSubmit(trimmedText)
                    dismiss()
                }
                .disabled(trimmedText.isEmpty || store.isDraftCorrectionInProgress)
                .buttonStyle(PrimaryActionButtonStyle())
                .padding(.top, 2)

                Button("填入示例：\(example)") {
                    text = example
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.coral)

                Spacer(minLength: 0)
            }
            .padding()
            .background(Color.cream)
            .navigationTitle("逐项修正")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundStyle(Color.readableSecondary)
                }
            }
        }
    }
}

struct RatioButton: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let ratio: Double

    var body: some View {
        RatioCapsuleButton(title: title) {
            store.applyDraftMealRatio(ratio)
        }
    }
}

struct RatioCapsuleButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.coral : Color.coral.opacity(0.45))
                .padding(.horizontal, 15)
                .frame(height: 36)
                .background(Color.coral.opacity(isEnabled ? 0.10 : 0.07))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.coral.opacity(isEnabled ? 0.14 : 0.08))
                }
        }
        .disabled(!isEnabled)
        .buttonStyle(RatioCapsuleButtonStyle())
    }
}

struct RatioCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? -0.025 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MealWideOverwriteConfirmationBlock: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Text("会覆盖当前各项调整，之后仍可单独修改。")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.amberText)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("取消") {
                    store.cancelDraftMealRatioOverwrite()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.readableSecondary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.surface.opacity(0.72))
                .clipShape(Capsule())

                Button("确认覆盖") {
                    store.confirmDraftMealRatioOverwrite()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.amberText)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.surface)
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Color.amber)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ActualFoodEditor: View {
    @EnvironmentObject private var store: AppStore
    let item: FoodItem

    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.headline)
                    Text("识别 \(item.recognizedQuantity.displayText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(item.actualNutrition.calories)) 千卡")
                    .font(.subheadline.weight(.semibold))
            }

            HStack {
                Text("实际吃了")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.setDraftItemAmount(foodID: item.id, amount: max(0, item.actualQuantity.amount - 1))
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(IntakeStepperButtonStyle())

                Text(item.actualQuantity.displayText)
                    .font(.headline)
                    .frame(minWidth: 72)

                Button {
                    store.setDraftItemAmount(foodID: item.id, amount: item.actualQuantity.amount + 1)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(IntakeStepperButtonStyle())
            }

            HStack {
                RatioCapsuleButton(title: "全部") {
                    store.setDraftItemRatio(foodID: item.id, ratio: 1)
                }
                RatioCapsuleButton(title: "1/2") {
                    store.setDraftItemRatio(foodID: item.id, ratio: 0.5)
                }
                RatioCapsuleButton(title: "1/4") {
                    store.setDraftItemRatio(foodID: item.id, ratio: 0.25)
                }
                RatioCapsuleButton(title: "自定义") {
                    let grams = item.recognizedQuantity.grams * 0.75
                    store.setDraftCustomQuantity(foodID: item.id, amount: grams, unit: "克", grams: grams)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isOverRecognizedAmount {
                VStack(alignment: .center, spacing: 10) {
                    Text(item.overRecognizedAmountConfirmed ? "已确认超过识别份量" : "实际摄入超过识别份量，请确认后再保存")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(item.overRecognizedAmountConfirmed ? Color.mintText : Color.amberText)
                        .multilineTextAlignment(.center)
                    if !item.overRecognizedAmountConfirmed {
                        Button("确认超过识别份量") {
                            store.confirmDraftOverRecognizedAmount(foodID: item.id)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.amberText)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Color.surface.opacity(0.72))
                        .clipShape(Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(item.overRecognizedAmountConfirmed ? Color.mint : Color.amber)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if item.actualQuantity.grams == 0 {
                Text("未食用 / 0 千卡；保留识别项但不计入汇总。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ClarificationSelectionView: View {
    @EnvironmentObject private var store: AppStore
    let correction: PendingFoodCorrection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("请选择要修正的 \(correction.foodName)")
                .font(.subheadline.weight(.semibold))
            ForEach(correction.candidates) { candidate in
                Button {
                    store.applyPendingFoodCorrection(to: candidate.id)
                } label: {
                    HStack {
                        Text(candidate.label)
                        Spacer()
                        Text("应用修正")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 8)
    }
}

struct MockErrorStateView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MockOnlyBanner()
                    Card {
                        Label(store.mockErrorState?.title ?? "识别失败", systemImage: "camera.metering.unknown")
                            .font(.headline)
                            .foregroundStyle(Color.amberText)
                        Text(store.mockErrorState?.message ?? "当前状态无法继续识别。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Card {
                        if store.mockErrorState == .realPhotoFailed {
                            ButtonRow(icon: "text.badge.plus", title: "改用文字补记", subtitle: "输入饮食描述后重新分析") {
                                store.openTextRecordInput()
                            }
                        } else if store.mockErrorState == .realTextFailed {
                            ButtonRow(icon: "arrow.clockwise", title: "重试真实文字分析", subtitle: store.textRecordDraft.isEmpty ? "返回输入页补充文字" : "再次分析：\(store.textRecordDraft)") {
                                store.retryTextRecordInput()
                            }
                            ButtonRow(icon: "square.and.pencil", title: "编辑文字后重试", subtitle: "修改饮食描述后重试") {
                                store.openTextRecordInput(prefill: store.textRecordDraft)
                            }
                        } else {
                            ButtonRow(icon: "text.badge.plus", title: "补充文字后继续", subtitle: "输入补充描述后继续文字分析") {
                                store.openTextRecordInput()
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color.cream)
            .navigationTitle("无法识别")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        store.activeModal = .recordMenu
                    }
                }
            }
        }
    }
}

struct PendingRecoveryView: View {
    @EnvironmentObject private var store: AppStore

    var pendingEntries: [MealEntry] {
        store.diary.entries.filter {
            if case .pendingAnalysis = $0.status { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HeaderView(title: "记录已保存，等待分析", subtitle: "网络异常")
                    MockOnlyBanner()
                    ForEach(pendingEntries) { entry in
                        Card {
                            HStack(alignment: .top, spacing: 12) {
                                Sticker(status: entry.status)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.sourceDescription)
                                        .font(.headline)
                                    Text("待分析，不计入今日汇总。网络恢复后可重试。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        Button("重试分析") {
                                            store.retryPending(entry)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        Button("删除") {
                                            store.deleteEntry(entry)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color.cream)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { store.activeModal = nil }
                }
            }
        }
    }
}

struct TrendView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingWeightInput = false
    @State private var weightInput = ""
    @State private var weightRecordDate = Date()

    private var weightButtonTitle: String {
        store.todayWeight == nil ? "添加今日体重" : "更新今日体重"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderView(title: "体重趋势", subtitle: "最近 30 天")

                HStack(spacing: 12) {
                    WeightMetric(title: "当前体重", value: store.latestWeight?.weight ?? 0)
                    WeightMetric(title: "目标体重", value: store.targetWeight)
                }

                Card {
                    Text("最近 30 天")
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    TrendLine(weights: store.diary.weights)
                        .frame(height: 180)
                    Text("包含 \(store.diary.weights.count) 天体重数据 · 点击数据点查看详情")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }

                Button(weightButtonTitle) {
                    let today = Date()
                    weightRecordDate = today
                    if let weight = store.weight(on: today)?.weight ?? store.latestWeight?.weight {
                        weightInput = String(format: "%.1f", weight)
                    } else {
                        weightInput = ""
                    }
                    showingWeightInput = true
                }
                .buttonStyle(PrimaryActionButtonStyle())

                Card {
                    Text("体重历史")
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    ForEach(store.diary.weights.sorted(by: { $0.date > $1.date })) { entry in
                        HStack(alignment: .center, spacing: 12) {
                            Text(String(format: "%.1f kg", entry.weight))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.ink)
                                .frame(minWidth: 82, alignment: .leading)
                            Spacer()
                            Text(entry.date.chineseFullDateText)
                                .font(.subheadline)
                                .foregroundStyle(Color.readableSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .allowsTightening(true)
                                .monospacedDigit()
                                .layoutPriority(1)
                                .frame(width: 142, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
                        Divider()
                    }
                }

                Spacer(minLength: 128)
            }
            .padding()
        }
        .background(Color.cream)
        .sheet(isPresented: $showingWeightInput) {
            WeightInputSheet(
                title: weightButtonTitle,
                weightText: $weightInput,
                recordDate: $weightRecordDate,
                onCancel: { showingWeightInput = false },
                onSave: { weight in
                    if store.saveWeight(weight, on: weightRecordDate) {
                        showingWeightInput = false
                    }
                }
            )
            .presentationDetents([.height(610)])
            .onChange(of: weightRecordDate) { _, newDate in
                if let weight = store.weight(on: newDate)?.weight {
                    weightInput = String(format: "%.1f", weight)
                } else if Calendar.current.isDateInToday(newDate), let weight = store.latestWeight?.weight {
                    weightInput = String(format: "%.1f", weight)
                } else {
                    weightInput = ""
                }
            }
        }
    }
}

struct WeightInputSheet: View {
    let title: String
    @Binding var weightText: String
    @Binding var recordDate: Date
    let onCancel: () -> Void
    let onSave: (Double) -> Void
    @State private var shouldReplacePrefill = true

    private var normalizedWeight: Double? {
        guard let value = Double(weightText) else { return nil }
        return (20.0...300.0).contains(value) ? (value * 10).rounded() / 10 : nil
    }

    private var helperText: String {
        if weightText.isEmpty {
            return "请输入 20.0–300.0 kg 范围内的体重。"
        }
        return normalizedWeight == nil ? "体重需在 20.0–300.0 kg 之间，最多一位小数。" : "仅用于展示你的体重趋势，可随时更新。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("体重")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(weightText.isEmpty ? "--" : weightText)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(weightText.isEmpty ? Color.secondary : Color.ink)
                Text("kg")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            ChineseDatePickerRow(title: "记录日期", selection: $recordDate, range: ...Date(), components: .date)
                .padding(.horizontal, 2)

            Text(helperText)
                .font(.footnote)
                .foregroundStyle(normalizedWeight == nil ? Color.amberText : .secondary)

            VStack(spacing: 10) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "delete.left"]], id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row, id: \.self) { key in
                            WeightKeyButton(key: key) {
                                handleKey(key)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button("取消", action: onCancel)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button("保存体重") {
                    if let normalizedWeight {
                        onSave(normalizedWeight)
                    }
                }
                .disabled(normalizedWeight == nil)
                .buttonStyle(PrimaryActionButtonStyle())
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .background(Color.cream)
        .onAppear {
            shouldReplacePrefill = !weightText.isEmpty
        }
    }

    private func handleKey(_ key: String) {
        if key == "delete.left" {
            shouldReplacePrefill = false
            if !weightText.isEmpty {
                weightText.removeLast()
            }
            return
        }
        if shouldReplacePrefill {
            weightText = ""
            shouldReplacePrefill = false
        }
        if key == "." {
            if weightText.isEmpty {
                applyCandidate("0.")
            } else if !weightText.contains(".") {
                applyCandidate(weightText + ".")
            }
            return
        }
        guard key.allSatisfy(\.isNumber) else { return }
        if let decimalIndex = weightText.firstIndex(of: ".") {
            let decimalCount = weightText.distance(from: weightText.index(after: decimalIndex), to: weightText.endIndex)
            guard decimalCount < 1 else { return }
        }
        if weightText == "0" {
            applyCandidate(key)
        } else {
            applyCandidate(weightText + key)
        }
    }

    private func applyCandidate(_ candidate: String) {
        guard isValidInputCandidate(candidate) else { return }
        weightText = candidate
    }

    private func isValidInputCandidate(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return true }
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        guard let integerPart = parts.first else { return false }
        guard integerPart.count <= 3 else { return false }
        if parts.count == 2 {
            guard parts[1].count <= 1 else { return false }
        }
        guard let value = Double(candidate) else { return candidate.hasSuffix(".") }
        return value <= 300.0
    }
}

struct WeightKeyButton: View {
    let key: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.surface)
                if key == "delete.left" {
                    Image(systemName: key)
                        .font(.title3.weight(.semibold))
                } else {
                    Text(key)
                        .font(.title2.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ink)
    }
}

struct WeightMetric: View {
    let title: String
    let value: Double

    var body: some View {
        Card {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
            Text(String(format: "%.1f", value))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ink)
            Text("kg")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
    }
}

struct TrendLine: View {
    let weights: [WeightEntry]

    var body: some View {
        GeometryReader { proxy in
            let sorted = weights.sorted { $0.date < $1.date }
            let values = sorted.map(\.weight)
            let rawMin = values.min() ?? 60
            let rawMax = values.max() ?? 70
            let minValue = rawMin == rawMax ? rawMin - 1 : rawMin - 0.5
            let maxValue = rawMin == rawMax ? rawMax + 1 : rawMax + 0.5
            let leftInset: CGFloat = 12
            let rightInset: CGFloat = 10
            let topInset: CGFloat = 10
            let bottomInset: CGFloat = 28
            let plotWidth = max(1, proxy.size.width - leftInset - rightInset)
            let plotHeight = max(1, proxy.size.height - topInset - bottomInset)
            let yTicks = [maxValue, (maxValue + minValue) / 2, minValue]
            let xLabelItems = axisLabelItems(from: sorted)

            ZStack {
                ForEach(Array(yTicks.enumerated()), id: \.offset) { index, _ in
                    let y = topInset + plotHeight * CGFloat(index) / CGFloat(max(yTicks.count - 1, 1))
                    Path { path in
                        path.move(to: CGPoint(x: leftInset, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width - rightInset, y: y))
                    }
                    .stroke(Color.black.opacity(0.07), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                }

                if !sorted.isEmpty {
                    Path { path in
                        for (index, entry) in sorted.enumerated() {
                            let point = point(for: entry.weight, index: index, count: sorted.count, minValue: minValue, maxValue: maxValue, leftInset: leftInset, topInset: topInset, plotWidth: plotWidth, plotHeight: plotHeight)
                            if index == 0 {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                    }
                    .stroke(Color.trendLine, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, entry in
                        let point = point(for: entry.weight, index: index, count: sorted.count, minValue: minValue, maxValue: maxValue, leftInset: leftInset, topInset: topInset, plotWidth: plotWidth, plotHeight: plotHeight)
                        Circle()
                            .fill(Color.surface)
                            .frame(width: 9, height: 9)
                            .overlay {
                                Circle().stroke(Color.trendLine, lineWidth: 2)
                            }
                            .position(point)
                    }
                }

                ForEach(xLabelItems, id: \.index) { item in
                    let x = sorted.count <= 1 ? leftInset + plotWidth / 2 : leftInset + plotWidth * CGFloat(item.index) / CGFloat(sorted.count - 1)
                    Text(item.date.chineseShortDateText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.readableSecondary)
                        .position(x: x, y: topInset + plotHeight + 17)
                }
            }
        }
    }

    private func point(
        for value: Double,
        index: Int,
        count: Int,
        minValue: Double,
        maxValue: Double,
        leftInset: CGFloat,
        topInset: CGFloat,
        plotWidth: CGFloat,
        plotHeight: CGFloat
    ) -> CGPoint {
        let x = count <= 1 ? leftInset + plotWidth / 2 : leftInset + plotWidth * CGFloat(index) / CGFloat(count - 1)
        let normalized = (value - minValue) / max(maxValue - minValue, 0.1)
        let y = topInset + plotHeight * CGFloat(1 - normalized)
        return CGPoint(x: x, y: y)
    }

    private func axisLabelItems(from sorted: [WeightEntry]) -> [(index: Int, date: Date)] {
        guard !sorted.isEmpty else { return [] }
        if sorted.count == 1 {
            return [(0, sorted[0].date)]
        }
        let middle = sorted.count / 2
        let indexes = Array(Set([0, middle, sorted.count - 1])).sorted()
        return indexes.map { ($0, sorted[$0].date) }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var proxyBaseURLDraft = ""
    @State private var aboutTapCount = 0
    @State private var showsAdvancedAISettings = false

    var body: some View {
        NavigationStack {
            List {
                Section("目标与记录") {
                    Picker("默认模式", selection: $store.defaultMode) {
                        Text("快速模式").tag("快速模式")
                        Text("精确模式").tag("精确模式")
                    }
                    .pickerStyle(.segmented)
                }
                Section("数据与隐私") {
                    Text("目标、饮食记录、体重记录和可重置设置会保存在本机；卸载 App 或更换手机会丢失。")
                    Text("食物照片仅用于本次 AI 分析，不在 App 内长期保存。")
                    Text("营养结果为估算参考，不作为医疗建议。")
                    Text("你可以删除单条饮食记录，也可以在这里删除全部本机数据并重新开始。")
                    if let message = store.localDataMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Color.readableSecondary)
                    }
                    Button("删除全部本机数据", role: .destructive) {
                        store.clearAllLocalData()
                    }
                }
                Section("关于") {
                    Text("热量咔")
                    Button("版本 1.0") {
                        aboutTapCount += 1
                        if aboutTapCount >= 7 {
                            showsAdvancedAISettings = true
                            aboutTapCount = 0
                            proxyBaseURLDraft = store.proxyBaseURLString
                            store.toast = "已开启高级设置"
                        }
                    }
                    .buttonStyle(.plain)
                    Text("AI 识别和营养估算仅用于饮食记录参考。")
                        .font(.footnote)
                        .foregroundStyle(Color.readableSecondary)
                }
                if showsAdvancedAISettings {
                    Section("高级连接设置") {
                        Text("仅在需要排查 AI 连接时使用。一般情况下不需要修改。")
                            .font(.footnote)
                            .foregroundStyle(Color.readableSecondary)

                        TextField("http://服务地址:8787", text: $proxyBaseURLDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        HStack {
                            Button("保存服务地址") {
                                store.applyProxyBaseURL(proxyBaseURLDraft)
                                proxyBaseURLDraft = store.proxyBaseURLString
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer()
                            Button("恢复默认地址") {
                                store.resetProxyBaseURLToSimulatorDefault()
                                proxyBaseURLDraft = store.proxyBaseURLString
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("检查连接") {
                            store.checkProxyHealth()
                        }

                        if let message = store.proxyConnectionMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(Color.readableSecondary)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { store.activeModal = nil }
                }
            }
            .onAppear {
                proxyBaseURLDraft = store.proxyBaseURLString
            }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.05))
        }
    }
}

struct DockButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? Color.coral : Color.readableSecondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? Color.coral.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct PrimaryDockButtonStyle: ButtonStyle {
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(highlighted ? Color.white : Color.coral)
            .background(highlighted ? Color.coral : Color.coral.opacity(0.13))
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Color.coral.opacity(highlighted ? 0.34 : 0.16))
            }
            .shadow(color: Color.coral.opacity(highlighted ? 0.22 : 0.10), radius: highlighted ? 14 : 8, y: highlighted ? 7 : 4)
            .scaleEffect(highlighted ? 1.08 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.74), value: highlighted)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.primaryAction)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct IntakeStepperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.ink)
            .frame(width: 36, height: 36)
            .background(Color.cream)
            .clipShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension Date {
    var chineseDateText: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return "\(components.year ?? 0)年\(components.month ?? 0)月\(components.day ?? 0)日"
    }

    var chineseDateTimeText: String {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        return "\(components.year ?? 0)年\(components.month ?? 0)月\(components.day ?? 0)日 \(String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0))"
    }

    var chineseShortDateText: String {
        let components = Calendar.current.dateComponents([.month, .day], from: self)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }

    var chineseMonthDayText: String {
        let components = Calendar.current.dateComponents([.month, .day], from: self)
        return String(format: "%02d月%02d日", components.month ?? 0, components.day ?? 0)
    }

    var chineseFullDateText: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return String(format: "%04d年%02d月%02d日", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

extension Color {
    static let cream = Color(red: 1.0, green: 0.973, blue: 0.949)
    static let surface = Color.white
    static let ink = Color(red: 0.141, green: 0.129, blue: 0.122)
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.29)
    static let primaryAction = Color(red: 0.72, green: 0.23, blue: 0.145)
    static let readableSecondary = Color(red: 0.42, green: 0.32, blue: 0.28)
    static let trendLine = Color(red: 0.78, green: 0.20, blue: 0.13)
    static let mint = Color(red: 0.866, green: 0.953, blue: 0.91)
    static let mintText = Color(red: 0.184, green: 0.459, blue: 0.345)
    static let amber = Color(red: 1.0, green: 0.945, blue: 0.78)
    static let amberText = Color(red: 0.475, green: 0.337, blue: 0.078)
    static let protein = Color(red: 0.408, green: 0.471, blue: 0.847)
    static let carb = Color(red: 0.839, green: 0.608, blue: 0.176)
    static let fat = Color(red: 0.776, green: 0.408, blue: 0.514)
}
