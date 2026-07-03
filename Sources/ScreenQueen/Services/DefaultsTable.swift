import Foundation

/// A tiny persisted table: string key → Codable value, one JSON blob per table in
/// UserDefaults. The shared shape of the small stores (layout profiles, size
/// calibrations, remembered names).
struct DefaultsTable<Value: Codable> {
    let key: String

    func all() -> [String: Value] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Value].self, from: data) else { return [:] }
        return decoded
    }

    func save(_ table: [String: Value]) {
        if let data = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    subscript(_ k: String) -> Value? {
        get { all()[k] }
        nonmutating set {
            var table = all()
            table[k] = newValue
            save(table)
        }
    }

    func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
