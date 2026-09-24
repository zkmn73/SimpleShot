enum BuildVariant {
    #if OFFLINE
    static let isOffline = true
    static let displayName = "SimpleShot Offline"
    #else
    static let isOffline = false
    static let displayName = "SimpleShot"
    #endif
}
