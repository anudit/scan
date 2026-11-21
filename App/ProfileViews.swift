import SwiftUI
import ScanEngine
import ScanQuery
import ScanTheme

private let usNumbers = Locale(identifier: "en_US")
private func formatted(_ value: Int) -> String { value.formatted(.number.locale(usNumbers)) }
private func percent(_ part: Int, of whole: Int) -> String {
    guard whole > 0 else { return "0%" }
    let value = Double(part) / Double(whole) * 100
    return value > 0 && value < 0.1 ? "<0.1%" : value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)).locale(usNumbers)) + "%"
}

/// A column summary in the inspector: counts, extremes, the distribution and the most common
/// values. It follows the focused column, and clicking a value or a bar filters to it.
struct ProfileView: View {
    @Bindable var model: DocumentModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Picker("Column", selection: Binding(get: { model.profileColumn }, set: { model.showProfile($0) })) {
                    if model.profileColumn.isEmpty { Text("Choose a column").tag("") }
                    ForEach(model.state.columns) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize(horizontal: false, vertical: true)
                if model.profileLoading { ProgressView().controlSize(.small).transition(.opacity) }
            }
            if !model.state.groups.isEmpty {
                note("Profiles describe rows. Clear the pivot to profile a column.")
            } else if let error = model.profileError {
                note(error).foregroundStyle(Color(nsColor: ScanTheme.danger))
            } else if let profile = model.profile {
                ScrollView(.vertical) { content(profile).padding(.bottom, 8) }.scrollIndicators(.never)
                    .opacity(model.profileLoading ? 0.55 : 1)
            } else if model.profileColumn.isEmpty {
                note("Select a cell or choose a column to see its distribution, empty values and most common values.")
            } else {
                ProfileSkeleton()
            }
        }
        .animation(Motion.hover, value: model.profileLoading)
        .onAppear {
            if model.profileColumn.isEmpty, model.state.columns.indices.contains(model.selectedIndex) { model.profileColumn = model.state.columns[model.selectedIndex].name }
            model.loadProfile()
        }
    }

    private func note(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }

    @ViewBuilder private func content(_ profile: ColumnProfile) -> some View {
        let present = profile.rows - profile.nulls
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                Stat(label: "Rows", value: formatted(profile.rows))
                Stat(label: "Distinct", value: "≈ " + formatted(profile.distinct), detail: percent(profile.distinct, of: max(1, present)) + " unique")
                Stat(label: "Empty (NULL)", value: formatted(profile.nulls), detail: percent(profile.nulls, of: profile.rows), tint: profile.nulls > 0 ? Color(nsColor: ScanTheme.null) : nil)
                if let mean = profile.mean { Stat(label: "Mean", value: Self.number(mean)) }
                if let minimum = profile.minimum { Stat(label: "Min", value: minimum, mono: true) }
                if let maximum = profile.maximum { Stat(label: "Max", value: maximum, mono: true) }
            }
            NullBar(fraction: profile.rows > 0 ? Double(profile.nulls) / Double(profile.rows) : 0)
            if !profile.bins.isEmpty, let range = profile.binRange {
                VStack(alignment: .leading, spacing: 6) {
                    label("Distribution")
                    Histogram(bins: profile.bins, range: range, temporal: profile.kind == .temporal) { low, high, last in
                        guard profile.kind == .number else { return }
                        let c = Planner.identifier(profile.column)
                        model.addRawFilter("\(c) >= \(Self.literal(low)) AND \(c) \(last ? "<=" : "<") \(Self.literal(high))")
                    }
                }
            }
            if let first = profile.top.first, first.count == 1, profile.distinct >= present * 9 / 10 {
                note("Every value appears once.")
            } else if !profile.top.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    label("Most common")
                    ForEach(Array(profile.top.enumerated()), id: \.offset) { _, entry in
                        ValueRow(entry: entry, total: profile.rows, peak: profile.top.first?.count ?? 1) {
                            model.filter(column: profile.column, value: entry.value)
                        } exclude: {
                            model.filter(column: profile.column, value: entry.value, .exclude)
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: profile)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: ScanTheme.muted))
    }
    static func number(_ value: Double) -> String {
        abs(value) >= 1e15 || (abs(value) < 1e-4 && value != 0) ? value.formatted(.number.notation(.scientific).locale(usNumbers))
            : value.formatted(.number.precision(.significantDigits(1...6)).locale(usNumbers))
    }
    /// A bound written so DuckDB reads it back exactly.
    static func literal(_ value: Double) -> String { value.description }
}

private struct Stat: View {
    let label: String
    let value: String
    var detail: String?
    var tint: Color?
    var mono = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: mono ? .monospaced : .default)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(tint ?? Color(nsColor: ScanTheme.primary)).contentTransition(.numericText()).textSelection(.enabled)
            if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
    }
}

/// How much of the column is present, as a filled track.
private struct NullBar: View {
    @Environment(\.accentRevision) private var accentRevision
    let fraction: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: ScanTheme.null).opacity(fraction > 0 ? 0.45 : 0.12))
                Capsule().fill(Color.scanAccent.opacity(0.75)).frame(width: proxy.size.width * (1 - fraction))
            }
        }
        .frame(height: 4)
        .help("\(percent(Int(((1 - fraction) * 1000).rounded()), of: 1000)) of rows have a value")
    }
}

/// Bars for each bin. Hovering shows a bin's range and count; clicking a numeric bin filters to it.
private struct Histogram: View {
    @Environment(\.accentRevision) private var accentRevision
    let bins: [Int]
    let range: ClosedRange<Double>
    let temporal: Bool
    let select: (Double, Double, Bool) -> Void
    @State private var hovered: Int?
    @State private var grown = false
    var body: some View {
        let peak = max(1, bins.max() ?? 1)
        let step = bins.count > 0 ? (range.upperBound - range.lowerBound) / Double(bins.count) : 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(bins.enumerated()), id: \.offset) { index, count in
                    let height = count == 0 ? 1 : max(2, 64 * sqrt(Double(count) / Double(peak)))
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.scanAccent.opacity(hovered == nil || hovered == index ? 0.8 : 0.35))
                        .frame(height: grown ? height : 1)
                        .frame(maxWidth: .infinity, maxHeight: 64, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { inside in hovered = inside ? index : (hovered == index ? nil : hovered) }
                        .onTapGesture { select(range.lowerBound + Double(index) * step, range.lowerBound + Double(index + 1) * step, index == bins.count - 1) }
                }
            }
            .frame(height: 64)
            .animation(Motion.hover, value: hovered)
            HStack {
                if let hovered {
                    Text("\(bound(range.lowerBound + Double(hovered) * step)) – \(bound(range.lowerBound + Double(hovered + 1) * step))")
                    Spacer()
                    Text(formatted(bins[hovered]) + " rows")
                } else {
                    Text(bound(range.lowerBound)); Spacer(); Text(bound(range.upperBound))
                }
            }
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { grown = true } }
    }
    private func bound(_ value: Double) -> String {
        temporal ? Date(timeIntervalSince1970: value).formatted(.iso8601.year().month().day()) : ProfileView.number(value)
    }
}

/// A value with its count, over a bar scaled to the most common value.
private struct ValueRow: View {
    @Environment(\.accentRevision) private var accentRevision
    let entry: ValueCount
    let total: Int
    let peak: Int
    let only: () -> Void
    let exclude: () -> Void
    var body: some View {
        Button(action: only) {
            HStack(spacing: 8) {
                Text(display).font(.system(size: 12, design: entry.value == nil ? .default : .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(entry.value == nil ? Color(nsColor: ScanTheme.null) : entry.value?.isEmpty == true ? Color(nsColor: ScanTheme.faint) : Color(nsColor: ScanTheme.primary))
                Spacer(minLength: 4)
                Text(formatted(entry.count)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text(percent(entry.count, of: total)).font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            .frame(height: 24)
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.scanAccent.opacity(0.12))
                        .frame(width: max(3, proxy.size.width * Double(entry.count) / Double(max(1, peak)) ))
                }.padding(.horizontal, -8)
            }
            .rowHighlight()
        }
        .buttonStyle(.plain)
        .help("Click to show only this value")
        .contextMenu {
            Button("Only This Value", action: only)
            Button("Exclude This Value", action: exclude)
            if let value = entry.value { Button("Copy Value") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } }
        }
    }
    private var display: String {
        guard let value = entry.value else { return "NULL" }
        return value.isEmpty ? "EMPTY" : value.replacingOccurrences(of: "\n", with: " ")
    }
}

/// A placeholder while the first profile loads.
private struct ProfileSkeleton: View {
    @State private var pulse = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07))
                    .frame(width: [160, 110, 190, 140, 170, 90][index], height: 12)
            }
        }
        .opacity(pulse ? 0.5 : 1)
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
    }
}

/// The most common values of a column, shown under it in the sidebar. Clicking one filters to it.
struct FacetList: View {
    @Bindable var model: DocumentModel
    let column: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if model.facetLoading && model.facetValues.isEmpty {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Counting values…").font(.system(size: 11)).foregroundStyle(.secondary) }.frame(height: 24)
            } else if model.facetValues.isEmpty {
                Text("No values").font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 24)
            }
            let total = max(1, model.facetValues.map(\.count).max() ?? 1)
            ForEach(Array(model.facetValues.enumerated()), id: \.offset) { _, entry in
                FacetRow(entry: entry, peak: total) { model.filter(column: column, value: entry.value) }
                    exclude: { model.filter(column: column, value: entry.value, .exclude) }
            }
        }
        .padding(.leading, 26)
        .opacity(model.facetLoading && !model.facetValues.isEmpty ? 0.55 : 1)
        .animation(Motion.hover, value: model.facetLoading)
    }
}

private struct FacetRow: View {
    @Environment(\.accentRevision) private var accentRevision
    let entry: ValueCount
    let peak: Int
    let only: () -> Void
    let exclude: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: only) {
            HStack(spacing: 6) {
                Text(entry.value.map { $0.isEmpty ? "EMPTY" : $0 } ?? "NULL").font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(entry.value == nil ? Color(nsColor: ScanTheme.null) : Color(nsColor: ScanTheme.primary).opacity(0.9))
                Spacer(minLength: 4)
                Text(formatted(entry.count)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).frame(height: 22)
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.scanAccent.opacity(hovering ? 0.22 : 0.11))
                        .frame(width: max(2, proxy.size.width * Double(entry.count) / Double(peak)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("Click to show only this value")
        .contextMenu {
            Button("Only This Value", action: only)
            Button("Exclude This Value", action: exclude)
        }
    }
}
