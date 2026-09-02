enum SettingsSaveHandler {
    @discardableResult
    static func perform(save: () -> Bool, close: () -> Void) -> Bool {
        let saved = save()
        if saved {
            close()
        }
        return saved
    }
}
