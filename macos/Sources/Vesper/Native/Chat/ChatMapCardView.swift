import MapKit
import SwiftUI
import VesperCore

/// Native MapKit card for ```map fenced blocks (pins, routes, auto-fit region, distance pill,
/// pin focus chips, and expandable lightbox).
struct ChatMapCardView: View {
    @Environment(\.vesperTheme) private var theme

    let spec: ChatMapSpec

    @State private var cameraPosition: MapCameraPosition
    @State private var selectedPinId: String?
    @State private var showLightbox = false

    init(spec: ChatMapSpec) {
        self.spec = spec
        let b = spec.bounds
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: b.centerLat, longitude: b.centerLon),
            span: MKCoordinateSpan(latitudeDelta: b.latDelta, longitudeDelta: b.lonDelta)
        )
        _cameraPosition = State(initialValue: .region(region))
    }

    var body: some View {
        let p = theme.palette
        let subtitle: String? = {
            if let s = spec.subtitle, !s.isEmpty { return s }
            var parts: [String] = []
            if !spec.pins.isEmpty {
                parts.append("\(spec.pins.count) \(spec.pins.count == 1 ? "pin" : "pins")")
            }
            if spec.totalRouteKm > 0.05 {
                let km = spec.totalRouteKm
                let mi = km * 0.621371
                parts.append(String(format: "%.1f km (%.1f mi)", km, mi))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }()

        ChatVizCard(
            icon: "map",
            title: spec.title ?? "Map",
            subtitle: subtitle,
            supportsLightbox: true,
            isLightboxPresented: $showLightbox
        ) {
            Button("Fit") {
                resetCamera()
            }
            .buttonStyle(.plain)
            .font(.system(size: theme.pointSize(.small)))
            .foregroundStyle(p.secondaryText)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                mapView(height: 290)
                if !spec.pins.isEmpty {
                    Rectangle().fill(p.rowBorder).frame(height: 1)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(spec.pins) { pin in
                                let active = selectedPinId == pin.id
                                Button {
                                    selectedPinId = pin.id
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        cameraPosition = .region(MKCoordinateRegion(
                                            center: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon),
                                            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
                                        ))
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "mappin.circle.fill")
                                            .imageScale(.small)
                                            .foregroundStyle(pinColor(pin))
                                        Text(pin.label)
                                            .font(.system(size: theme.pointSize(.micro), weight: active ? .semibold : .medium))
                                            .foregroundStyle(active ? p.accent : p.text)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(active ? p.selected : p.surface, in: Capsule())
                                    .overlay(Capsule().stroke(active ? p.accent : p.border))
                                }
                                .buttonStyle(.plain)
                                .help(pin.detail ?? "\(pin.lat), \(pin.lon)")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .sheet(isPresented: $showLightbox) {
            ChatLightboxSheet(title: spec.title ?? "Map", subtitle: subtitle) {
                mapView(height: 520)
            }
        }
    }

    private func mapView(height: CGFloat) -> some View {
        let viz = ChatVizPalette(theme: theme)
        return Map(position: $cameraPosition) {
            ForEach(spec.pins) { pin in
                Marker(pin.label, coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon))
                    .tint(pinColor(pin))
            }
            ForEach(Array(spec.routes.enumerated()), id: \.element.id) { idx, route in
                let coords = route.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                MapPolyline(coordinates: coords)
                    .stroke(routeColor(route, index: idx, viz: viz), lineWidth: 3)
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .frame(height: height)
    }

    private func pinColor(_ pin: ChatMapPin) -> Color {
        if let hex = pin.color, let c = Color(hex: hex) { return c }
        return theme.palette.accent
    }

    private func routeColor(_ route: ChatMapRoute, index: Int, viz: ChatVizPalette) -> Color {
        if let hex = route.color, let c = Color(hex: hex) { return c }
        return viz.seriesColor(at: index)
    }

    private func resetCamera() {
        let b = spec.bounds
        selectedPinId = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: b.centerLat, longitude: b.centerLon),
                span: MKCoordinateSpan(latitudeDelta: b.latDelta, longitudeDelta: b.lonDelta)
            ))
        }
    }
}
