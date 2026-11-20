import Foundation

// MARK: - 天气快照
struct WeatherSnapshot: Equatable {
    var cityName: String = ""
    var temperature: Double?
    var weatherCode: Int?
    var symbolName: String = "cloud.fill"
    var condition: String = ""
    var updatedAt: Date?

    var isAvailable: Bool { temperature != nil }
}

// MARK: - 天气服务
//
/// 数据源：Open-Meteo（https://open-meteo.com），免费、无需 API Key、非商业用途可用。
///
/// **为什么不用苹果天气**：
///   - WeatherKit 需要付费开发者账号 + `com.apple.developer.weatherkit` entitlement，
///     ad-hoc 签名无法启用；
///   - Weather.app 把数据存在自己的容器里（`~/Library/Containers/com.apple.weather`），
///     读取属于其他 App 的受保护数据，格式未公开，不能依赖。
///
/// 隐私：只把「城市中心的经纬度」发给 Open-Meteo，不发送任何设备标识。
final class WeatherService {
    struct City: Equatable {
        var name: String
        var latitude: Double
        var longitude: Double
    }

    private var task: Task<Void, Never>?

    // MARK: 查询天气

    func fetch(_ city: City, completion: @escaping (WeatherSnapshot) -> Void) {
        task?.cancel()
        task = Task {
            var snapshot = WeatherSnapshot(cityName: city.name)
            do {
                var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
                components?.queryItems = [
                    URLQueryItem(name: "latitude", value: String(city.latitude)),
                    URLQueryItem(name: "longitude", value: String(city.longitude)),
                    URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
                    URLQueryItem(name: "timezone", value: "auto"),
                ]
                guard let url = components?.url else { return }

                var request = URLRequest(url: url)
                request.timeoutInterval = 12

                let (data, _) = try await URLSession.shared.data(for: request)
                let decoded = try JSONDecoder().decode(ForecastResponse.self, from: data)

                if let current = decoded.current {
                    snapshot.temperature = current.temperature_2m
                    snapshot.weatherCode = current.weather_code
                    snapshot.symbolName = Self.symbol(for: current.weather_code)
                    snapshot.condition = Self.condition(for: current.weather_code)
                    snapshot.updatedAt = Date()
                }
            } catch {
                if ProcessInfo.processInfo.environment["DM_DEBUG_WEATHER"] != nil {
                    FileHandle.standardError.write(Data("WEATHER fetch error: \(error)\n".utf8))
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { completion(snapshot) }
        }
    }

    // MARK: 地名 → 经纬度

    func resolve(cityName: String, completion: @escaping (City?) -> Void) {
        task?.cancel()

        // 支持直接输入「纬度,经度」：有些县级地名在 Open-Meteo 的地名库里没有
        // （例如「临沭」返回 0 条），只能靠坐标精确指定。
        let pieces = cityName
            .replacingOccurrences(of: "，", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if pieces.count == 2,
           let latitude = Double(pieces[0]), let longitude = Double(pieces[1]),
           abs(latitude) <= 90, abs(longitude) <= 180 {
            let city = City(
                name: String(format: "%.2f,%.2f", latitude, longitude),
                latitude: latitude,
                longitude: longitude
            )
            completion(city)
            return
        }

        task = Task {
            var city: City?
            do {
                var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
                components?.queryItems = [
                    URLQueryItem(name: "name", value: cityName),
                    URLQueryItem(name: "count", value: "1"),
                    URLQueryItem(name: "language", value: "zh"),
                ]
                guard let url = components?.url else { return }

                var request = URLRequest(url: url)
                request.timeoutInterval = 12

                let (data, _) = try await URLSession.shared.data(for: request)
                let decoded = try JSONDecoder().decode(GeocodeResponse.self, from: data)
                if let first = decoded.results?.first {
                    city = City(
                        name: first.name,
                        latitude: first.latitude,
                        longitude: first.longitude
                    )
                }
            } catch {
                city = nil
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { completion(city) }
        }
    }

    /// 没设置过城市时，用时区名猜一个（Asia/Shanghai → Shanghai）
    static func guessCityFromTimeZone() -> String? {
        let identifier = TimeZone.current.identifier
        guard identifier.contains("/") else { return nil }
        guard let last = identifier.split(separator: "/").last else { return nil }
        let name = String(last).replacingOccurrences(of: "_", with: " ")
        // 纯缩写（如 CDT、GMT）没法当地名搜
        guard name.count >= 3, !name.hasSuffix("GMT"), !name.hasSuffix("UTC") else { return nil }
        return name
    }

    // MARK: WMO 天气码 → 图标 / 文字

    static func symbol(for code: Int?) -> String {
        guard let code else { return "cloud.fill" }
        switch code {
        case 0: return "sun.max.fill"
        case 1: return "sun.max.fill"
        case 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57: return "cloud.sleet.fill"
        case 61, 63, 65: return "cloud.rain.fill"
        case 66, 67: return "cloud.sleet.fill"
        case 71, 73, 75, 77: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func condition(for code: Int?) -> String {
        guard let code else { return "" }
        switch code {
        case 0: return "晴"
        case 1: return "晴间多云"
        case 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻雨"
        case 61: return "小雨"
        case 63: return "中雨"
        case 65: return "大雨"
        case 66, 67: return "冻雨"
        case 71, 73, 75, 77: return "雪"
        case 80, 81: return "阵雨"
        case 82: return "强阵雨"
        case 85, 86: return "阵雪"
        case 95: return "雷阵雨"
        case 96, 99: return "雷阵雨伴冰雹"
        default: return ""
        }
    }

    // MARK: 响应结构

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double?
            let weather_code: Int?
        }
        let current: Current?
    }

    private struct GeocodeResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
        }
        let results: [Result]?
    }
}
