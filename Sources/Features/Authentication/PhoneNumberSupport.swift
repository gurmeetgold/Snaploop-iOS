import Foundation

struct PhoneCountry: Identifiable, Hashable, Sendable {
    let regionCode: String
    let name: String
    let callingCode: String
    var id: String { regionCode }

    static let supported: [PhoneCountry] = [
        .init(regionCode: "CA", name: "Canada", callingCode: "+1"),
        .init(regionCode: "US", name: "United States", callingCode: "+1"),
        .init(regionCode: "IN", name: "India", callingCode: "+91"),
        .init(regionCode: "GB", name: "United Kingdom", callingCode: "+44"),
        .init(regionCode: "AU", name: "Australia", callingCode: "+61"),
        .init(regionCode: "NZ", name: "New Zealand", callingCode: "+64"),
        .init(regionCode: "AE", name: "United Arab Emirates", callingCode: "+971"),
        .init(regionCode: "SG", name: "Singapore", callingCode: "+65"),
        .init(regionCode: "DE", name: "Germany", callingCode: "+49"),
        .init(regionCode: "FR", name: "France", callingCode: "+33"),
        .init(regionCode: "IT", name: "Italy", callingCode: "+39"),
        .init(regionCode: "ES", name: "Spain", callingCode: "+34")
    ]

    static var localeDefault: PhoneCountry {
        let region = Locale.current.region?.identifier.uppercased()
        return supported.first(where: { $0.regionCode == region })
            ?? supported.first(where: { $0.regionCode == "CA" })!
    }
}

enum PhoneNumberNormalizer {
    /// Conservative MVP normalizer. Firebase receives one canonical E.164-like
    /// string. Full international validation can later move to a dedicated
    /// phone-number library; we deliberately do not guess unfamiliar prefixes.
    static func e164(localInput: String, country: PhoneCountry) -> String? {
        let trimmed = localInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = trimmed.filter { $0.isNumber || $0 == "+" }

        if allowed.hasPrefix("+") {
            let digits = allowed.dropFirst().filter(\.isNumber)
            guard digits.count >= 8, digits.count <= 15 else { return nil }
            return "+" + digits
        }

        var digits = allowed.filter(\.isNumber)
        while digits.first == "0" { digits.removeFirst() }
        let callingDigits = country.callingCode.filter(\.isNumber)
        if (country.regionCode == "CA" || country.regionCode == "US"), digits.count == 11, digits.first == "1" {
            digits.removeFirst()
        }
        let combined = callingDigits + digits
        guard combined.count >= 8, combined.count <= 15 else { return nil }
        return "+" + combined
    }
}
