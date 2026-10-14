/// Console logging that exists only in debug builds. The message is an
/// autoclosure, so release builds don't even evaluate the interpolation —
/// nothing about a conversation (or an error that might carry a URL) is
/// formatted, let alone printed, in a shipped app.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
