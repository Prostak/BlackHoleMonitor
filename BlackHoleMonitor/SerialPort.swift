import Darwin
import Foundation

enum SerialPortError: LocalizedError {
    case openFailed(String)
    case notOpen
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "Could not open \(path): \(String(cString: strerror(errno)))"
        case .notOpen:
            return "Serial port is not open"
        case .writeFailed:
            return "Serial write failed: \(String(cString: strerror(errno)))"
        }
    }
}

/// Write-focused serial port (115200 8N1) with tcdrain flush after each write.
final class SerialPort: @unchecked Sendable {
    static let defaultPath = "/dev/cu.usbserial-0001"

    private var fd: Int32 = -1
    private let lock = NSLock()

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    func open(path: String, baud: speed_t = speed_t(B115200)) throws {
        close()

        let opened = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard opened >= 0 else {
            throw SerialPortError.openFailed(path)
        }

        var options = termios()
        guard tcgetattr(opened, &options) == 0 else {
            Darwin.close(opened)
            throw SerialPortError.openFailed(path)
        }

        cfmakeraw(&options)
        cfsetspeed(&options, baud)

        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)

        options.c_cc.16 = 1 // VMIN
        options.c_cc.17 = 0 // VTIME

        guard tcsetattr(opened, TCSANOW, &options) == 0 else {
            Darwin.close(opened)
            throw SerialPortError.openFailed(path)
        }

        tcflush(opened, TCIOFLUSH)

        lock.lock()
        fd = opened
        lock.unlock()
    }

    func write(_ data: Data) throws {
        lock.lock()
        let currentFD = fd
        lock.unlock()

        guard currentFD >= 0 else { throw SerialPortError.notOpen }
        guard !data.isEmpty else { return }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(currentFD, base.advanced(by: offset), data.count - offset)
                guard written > 0 else { throw SerialPortError.writeFailed }
                offset += written
            }
        }

        guard tcdrain(currentFD) == 0 else { throw SerialPortError.writeFailed }
    }

    func writeBacktick() throws {
        try write(Data([0x60])) // ASCII `
    }

    func close() {
        lock.lock()
        let currentFD = fd
        fd = -1
        lock.unlock()

        if currentFD >= 0 {
            Darwin.close(currentFD)
        }
    }

    deinit {
        close()
    }
}
