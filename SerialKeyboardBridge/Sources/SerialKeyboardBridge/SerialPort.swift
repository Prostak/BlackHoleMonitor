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

final class SerialPort: @unchecked Sendable {
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "SerialKeyboardBridge.read")

    var onReceive: (@Sendable (Data) -> Void)?

    var isOpen: Bool { fd >= 0 }

    func open(path: String, baud: speed_t = speed_t(B115200)) throws {
        close()

        let opened = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard opened >= 0 else {
            throw SerialPortError.openFailed(path)
        }
        fd = opened

        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            close()
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

        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            close()
            throw SerialPortError.openFailed(path)
        }

        tcflush(fd, TCIOFLUSH)
        startReading()
    }

    func write(_ data: Data) throws {
        guard fd >= 0 else { throw SerialPortError.notOpen }
        guard !data.isEmpty else { return }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                guard written > 0 else { throw SerialPortError.writeFailed }
                offset += written
            }
        }

        guard tcdrain(fd) == 0 else { throw SerialPortError.writeFailed }
    }

    func close() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private func startReading() {
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        readSource?.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: 256)
            let count = read(self.fd, &buffer, buffer.count)
            guard count > 0 else { return }

            let data = Data(buffer.prefix(count))
            self.onReceive?(data)
        }
        readSource?.setCancelHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            Darwin.close(self.fd)
            self.fd = -1
        }
        readSource?.resume()
    }

    deinit {
        close()
    }
}
