import Foundation

/// Pure Swift parser/validator for ```map JSON specs rendered with native MapKit on macOS and iOS.
public struct ChatMapPin: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let lat: Double
    public let lon: Double
    public let detail: String?
    public let color: String?

    public init(id: String, label: String, lat: Double, lon: Double, detail: String? = nil, color: String? = nil) {
        self.id = id
        self.label = label
        self.lat = lat
        self.lon = lon
        self.detail = detail
        self.color = color
    }
}

public struct ChatMapCoord: Sendable, Equatable, Hashable {
    public let lat: Double
    public let lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

public struct ChatMapRoute: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let points: [ChatMapCoord]
    public let color: String?

    public init(id: String, label: String, points: [ChatMapCoord], color: String? = nil) {
        self.id = id
        self.label = label
        self.points = points
        self.color = color
    }

    /// Great-circle total route distance in kilometers (Haversine).
    public var distanceKm: Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(points.count - 1) {
            total += ChatMapSpec.haversineKm(points[i], points[i + 1])
        }
        return total
    }
}

public struct ChatMapBounds: Sendable, Equatable {
    public let centerLat: Double
    public let centerLon: Double
    public let latDelta: Double
    public let lonDelta: Double
}

public struct ChatMapSpec: Sendable, Equatable, Hashable {
    public enum Limits {
        public static let pins = 100
        public static let routes = 12
        public static let routePoints = 500
    }

    public let title: String?
    public let subtitle: String?
    public let pins: [ChatMapPin]
    public let routes: [ChatMapRoute]

    public init(title: String? = nil, subtitle: String? = nil, pins: [ChatMapPin] = [], routes: [ChatMapRoute] = []) {
        self.title = title
        self.subtitle = subtitle
        self.pins = pins
        self.routes = routes
    }

    public var totalRouteKm: Double {
        routes.reduce(0) { $0 + $1.distanceKm }
    }

    public var bounds: ChatMapBounds {
        var all: [ChatMapCoord] = pins.map { ChatMapCoord(lat: $0.lat, lon: $0.lon) }
        for r in routes { all.append(contentsOf: r.points) }
        guard let first = all.first else {
            return ChatMapBounds(centerLat: 37.7749, centerLon: -122.4194, latDelta: 0.2, lonDelta: 0.2)
        }
        var minLat = first.lat, maxLat = first.lat
        var minLon = first.lon, maxLon = first.lon
        for c in all {
            minLat = min(minLat, c.lat)
            maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon)
            maxLon = max(maxLon, c.lon)
        }
        let latSpan = max(0.03, (maxLat - minLat) * 1.45)
        let lonSpan = max(0.03, (maxLon - minLon) * 1.45)
        return ChatMapBounds(
            centerLat: (minLat + maxLat) / 2,
            centerLon: (minLon + maxLon) / 2,
            latDelta: min(160, latSpan),
            lonDelta: min(340, lonSpan)
        )
    }

    public static func haversineKm(_ a: ChatMapCoord, _ b: ChatMapCoord) -> Double {
        let r = 6371.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(max(0, h))))
    }

    public static func isMapFence(_ info: String?) -> Bool {
        let first = (info ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
        return first?.lowercased() == "map"
    }

    public static func parse(_ code: String) -> Result<ChatMapSpec, ChatChartError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root else {
            return .failure(ChatChartError("This map isn't valid JSON."))
        }

        func str(_ v: JSONValue?) -> String? {
            guard let s = v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        func num(_ v: JSONValue?) -> Double? {
            switch v {
            case .int(let i): return Double(i)
            case .double(let d): return d.isFinite ? d : nil
            default: return nil
            }
        }
        func validLatLon(_ lat: Double, _ lon: Double) -> Bool {
            lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
        }

        var pins: [ChatMapPin] = []
        if case .array(let rawPins) = obj["pins"] {
            if rawPins.count > Limits.pins {
                return .failure(ChatChartError("Map supports at most \(Limits.pins) pins."))
            }
            for (idx, item) in rawPins.enumerated() {
                guard case .object(let p) = item,
                      let lat = num(p["lat"] ?? p["latitude"]),
                      let lon = num(p["lon"] ?? p["lng"] ?? p["longitude"]),
                      validLatLon(lat, lon) else { continue }
                let label = str(p["label"] ?? p["name"] ?? p["title"]) ?? "Pin \(idx + 1)"
                pins.append(ChatMapPin(
                    id: "pin-\(idx)",
                    label: label,
                    lat: lat,
                    lon: lon,
                    detail: str(p["detail"] ?? p["note"] ?? p["description"]),
                    color: str(p["color"])
                ))
            }
        }

        var routes: [ChatMapRoute] = []
        if case .array(let rawRoutes) = obj["routes"] {
            if rawRoutes.count > Limits.routes {
                return .failure(ChatChartError("Map supports at most \(Limits.routes) routes."))
            }
            for (idx, item) in rawRoutes.enumerated() {
                guard case .object(let r) = item,
                      case .array(let rawPts) = r["points"] else { continue }
                var pts: [ChatMapCoord] = []
                for rawPt in rawPts.prefix(Limits.routePoints) {
                    if case .array(let pair) = rawPt, pair.count >= 2,
                       let lat = num(pair[0]), let lon = num(pair[1]),
                       validLatLon(lat, lon) {
                        pts.append(ChatMapCoord(lat: lat, lon: lon))
                    } else if case .object(let po) = rawPt,
                              let lat = num(po["lat"] ?? po["latitude"]),
                              let lon = num(po["lon"] ?? po["lng"] ?? po["longitude"]),
                              validLatLon(lat, lon) {
                        pts.append(ChatMapCoord(lat: lat, lon: lon))
                    }
                }
                if pts.count >= 2 {
                    routes.append(ChatMapRoute(
                        id: "route-\(idx)",
                        label: str(r["label"] ?? r["name"]) ?? "Route \(idx + 1)",
                        points: pts,
                        color: str(r["color"])
                    ))
                }
            }
        }

        guard !pins.isEmpty || !routes.isEmpty else {
            return .failure(ChatChartError("A map needs at least one valid pin (lat, lon) or route (2+ points)."))
        }

        return .success(ChatMapSpec(
            title: str(obj["title"]),
            subtitle: str(obj["subtitle"]),
            pins: pins,
            routes: routes
        ))
    }
}
