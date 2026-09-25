import Foundation

/// App 與 Share Extension 共用的 App Group。
///
/// 識別碼由 xcconfig 的 `APP_GROUP_ID` 寫入各 target 的 Info.plist（`AppGroupIdentifier`），
/// 讓不同開發者可用自己的 bundle prefix 簽章。
public enum AppGroup {
    public static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
    }

    public static var containerURL: URL? {
        guard let identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Keychain 共用群組：只有真的拿到 App Group 權限時才用；沒有（NoAppGroup 簽章）時
    /// 用 App 自己的 Keychain，否則登入狀態會存不進去（審查）。
    public static var keychainAccessGroup: String? {
        containerURL == nil ? nil : identifier
    }
}
