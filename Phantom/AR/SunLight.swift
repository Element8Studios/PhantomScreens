import ARKit
import CoreLocation
import RealityKit
import UIKit

/// Where the sun is in the sky.
enum SunPosition {
    /// Azimuth (degrees clockwise from true north) and elevation (degrees
    /// above the horizon) for a date and location. Accurate to well under a
    /// degree, which is plenty for shadow direction.
    static func compute(date: Date, latitude: Double, longitude: Double) -> (azimuth: Double, elevation: Double) {
        let rad = Double.pi / 180
        let julian = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let n = julian - 2_451_545.0

        let meanLongitude = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let anomaly = ((357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)) * rad
        let eclipticLongitude = (meanLongitude + 1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)) * rad
        let obliquity = (23.439 - 0.0000004 * n) * rad

        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))

        var siderealHours = (18.697374558 + 24.06570982441908 * n).truncatingRemainder(dividingBy: 24)
        if siderealHours < 0 { siderealHours += 24 }
        let hourAngle = (siderealHours * 15 + longitude) * rad - rightAscension

        let lat = latitude * rad
        let elevation = asin(sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle))
        var azimuth = atan2(-sin(hourAngle), cos(lat) * tan(declination) - sin(lat) * cos(hourAngle))
        if azimuth < 0 { azimuth += 2 * Double.pi }
        return (azimuth / rad, elevation / rad)
    }

    /// Unit vector toward the sun in ARKit's gravity-and-heading world
    /// (+x east, +y up, −z north).
    static func direction(azimuth: Double, elevation: Double) -> SIMD3<Float> {
        let a = azimuth * .pi / 180
        let e = elevation * .pi / 180
        return SIMD3(Float(sin(a) * cos(e)), Float(sin(e)), Float(-cos(a) * cos(e)))
    }
}

/// Whether the opening is in direct sun.
enum SunExposure: String, CaseIterable, Identifiable {
    case auto, sun, shade
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .sun: return "In sun"
        case .shade: return "In shade"
        }
    }
}

/// One-shot location for the sun calculation.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var location: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension PhantomSession {
    /// Aims the key light along the real sun. Returns false when the sun
    /// can't be used (no location, sun below the horizon), so the caller
    /// falls back to the indoor light.
    func updateSunLight(_ light: DirectionalLight, level: Float) -> Bool {
        guard sunMode, let location = locationProvider.location, let opening = fittedOpening else { return false }
        let sun = SunPosition.compute(date: Date(), latitude: location.coordinate.latitude,
                                      longitude: location.coordinate.longitude)
        guard sun.elevation > 1 else { return false }
        let toSun = SunPosition.direction(azimuth: sun.azimuth, elevation: sun.elevation)

        let litByGeometry = dot(toSun, opening.normal) > 0.05
        let inSun: Bool
        switch sunExposure {
        case .auto: inSun = litByGeometry
        case .sun: inSun = true
        case .shade: inSun = false
        }

        light.look(at: opening.center, from: opening.center + toSun * 4, relativeTo: nil)
        light.light.color = .white
        light.light.intensity = (inSun ? 9000 : 350) * level * pow(2, exposureOffset)
        light.shadow = inSun ? DirectionalLightComponent.Shadow(maximumDistance: 6, depthBias: 3) : nil
        return true
    }
}
