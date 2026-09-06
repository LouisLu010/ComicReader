#if DEBUG
/// 仅由明确的 privacy-locked UI 夹具注入；Release 不编译此类型。
@MainActor
final class UITestDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    func authenticate() async -> Bool {
        await Task.yield()
        return true
    }
    func cancel() {}
}
#endif
