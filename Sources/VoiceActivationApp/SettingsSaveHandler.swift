@MainActor
enum SettingsSaveHandler {
    @discardableResult
    static func perform(save: () async -> Bool, close: () -> Void) async -> Bool {
        let saved = await save()
        if saved {
            close()
        }
        return saved
    }
}
