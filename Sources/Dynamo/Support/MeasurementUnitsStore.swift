import Foundation
import SwiftUI

/// App-wide metric / imperial preference + on-device conversion helpers.
@MainActor
final class MeasurementUnitsStore: ObservableObject {
    static let shared = MeasurementUnitsStore()

    enum System: String, CaseIterable, Identifiable {
        case metric
        case imperial

        var id: String { rawValue }

        var title: String {
            switch self {
            case .metric: return "Metric"
            case .imperial: return "Imperial"
            }
        }
    }

    enum Category: String, CaseIterable, Identifiable {
        case distance, temperature, length, mass, volume

        var id: String { rawValue }

        var title: String {
            switch self {
            case .distance: return "Distance"
            case .temperature: return "Temperature"
            case .length: return "Length"
            case .mass: return "Mass"
            case .volume: return "Volume"
            }
        }
    }

    private static let systemKey = "dynamo.units.system"
    private static let showTableKey = "dynamo.units.showConversionTable"

    @Published var system: System {
        didSet { UserDefaults.standard.set(system.rawValue, forKey: Self.systemKey) }
    }

    /// When true, World Clock Convert shows the reference table.
    @Published var showConversionTable: Bool {
        didSet { UserDefaults.standard.set(showConversionTable, forKey: Self.showTableKey) }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.systemKey),
           let parsed = System(rawValue: raw) {
            system = parsed
        } else {
            // US (and similar) → imperial; everyone else → metric.
            let region = Locale.current.region?.identifier ?? ""
            system = ["US", "LR", "MM"].contains(region) ? .imperial : .metric
        }
        if UserDefaults.standard.object(forKey: Self.showTableKey) == nil {
            showConversionTable = false
        } else {
            showConversionTable = UserDefaults.standard.bool(forKey: Self.showTableKey)
        }
    }

    // MARK: - Formatters

    /// `km` is always the storage unit from CoreLocation.
    func formatDistance(kilometers km: Double) -> String {
        switch system {
        case .metric:
            if km < 10 { return String(format: "%.1f km", km) }
            return String(format: "%.0f km", km.rounded())
        case .imperial:
            let mi = km * 0.621371
            if mi < 10 { return String(format: "%.1f mi", mi) }
            return String(format: "%.0f mi", mi.rounded())
        }
    }

    func formatTemperature(celsius c: Double) -> String {
        switch system {
        case .metric:
            return String(format: "%.0f°C", c.rounded())
        case .imperial:
            let f = c * 9 / 5 + 32
            return String(format: "%.0f°F", f.rounded())
        }
    }

    /// Convert a Measurement temperature for display using the store preference.
    func formatTemperature(_ temperature: Measurement<UnitTemperature>) -> String {
        switch system {
        case .metric:
            let c = temperature.converted(to: .celsius).value
            return String(format: "%.0f°", c.rounded())
        case .imperial:
            let f = temperature.converted(to: .fahrenheit).value
            return String(format: "%.0f°", f.rounded())
        }
    }

    // MARK: - Conversion

    struct UnitOption: Identifiable, Hashable {
        let id: String
        let title: String
        /// Multiply by this to reach the category’s SI base (m, kg, L, °C, km).
        let toBase: Double
        let offset: Double // for temperature

        init(_ id: String, _ title: String, toBase: Double, offset: Double = 0) {
            self.id = id
            self.title = title
            self.toBase = toBase
            self.offset = offset
        }
    }

    func units(for category: Category) -> [UnitOption] {
        switch category {
        case .distance:
            return [
                UnitOption("km", "Kilometers", toBase: 1),
                UnitOption("mi", "Miles", toBase: 1.60934),
                UnitOption("nmi", "Nautical miles", toBase: 1.852)
            ]
        case .temperature:
            return [
                UnitOption("c", "Celsius", toBase: 1, offset: 0),
                UnitOption("f", "Fahrenheit", toBase: 5.0 / 9.0, offset: -32),
                UnitOption("k", "Kelvin", toBase: 1, offset: -273.15)
            ]
        case .length:
            return [
                UnitOption("m", "Meters", toBase: 1),
                UnitOption("ft", "Feet", toBase: 0.3048),
                UnitOption("in", "Inches", toBase: 0.0254),
                UnitOption("cm", "Centimeters", toBase: 0.01),
                UnitOption("yd", "Yards", toBase: 0.9144)
            ]
        case .mass:
            return [
                UnitOption("kg", "Kilograms", toBase: 1),
                UnitOption("lb", "Pounds", toBase: 0.453592),
                UnitOption("oz", "Ounces", toBase: 0.0283495),
                UnitOption("g", "Grams", toBase: 0.001)
            ]
        case .volume:
            return [
                UnitOption("l", "Liters", toBase: 1),
                UnitOption("gal", "Gallons (US)", toBase: 3.78541),
                UnitOption("ml", "Milliliters", toBase: 0.001),
                UnitOption("cup", "Cups (US)", toBase: 0.236588)
            ]
        }
    }

    func defaultFromUnit(for category: Category) -> UnitOption {
        let opts = units(for: category)
        switch (category, system) {
        case (.distance, .imperial), (.length, .imperial):
            return opts.first { $0.id == "mi" || $0.id == "ft" } ?? opts[0]
        case (.temperature, .imperial):
            return opts.first { $0.id == "f" } ?? opts[0]
        case (.mass, .imperial):
            return opts.first { $0.id == "lb" } ?? opts[0]
        case (.volume, .imperial):
            return opts.first { $0.id == "gal" } ?? opts[0]
        default:
            return opts[0]
        }
    }

    func defaultToUnit(for category: Category) -> UnitOption {
        let opts = units(for: category)
        switch (category, system) {
        case (.distance, .imperial), (.length, .imperial):
            return opts.first { $0.id == "km" || $0.id == "m" } ?? opts[0]
        case (.temperature, .imperial):
            return opts.first { $0.id == "c" } ?? opts[0]
        case (.mass, .imperial):
            return opts.first { $0.id == "kg" } ?? opts[0]
        case (.volume, .imperial):
            return opts.first { $0.id == "l" } ?? opts[0]
        default:
            return opts.count > 1 ? opts[1] : opts[0]
        }
    }

    func convert(value: Double, from: UnitOption, to: UnitOption, category: Category) -> Double {
        if category == .temperature {
            // to °C base, then out
            let celsius = (value + from.offset) * from.toBase
            if to.id == "c" { return celsius }
            if to.id == "f" { return celsius * 9 / 5 + 32 }
            if to.id == "k" { return celsius + 273.15 }
            return celsius
        }
        let base = value * from.toBase
        return base / to.toBase
    }

    /// Common reference rows for the conversion table.
    func referenceRows(category: Category) -> [(label: String, value: String)] {
        switch category {
        case .distance:
            return [
                ("1 mi", formatDistance(kilometers: 1.60934)),
                ("5 mi", formatDistance(kilometers: 8.04672)),
                ("10 km", system == .metric ? "10 km" : String(format: "%.1f mi", 6.21371)),
                ("100 km", system == .metric ? "100 km" : String(format: "%.0f mi", 62.0))
            ]
        case .temperature:
            return [
                ("0°C", formatTemperature(celsius: 0)),
                ("20°C", formatTemperature(celsius: 20)),
                ("37°C", formatTemperature(celsius: 37)),
                ("100°C", formatTemperature(celsius: 100))
            ]
        case .length:
            return system == .metric
                ? [("1 ft", "0.30 m"), ("1 yd", "0.91 m"), ("1 in", "2.54 cm"), ("6 ft", "1.83 m")]
                : [("1 m", "3.28 ft"), ("1 cm", "0.39 in"), ("100 m", "328 ft"), ("1 km", "3281 ft")]
        case .mass:
            return system == .metric
                ? [("1 lb", "0.45 kg"), ("8 oz", "227 g"), ("1 oz", "28 g"), ("10 lb", "4.5 kg")]
                : [("1 kg", "2.20 lb"), ("100 g", "3.5 oz"), ("500 g", "1.1 lb"), ("70 kg", "154 lb")]
        case .volume:
            return system == .metric
                ? [("1 gal", "3.79 L"), ("1 cup", "237 mL"), ("1 qt", "0.95 L"), ("16 oz", "473 mL")]
                : [("1 L", "0.26 gal"), ("500 mL", "2.1 cup"), ("250 mL", "1.1 cup"), ("2 L", "0.53 gal")]
        }
    }
}

// MARK: - Reusable convert UI (Preferences + World Clock)

struct MeasurementConvertPanel: View {
    @ObservedObject var units = MeasurementUnitsStore.shared
    @State private var category: MeasurementUnitsStore.Category = .distance
    @State private var inputText: String = "10"
    @State private var fromID: String = "km"
    @State private var toID: String = "mi"

    private var fromUnit: MeasurementUnitsStore.UnitOption {
        units.units(for: category).first { $0.id == fromID } ?? units.defaultFromUnit(for: category)
    }

    private var toUnit: MeasurementUnitsStore.UnitOption {
        units.units(for: category).first { $0.id == toID } ?? units.defaultToUnit(for: category)
    }

    private var inputValue: Double {
        Double(inputText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var outputValue: Double {
        units.convert(value: inputValue, from: fromUnit, to: toUnit, category: category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Category", selection: $category) {
                ForEach(MeasurementUnitsStore.Category.allCases) { cat in
                    Text(cat.title).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: category) { cat in
                fromID = units.defaultFromUnit(for: cat).id
                toID = units.defaultToUnit(for: cat).id
            }

            HStack(spacing: 8) {
                TextField("Value", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                Picker("From", selection: $fromID) {
                    ForEach(units.units(for: category)) { u in
                        Text(u.title).tag(u.id)
                    }
                }
                .labelsHidden()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Picker("To", selection: $toID) {
                    ForEach(units.units(for: category)) { u in
                        Text(u.title).tag(u.id)
                    }
                }
                .labelsHidden()
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatted(outputValue))
                    .font(.title2.monospacedDigit().weight(.semibold))
                Text(toUnit.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    units.showConversionTable.toggle()
                } label: {
                    Label(
                        units.showConversionTable ? "Hide table" : "Show table",
                        systemImage: "tablecells"
                    )
                }
                .controlSize(.small)
            }

            if units.showConversionTable {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reference")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(units.referenceRows(category: category), id: \.label) { row in
                        HStack {
                            Text(row.label)
                                .font(.caption.monospacedDigit())
                            Spacer()
                            Text(row.value)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                )
            }
        }
        .onAppear {
            fromID = units.defaultFromUnit(for: category).id
            toID = units.defaultToUnit(for: category).id
        }
    }

    private func formatted(_ value: Double) -> String {
        if abs(value) >= 100 { return String(format: "%.1f", value) }
        if abs(value) >= 10 { return String(format: "%.2f", value) }
        return String(format: "%.3f", value)
    }
}
