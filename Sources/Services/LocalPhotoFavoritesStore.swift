import Foundation

/// MVP favorite state is device-local and account-scoped. It contains only
/// deterministic match IDs — never image data or face descriptors.
public enum LocalPhotoFavoritesStore {
    private static let prefix = "snaploop.favorites."

    public static func load(userId: String) -> Set<String> {
        guard let values = UserDefaults.standard.array(forKey: key(userId)) as? [String] else {
            return []
        }
        return Set(values)
    }

    public static func set(_ favorite: Bool, matchId: String, userId: String) {
        var values = load(userId: userId)
        if favorite { values.insert(matchId) }
        else { values.remove(matchId) }
        UserDefaults.standard.set(Array(values).sorted(), forKey: key(userId))
    }

    private static func key(_ userId: String) -> String {
        prefix + Data(userId.utf8).base64EncodedString()
    }
}
