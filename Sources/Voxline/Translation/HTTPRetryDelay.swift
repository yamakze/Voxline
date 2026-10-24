import Foundation

/// Shared HTTP backoff calculation; each operation owns retry eligibility and its attempt limit.
enum HTTPRetryDelay {
    static func seconds(retryAfter: String?, attempt: Int, now: Date = .now, jitter: Double = 0) -> TimeInterval {
        if let value = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
               let seconds = Double(value), seconds.isFinite { return seconds }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return [5.0, 15.0, 45.0][min(max(attempt - 1, 0), 2)] * (1 + jitter * 0.2)
    }
}
