import SwiftUI

/// Weather is a destination, with its configuration tucked behind the place name.
struct WeatherPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var phase
    let accent: Color
    var preview: WallWeather? = nil
    var referenceDate: Date? = nil
    @State private var report: WallWeather?
    @State private var selectedHour: Double?
    @State private var editingPlace = false
    @State private var query = ""
    @State private var busy = false
    @State private var loading = true
    @State private var problem: String?
    @State private var placeProblem: String?
    @State private var lastReceived: Date?
    @State private var previewUnits = "f"
    @FocusState private var placeFocused: Bool

    private var data: WallWeather? { report ?? preview }
    private var isPreview: Bool { preview != nil }
    private var isF: Bool { (isPreview ? previewUnits : wall.state.weatherUnits) == "f" }
    private var place: String {
        let value = data?.place ?? wall.state.place
        return value.isEmpty ? "Your weather" : value
    }
    private var hour: WallWeather.Hour? { data?.hours?.first { $0.t == selectedHour && selectedHour != nil } }
    private var nowDate: Date { referenceDate ?? .now }
    private var date: Date { hour?.t.map(Date.init(timeIntervalSince1970:)) ?? nowDate }
    private var mood: WeatherMood {
        let day = hour?.is_day ?? data?.now?.is_day ?? true
        let nearSun = [data?.now?.sunrise, data?.now?.sunset].compactMap { $0 }
            .contains { abs(date.timeIntervalSince1970 - $0) < 4500 }
        return WeatherMood(code: hour?.code ?? data?.now?.code, day: day, golden: day && nearSun)
    }
    private var unavailable: Bool { problem != nil || data?.problem != nil }
    private var stale: Bool {
        (data?.stale ?? false) || (data?.age_s ?? 0) + Int(lastReceived.map { Date().timeIntervalSince($0) } ?? 0) > 3600
    }
    private var shownOnWall: Bool { wall.link.isLive && wall.state.mode == "weather" }
    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if data?.now != nil {
                    hero
                    forecast
                    wallControl
                    instruments
                    daylight
                    source
                } else {
                    emptyState
                    placeEditor
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(initialAnchor)
        .background {
            ZStack(alignment: .top) {
                Ink.ground
                RadialGradient(colors: [mood.accent.opacity(0.08), .clear], center: .topTrailing, startRadius: 10, endRadius: 520)
            }.ignoresSafeArea()
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .tint(mood.accent)
        .refreshable { await refresh() }
        .sheet(isPresented: $editingPlace) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Choose your sky").font(.display(30)).foregroundStyle(Ink.ink)
                        Text("Name a town or city. The forecast and your wall will follow it.")
                            .font(.ui(16)).foregroundStyle(Ink.dim)
                        placeEditor
                    }.padding(24)
                }
                .background(Ink.ground)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { editingPlace = false }.tint(Ink.ink)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
        .task(id: wall.host) {
            guard !isPreview else {
                loading = false
                #if DEBUG
                if CommandLine.arguments.contains("-weather-hour"), let hours = data?.hours, hours.count > 2 { selectedHour = hours[2].t }
                if CommandLine.arguments.contains("-weather-celsius") { previewUnits = "c" }
                #endif
                return
            }
            while !Task.isCancelled {
                if phase == .active { await refresh() }
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        .onChange(of: data?.place) { _, _ in selectedHour = nil }
    }

    private var initialAnchor: UnitPoint {
        #if DEBUG
        if isPreview && CommandLine.arguments.contains("-weather-detail") { return .bottom }
        #endif
        return .top
    }

    private var header: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Weather").font(.display(32)).foregroundStyle(Ink.ink)
                    unitPicker
                }
            } else {
                HStack {
                    Text("Weather").font(.display(32)).foregroundStyle(Ink.ink)
                    Spacer()
                    unitPicker
                }
            }
        }
    }

    private var unitPicker: some View {
        HStack(spacing: 2) {
            unitButton("°F", value: "f")
            unitButton("°C", value: "c")
        }
        .padding(4)
        .background(Ink.plaster, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 1))
    }

    private func unitButton(_ title: String, value: String) -> some View {
        let selected = (value == "f") == isF
        return Button {
            if isPreview { previewUnits = value }
            else { wall.send(["weather_units": value]) }
            Taps.detent(intensity: 0.4)
        } label: {
            Text(title).font(.ui(14, .semibold))
                .foregroundStyle(selected ? Ink.ground : Ink.dim)
                .frame(minWidth: 40, minHeight: 36)
                .background(selected ? Ink.ink : .clear, in: Capsule())
                .padding(.vertical, 2)
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .accessibilityLabel(value == "f" ? "Fahrenheit" : "Celsius")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(stale || unavailable ? Ink.tile : mood.accent).frame(width: 5, height: 5)
                Text(hour == nil ? (stale || unavailable ? "LAST KNOWN WEATHER" : "CURRENT CONDITIONS") : "FORECAST · \(time(hour?.t, format: "h a"))")
                    .font(.machine(9)).kerning(1.1)
                Spacer(minLength: 0)
                Image(systemName: hour == nil ? "location.fill" : "clock").font(.system(size: 11))
            }
            .foregroundStyle(Color(hex: 0xE3E8DC))
            .padding(.bottom, 18)
            Button { editingPlace = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(place).font(.ui(25, .medium)).multilineTextAlignment(.leading)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                }.foregroundStyle(Color(hex: 0xF4F0E5))
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Change place, \(place)")
            .padding(.bottom, 10)
            Text(degrees(hour?.temp ?? data?.now?.temp))
                .font(.custom(Face.displayBook, size: typeSize.isAccessibilitySize ? 100 : 118))
                .tracking(-5)
                .foregroundStyle(Color(hex: 0xFFF2DE))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.65)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                .accessibilityLabel("\(degrees(hour?.temp ?? data?.now?.temp)) \(isF ? "Fahrenheit" : "Celsius")")
            Text(mood.words).font(.ui(18, .medium)).foregroundStyle(Color(hex: 0xF4F0E5))
                .padding(.top, -2)
            HStack(spacing: 12) {
                Label(degrees(data?.now?.high), systemImage: "arrow.up")
                Label(degrees(data?.now?.low), systemImage: "arrow.down")
            }
            .font(.ui(13, .medium)).foregroundStyle(Color(hex: 0xE1E4DB))
            .padding(.top, 10)
            Spacer(minLength: 64)
            Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: mood.symbol).symbolRenderingMode(.hierarchical)
                    .font(.system(size: 20)).foregroundStyle(mood.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hour == nil ? "The sky, in motion." : "A look ahead.")
                        .font(.ui(13, .semibold)).foregroundStyle(Color(hex: 0xF4F0E5))
                    Text(hour == nil ? "Drawn from your local forecast" : "\(time(hour?.t, format: "h:mm a")) · \(mood.words)")
                        .font(.ui(11)).foregroundStyle(Color(hex: 0xB5C3BC))
                }
                Spacer(minLength: 0)
                if hour != nil {
                    Button("Now") { select(nil) }
                        .font(.ui(13, .semibold)).foregroundStyle(mood.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .buttonStyle(PressStyle())
                } else {
                    Text(isPreview ? "PREVIEW" : "TESSERA").font(.machine(8)).kerning(1.5)
                        .foregroundStyle(Color(hex: 0xB5C3BC))
                }
            }.padding(.top, 16)
        }
        .padding(24)
        .frame(minHeight: typeSize.isAccessibilitySize ? 520 : 450)
        .background { WeatherAtmosphere(mood: mood, wind: data?.now?.wind_kmh ?? 8, date: date) }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.025), mood.accent.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .animation(Motion.settle, value: selectedHour)
        .animation(Motion.blink, value: isF)
    }

    @ViewBuilder private var forecast: some View {
        if let hours = data?.hours, !hours.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("The next hours").font(.displayMid(21)).foregroundStyle(Ink.ink)
                    Spacer()
                    if !typeSize.isAccessibilitySize {
                        Text("TAP TO EXPLORE").font(.machine(8)).kerning(0.6).foregroundStyle(Ink.dim)
                    }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(hours.enumerated()), id: \.offset) { _, h in
                            let selected = h.t != nil && selectedHour == h.t
                            let m = WeatherMood(code: h.code, day: h.is_day ?? true)
                            Button { select(h.t) } label: {
                                VStack(spacing: 14) {
                                    Text(time(h.t, format: "ha").lowercased()).font(.machine(10))
                                        .foregroundStyle(selected ? Ink.ink : Ink.dim)
                                    Image(systemName: m.symbol).symbolRenderingMode(.hierarchical)
                                        .font(.system(size: 23)).foregroundStyle(selected ? m.accent : Ink.ink)
                                        .frame(height: 28)
                                    Text(degrees(h.temp)).font(.ui(18, .medium)).foregroundStyle(Ink.ink)
                                    Circle().fill(selected ? m.accent : Ink.hairline).frame(width: 4, height: 4)
                                }
                                .frame(width: typeSize.isAccessibilitySize ? 112 : 55).padding(.vertical, 14)
                                .background(selected ? mood.accent.opacity(0.09) : Ink.plaster.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? mood.accent.opacity(0.45) : .clear, lineWidth: 1))
                            }
                            .disabled(h.t == nil)
                            .buttonStyle(PressStyle(scale: 0.97))
                            .accessibilityLabel("\(time(h.t, format: "h a")), \(m.words), \(degrees(h.temp))")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }.padding(1)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var wallControl: some View {
        Button {
            guard !isPreview else { return }
            wall.send(["mode": "weather"]); Taps.commit()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(mood.accent.opacity(0.1))
                    if shownOnWall, let frame = wall.frame {
                        PanelCanvas(px: [UInt8](frame), duty: 1).clipShape(RoundedRectangle(cornerRadius: 7)).padding(4)
                    } else {
                        Image(systemName: "square.grid.3x3.fill").font(.system(size: 22)).foregroundStyle(mood.accent)
                    }
                }.frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(shownOnWall ? "Weather is on the wall" : "Put the sky on your wall")
                        .font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                    Text(isPreview ? "Connect your wall to display the weather" : shownOnWall ? "Live conditions · animated in light" : wall.link.isLive ? "Show the current weather face" : "Connect your wall to show the weather")
                        .font(.ui(12)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: shownOnWall ? "checkmark" : "arrow.up.right")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(mood.accent)
            }
            .padding(16)
            .background(mood.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(mood.accent.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(PressStyle(scale: 0.985))
        .disabled(isPreview || !wall.link.isLive || shownOnWall)
    }

    private var instruments: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Right now").font(.displayMid(21)).foregroundStyle(Ink.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                instrument("Feels like", symbol: "thermometer.medium", value: degrees(data?.now?.feels), note: "Apparent temperature", kind: 0)
                instrument("Wind", symbol: "wind", value: windLabel, note: isF ? "Miles per hour" : "Kilometres per hour", kind: 1)
                instrument("Cloud cover", symbol: "cloud", value: data?.now?.cloud.map { "\(Int($0.rounded()))%" } ?? "—", note: "Of the sky covered", kind: 2)
                instrument("Precipitation", symbol: "drop", value: rainLabel, note: "In the current hour", kind: 3)
            }
        }
    }

    private func instrument(_ title: String, symbol: String, value: String, note: String, kind: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.ui(12, .medium)).foregroundStyle(Ink.dim)
            Text(value).font(.displayMid(32)).foregroundStyle(Ink.ink).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            WeatherInstrument(kind: kind, accent: mood.accent, cloud: data?.now?.cloud ?? 0)
                .frame(height: 24).accessibilityHidden(true)
            Text(note).font(.ui(10)).foregroundStyle(Ink.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(Ink.plaster.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Ink.hairline.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var daylight: some View {
        if let rise = data?.now?.sunrise, let set = data?.now?.sunset, set > rise {
            let progress = min(1, max(0, (nowDate.timeIntervalSince1970 - rise) / (set - rise)))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Daylight", systemImage: "sun.horizon").font(.ui(13, .medium)).foregroundStyle(Ink.dim)
                    Spacer()
                    Text(daylightLabel(rise: rise, set: set)).font(.machine(10)).foregroundStyle(mood.accent)
                }
                Canvas { ctx, size in
                    let w = size.width, h = size.height - 10
                    var arc = Path()
                    arc.move(to: CGPoint(x: 8, y: h))
                    arc.addQuadCurve(to: CGPoint(x: w - 8, y: h), control: CGPoint(x: w / 2, y: -h * 0.85))
                    ctx.stroke(arc, with: .color(Ink.dim.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                    ctx.stroke(arc.trimmedPath(from: 0, to: progress), with: .color(mood.accent), lineWidth: 1.5)
                    var horizon = Path(); horizon.move(to: CGPoint(x: 0, y: h)); horizon.addLine(to: CGPoint(x: w, y: h))
                    ctx.stroke(horizon, with: .color(Ink.hairline), lineWidth: 0.5)
                    // Get the endpoint from the trimmed path, matching its arc-length parameter.
                    let p = arc.trimmedPath(from: 0, to: max(0.001, progress)).currentPoint ?? CGPoint(x: 8, y: h)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)), with: .radialGradient(Gradient(colors: [mood.accent.opacity(0.3), .clear]), center: p, startRadius: 0, endRadius: 16))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(mood.accent))
                }.frame(height: 78).accessibilityHidden(true)
                HStack {
                    solarTime("Sunrise", value: time(rise, format: "h:mm a"), alignment: .leading)
                    Spacer()
                    solarTime("Sunset", value: time(set, format: "h:mm a"), alignment: .trailing)
                }
            }
            .padding(20)
            .background(Ink.plaster.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .combine)
        }
    }

    private func solarTime(_ title: String, value: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(title).font(.ui(11)).foregroundStyle(Ink.dim)
            Text(value).font(.machine(12)).foregroundStyle(Ink.ink)
        }
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = problem ?? data?.problem {
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.ui(12)).foregroundStyle(Ink.tile)
            }
            HStack(spacing: 6) {
                Circle().fill(stale || unavailable ? Ink.tile : Ink.moss).frame(width: 5, height: 5)
                Text(isPreview ? "Sample forecast for design preview" : stale || unavailable ? "Last known forecast · pull to retry" : freshness)
                    .font(.ui(11)).foregroundStyle(Ink.dim)
            }
            HStack {
                Link(destination: URL(string: "https://open-meteo.com/")!) {
                    HStack(spacing: 4) {
                        Text("Weather by Open-Meteo")
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                    }
                }.font(.ui(11)).foregroundStyle(Ink.dim)
                Spacer()
                Text(data?.utc_offset_s == nil ? "Times on this phone" : "Times local to \(place)")
                    .font(.ui(10)).foregroundStyle(Ink.dim).multilineTextAlignment(.trailing)
            }
        }.padding(.horizontal, 3)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 180)
            Text(loading ? "Finding your sky…" : "A window to outside.")
                .font(.displayMid(30)).foregroundStyle(Ink.ink)
            Text(loading ? "Reading the forecast from your wall." : "Choose a place to bring its changing sky into your room.")
                .font(.ui(15)).foregroundStyle(Ink.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background { WeatherAtmosphere(mood: WeatherMood(code: 1, day: true, golden: true)) }
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .accessibilityElement(children: .combine)
    }

    private var placeEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your place").font(.displayMid(21)).foregroundStyle(Ink.ink)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.dim)
                TextField("Town or city", text: $query)
                    .font(.ui(16)).foregroundStyle(Ink.ink)
                    .autocorrectionDisabled().submitLabel(.search)
                    .focused($placeFocused).onSubmit { setPlace() }
                    .accessibilityLabel("Town or city")
                if busy { ProgressView().tint(mood.accent) }
            }.padding(16)
                .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(placeFocused ? mood.accent : Ink.hairline, lineWidth: 1))
            Button { setPlace() } label: {
                HStack {
                    Text(busy ? "Finding your place…" : "Use this place")
                    Spacer(); Image(systemName: "arrow.right")
                }
                .font(.ui(15, .semibold)).padding(16)
                .foregroundStyle(typed.isEmpty || busy ? Ink.dim : Ink.ground)
                .background(typed.isEmpty || busy ? Ink.plaster : mood.accent, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(PressStyle()).disabled(typed.isEmpty || busy || isPreview)
            if let message = placeProblem ?? problem { Text(message).font(.ui(13)).foregroundStyle(Ink.tile) }
            if !wall.state.place.isEmpty {
                Text("Currently following \(wall.state.place)").font(.ui(12)).foregroundStyle(Ink.dim)
            }
        }
    }

    private func select(_ timestamp: Double?) {
        withAnimation(Motion.settle) { selectedHour = timestamp }
        Taps.detent(intensity: 0.35)
    }
    private func degrees(_ c: Double?) -> String {
        guard let c, c.isFinite else { return "—" }
        return "\(Int((isF ? c * 9 / 5 + 32 : c).rounded()))°"
    }
    private var windLabel: String {
        guard let kmh = data?.now?.wind_kmh else { return "—" }
        return "\(Int((isF ? kmh / 1.609344 : kmh).rounded()))"
    }
    private var rainLabel: String {
        guard let mm = data?.now?.precip_mm else { return "—" }
        return isF ? String(format: "%.2f in", mm / 25.4) : String(format: "%.1f mm", mm)
    }
    private func time(_ timestamp: Double?, format: String) -> String {
        guard let timestamp else { return "—" }
        let f = DateFormatter(); f.dateFormat = format
        if let offset = data?.utc_offset_s { f.timeZone = TimeZone(secondsFromGMT: offset) }
        return f.string(from: Date(timeIntervalSince1970: timestamp))
    }
    private var freshness: String {
        let minutes = max(0, (data?.age_s ?? 0) / 60)
        return minutes < 1 ? "Updated just now" : "Updated \(minutes) min ago"
    }
    private func daylightLabel(rise: Double, set: Double) -> String {
        let now = nowDate.timeIntervalSince1970
        if now < rise { return "Before sunrise" }
        if now > set { return "After sunset" }
        let mins = Int((set - now) / 60)
        return "\(mins / 60)h \(mins % 60)m of light left"
    }
    @MainActor private func refresh() async {
        guard !isPreview else { return }
        let host = wall.host
        let result = await WallWeather.read(host: host)
        guard !Task.isCancelled, wall.host == host else { return }
        loading = false
        if let result {
            report = result; lastReceived = .now; problem = nil
            if !((result.hours ?? []).contains { $0.t == selectedHour }) { selectedHour = nil }
        } else {
            problem = "The wall isn’t answering. Check its connection and pull to retry."
        }
    }
    private func setPlace() {
        guard !typed.isEmpty, !busy, !isPreview else { return }
        busy = true; placeProblem = nil; placeFocused = false
        let host = wall.host, place = typed
        Task { @MainActor in
            let (ok, why) = await WallWeather.setPlace(host: host, query: place)
            busy = false
            guard wall.host == host else { return }
            if ok {
                query = ""; selectedHour = nil; report = nil; loading = true
                editingPlace = false; Taps.commit(); await refresh()
            } else { placeProblem = why }
        }
    }
}

/// Small engraved instruments provide texture without inventing measurements.
private struct WeatherInstrument: View {
    let kind: Int
    let accent: Color
    let cloud: Double
    var body: some View {
        Canvas { ctx, size in
            if kind == 1 {
                for i in 0..<3 {
                    var path = Path()
                    let y = Double(i) * 7 + 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addCurve(to: CGPoint(x: size.width * (i == 1 ? 0.95 : 0.72), y: y - 2), control1: CGPoint(x: size.width * 0.3, y: y + 8), control2: CGPoint(x: size.width * 0.55, y: y - 10))
                    ctx.stroke(path, with: .color(accent.opacity(0.3 + Double(i) * 0.2)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
            } else {
                for i in 0..<26 {
                    let x = Double(i) / 25 * size.width
                    let active = kind == 2 ? Double(i) / 26 < cloud / 100 : true
                    let height: Double = kind == 3 ? 3 : i % 5 == 0 ? 18 : 10
                    let rect = CGRect(x: x, y: (24 - height) / 2, width: kind == 3 ? 2 : 1, height: height)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(active ? accent.opacity(kind == 2 ? 0.8 : 0.25 + Double(i) / 40) : Ink.hairline))
                }
            }
        }
    }
}
