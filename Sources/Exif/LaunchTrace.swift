import Foundation

/// EXIF_TRACE=1: prints how long after the process started each launch step ends.
enum LaunchTrace {
    static let enabled = ProcessInfo.processInfo.environment["EXIF_TRACE"] != nil
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()
    static func mark(_ what: String) {
        if enabled { FileHandle.standardError.write(Data(String(format: "%.3f s  %@\n", Date().timeIntervalSince(processStart), what).utf8)) }
    }
}
