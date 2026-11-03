import Foundation
@preconcurrency import IOBluetooth

let logPath = ProcessInfo.processInfo.environment["DIVOOM_LOG"] ?? "/tmp/divoom-send.log"
let logFH: FileHandle? = {
    let fd = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: false) : nil
}()
func log(_ s: String) {
    let line = s + "\n"
    FileHandle.standardOutput.write(Data(line.utf8))
    logFH?.write(Data(line.utf8))
}

func ioReturnName(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess:         return "kIOReturnSuccess"
    case kIOReturnError:           return "kIOReturnError (generic: peer refused or already owns the channel)"
    case kIOReturnBusy:            return "kIOReturnBusy (channel in use)"
    case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess (another client owns the channel)"
    case kIOReturnNoDevice:        return "kIOReturnNoDevice (device not reachable)"
    case kIOReturnNotOpen:         return "kIOReturnNotOpen"
    case kIOReturnTimeout:         return "kIOReturnTimeout (device did not answer in time)"
    case kIOReturnOffline:         return "kIOReturnOffline (device asleep or out of range)"
    case kIOReturnNotPermitted:    return "kIOReturnNotPermitted (macOS Bluetooth permission denied?)"
    case kIOReturnNotAttached:     return "kIOReturnNotAttached (device not paired?)"
    case kIOReturnNotResponding:   return "kIOReturnNotResponding"
    case kIOReturnAborted:         return "kIOReturnAborted"
    case kIOReturnNoResources:     return "kIOReturnNoResources"
    case kIOReturnBadArgument:     return "kIOReturnBadArgument (bad channel number?)"
    default:                       return "unrecognized IOKit code"
    }
}

func ioReturnDesc(_ r: IOReturn) -> String {
    return String(format: "0x%08x", UInt32(bitPattern: r)) + " " + ioReturnName(r)
}

func fatal(_ message: String, code: Int32) -> Never {
    log("FATAL: " + message)
    exit(code)
}

func checksum(_ payload: [UInt8]) -> [UInt8] {
    let sum = payload.reduce(0) { $0 + Int($1) }
    return [UInt8(sum & 0xFF), UInt8((sum >> 8) & 0xFF)]
}

func escapePayload(_ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    for b in payload {
        if b >= 0x01 && b <= 0x03 {
            out.append(0x03)
            out.append(b + 0x03)
        } else {
            out.append(b)
        }
    }
    return out
}

func frame(command: UInt8, args: [UInt8]) -> [UInt8] {
    let length = args.count + 3
    var payload: [UInt8] = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), command]
    payload += args
    let cs = checksum(payload)
    let body = payload + cs
    let finalBody = (ProcessInfo.processInfo.environment["DIVOOM_ESCAPE"] == "1") ? escapePayload(body) : body
    return [0x01] + finalBody + [0x02]
}

func framesForFace(_ id: UInt8) -> [[UInt8]] {
    return [
        frame(command: 0x45, args: [0x05]),
        frame(command: 0xbd, args: [0x17, id]),
    ]
}

func framesForBrightness(_ pct: UInt8) -> [[UInt8]] {
    let opHex = ProcessInfo.processInfo.environment["DIVOOM_BRIGHT_OP"] ?? "32"
    let op = UInt8(opHex, radix: 16) ?? 0x32
    return [frame(command: op, args: [pct])]
}

func framesForRaw(_ hexString: String) -> [[UInt8]] {
    let bytes = hexString.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    guard !bytes.isEmpty else { return [] }
    return [frame(command: bytes[0], args: Array(bytes.dropFirst()))]
}

func framesForRawFile(_ path: String) -> [[UInt8]]? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        log("rawfile: cannot read \(path)")
        return nil
    }
    var frames: [[UInt8]] = []
    for rawLine in content.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        let hexPart = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
        let built = framesForRaw(hexPart)
        if built.isEmpty {
            log("rawfile: bad hex line: \(line)")
            return nil
        }
        frames += built
    }
    return frames
}

func framesForJson(_ jsonString: String) -> [[UInt8]] {
    let jsonBytes = Array(jsonString.utf8)
    return [frame(command: 0x01, args: jsonBytes)]
}

func jsonString(_ object: [String: Any]) -> String? {
    guard
        let data = try? JSONSerialization.data(withJSONObject: object, options: []),
        let json = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return json
}

func framesForCustomSwitch(fileId: String, deviceId: Int, pageIndex: Int, customId: Int, cleanFirst: Bool) -> [[UInt8]] {
    let set: [String: Any] = [
        "Command": "Channel/SetCustom",
        "CustomPageIndex": pageIndex,
        "CustomId": customId,
        "FileId": fileId,
        "ClockId": 0,
        "ParentClockId": 0,
        "ParentItemId": "",
        "LcdIndependence": 0,
        "LcdIndex": 0,
        "Language": "en",
        "DeviceId": deviceId,
    ]
    guard let setJson = jsonString(set) else {
        return []
    }
    if !cleanFirst {
        return framesForJson(setJson)
    }
    let clean: [String: Any] = [
        "Command": "Channel/CleanCustom",
        "CustomPageIndex": pageIndex,
        "ClockId": 0,
        "ParentClockId": 0,
        "ParentItemId": "",
        "DeviceId": deviceId,
    ]
    guard let cleanJson = jsonString(clean) else {
        return []
    }
    return framesForJson(cleanJson) + framesForJson(setJson)
}

func framesForHandshake() -> [[UInt8]] {
    let brightnessArg = ProcessInfo.processInfo.environment["DIVOOM_HANDSHAKE_BRIGHTNESS"] ?? "100"
    let brightness = min(100, UInt8(brightnessArg) ?? 100)
    let commands: [[String: Any]] = [
        ["Command": "Channel/SetBrightness", "Brightness": Int(brightness)],
        ["Command": "Sys/DevUpdateConf"],
        ["Command": "Tomato/GetList"],
        ["Command": "Channel/DeviceGetMyClock"],
        ["Command": "TimePlan/GetPlan"],
        ["Command": "Device/GetFileVersion"],
    ]
    return commands.compactMap { jsonString($0) }.map { frame(command: 0x01, args: Array($0.utf8)) }
}

func sendHandshake(on channel: IOBluetoothRFCOMMChannel) {
    guard ProcessInfo.processInfo.environment["DIVOOM_HANDSHAKE"] == "1" else {
        log("handshake: skipped (opt-in only, set DIVOOM_HANDSHAKE=1 -- see plan.md)")
        return
    }
    let delayMs = Int(ProcessInfo.processInfo.environment["DIVOOM_HANDSHAKE_DELAY_MS"] ?? "150") ?? 150
    log("handshake: sending boot-time init sequence (mirrors official app connect)")
    sendFrames(framesForHandshake(), on: channel, delayMs: delayMs)
}

func framesForClock() -> [[UInt8]] {
    return [frame(command: 0x45, args: [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])]
}

func hex(_ bytes: [UInt8]) -> String {
    return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func framedPackets(from bytes: [UInt8]) -> [[UInt8]] {
    var packets: [[UInt8]] = []
    var i = 0
    while i + 3 < bytes.count {
        guard bytes[i] == 0x01 else {
            i += 1
            continue
        }
        let length = Int(bytes[i + 1]) | (Int(bytes[i + 2]) << 8)
        let total = length + 4
        guard length >= 3, total > 0 else {
            i += 1
            continue
        }
        guard i + total <= bytes.count else {
            break
        }
        guard bytes[i + total - 1] == 0x02 else {
            i += 1
            continue
        }
        packets.append(Array(bytes[i..<(i + total)]))
        i += total
    }
    return packets
}

func intValue(_ value: Any?) -> Int? {
    if let n = value as? NSNumber {
        return n.intValue
    }
    if let s = value as? String {
        return Int(s)
    }
    return nil
}

final class AutoCustomResponder {
    private struct CustomFile {
        let fileId: String
        let startFrame: [UInt8]
        let chunkFrames: [[UInt8]]
    }

    private let filesById: [String: CustomFile]
    private let defaultFileId: String
    private let deviceId: Int
    private let fileDelayMs: Int
    private let queue = DispatchQueue(label: "divoom.autocustom")
    private var sendingChunks = false
    private var activeFileId: String?

    convenience init?(fileId: String, rawfilePath: String, deviceId: Int, fileDelayMs: Int) {
        self.init(entries: [(fileId, rawfilePath)], deviceId: deviceId, fileDelayMs: fileDelayMs)
    }

    init?(entries: [(String, String)], deviceId: Int, fileDelayMs: Int) {
        var files: [String: CustomFile] = [:]
        var firstFileId: String?
        for (fileId, rawfilePath) in entries {
            guard !fileId.isEmpty else {
                log("autocustom: empty fileId")
                return nil
            }
            guard files[fileId] == nil else {
                log("autocustom: duplicate fileId \(fileId)")
                return nil
            }
            guard let frames = framesForRawFile(rawfilePath), !frames.isEmpty else {
                log("autocustom: cannot load rawfile \(rawfilePath)")
                return nil
            }
            let file = CustomFile(
                fileId: fileId,
                startFrame: frames[0],
                chunkFrames: Array(frames.dropFirst())
            )
            files[fileId] = file
            if firstFileId == nil {
                firstFileId = fileId
            }
            log("autocustom: loaded fileId=\(fileId) start=1 chunks=\(file.chunkFrames.count)")
        }
        guard let defaultFileId = firstFileId, !files.isEmpty else {
            log("autocustom: no files configured")
            return nil
        }
        self.filesById = files
        self.defaultFileId = defaultFileId
        self.deviceId = deviceId
        self.fileDelayMs = fileDelayMs
        log("autocustom: enabled files=\(files.count) default=\(defaultFileId) delay=\(fileDelayMs)ms deviceId=\(deviceId)")
    }

    func handleBytes(_ bytes: [UInt8], on channel: IOBluetoothRFCOMMChannel) {
        for packet in framedPackets(from: bytes) {
            handlePacket(packet, on: channel)
        }
    }

    private func handlePacket(_ packet: [UInt8], on channel: IOBluetoothRFCOMMChannel) {
        guard packet.count >= 8, packet[3] == 0x04 else { return }

        if packet[4] == 0xbd, packet[5] == 0x55, packet[6] == 0x30 {
            let requestedLen = Int(packet[7])
            guard packet.count >= 8 + requestedLen + 3 else { return }
            let requestedId = String(bytes: packet[8..<(8 + requestedLen)], encoding: .utf8) ?? ""
            guard let file = filesById[requestedId] else {
                log("autocustom: ignoring BD30 for unexpected fileId=\(requestedId)")
                return
            }
            sendStart(file, on: channel, reason: "BD30")
            return
        }

        if packet[4] == 0xbe, packet[5] == 0x55 {
            let status = packet[6]
            if status == 0 {
                sendChunks(on: channel, reason: "BE00")
            } else if status == 1, packet.count >= 10 {
                let index = Int(packet[7]) | (Int(packet[8]) << 8)
                resendChunk(index, on: channel)
            } else {
                log("autocustom: unhandled BE status=\(status)")
            }
            return
        }

        if packet[4] == 0x01, packet[5] == 0x55 {
            let end = packet.count - 3
            guard end > 6 else { return }
            let jsonBytes = Array(packet[6..<end])
            guard
                let json = try? JSONSerialization.jsonObject(with: Data(jsonBytes)),
                let obj = json as? [String: Any],
                let command = obj["Command"] as? String
            else {
                return
            }
            handleJson(command: command, object: obj, on: channel)
        }
    }

    private func handleJson(command: String, object: [String: Any], on channel: IOBluetoothRFCOMMChannel) {
        switch command {
        case "Channel/GetOneCustom":
            let customId = intValue(object["CustomId"]) ?? 0
            let pageIndex = intValue(object["CustomPageIndex"]) ?? 0
            log("autocustom: reply Channel/GetOneCustom page=\(pageIndex) custom=\(customId)")
            sendJson([
                "Command": "Channel/GetOneCustom",
                "ReturnCode": 0,
                "ReturnMessage": "",
                "DeviceId": deviceId,
                "CustomPageIndex": pageIndex,
                "CustomId": customId,
                "FileId": jsonFileId(object),
            ], on: channel)

        case "Device/GetFileVersion":
            let fileType = intValue(object["FileType"]) ?? 1
            log("autocustom: reply Device/GetFileVersion type=\(fileType)")
            sendJson([
                "Command": "Device/GetFileVersion",
                "ReturnCode": 0,
                "ReturnMessage": "",
                "DeviceId": deviceId,
                "FileType": fileType,
                "FileId": jsonFileId(object),
                "Version": 1,
            ], on: channel)

        default:
            break
        }
    }

    private func jsonFileId(_ object: [String: Any]) -> String {
        if let fileId = object["FileId"] as? String, filesById[fileId] != nil {
            return fileId
        }
        return defaultFileId
    }

    private func sendJson(_ object: [String: Any], on channel: IOBluetoothRFCOMMChannel) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: []),
            let json = String(data: data, encoding: .utf8)
        else {
            log("autocustom: failed to encode JSON response")
            return
        }
        sendOnMain(framesForJson(json), on: channel, delayMs: 0)
    }

    private func sendStart(_ file: CustomFile, on channel: IOBluetoothRFCOMMChannel, reason: String) {
        queue.async {
            if self.sendingChunks {
                log("autocustom: ignoring start request while chunks are in flight")
                return
            }
            self.activeFileId = file.fileId
            log("autocustom: sending start for \(file.fileId) reason=\(reason)")
            self.sendOnMain([file.startFrame], on: channel, delayMs: 0)
        }
    }

    private func sendChunks(on channel: IOBluetoothRFCOMMChannel, reason: String) {
        queue.async {
            if self.sendingChunks {
                log("autocustom: chunks already in flight")
                return
            }
            guard
                let activeFileId = self.activeFileId,
                let file = self.filesById[activeFileId]
            else {
                log("autocustom: BE00 without active file")
                return
            }
            self.sendingChunks = true
            log("autocustom: sending \(file.chunkFrames.count) chunks for \(file.fileId) reason=\(reason)")
            self.sendOnMain(file.chunkFrames, on: channel, delayMs: self.fileDelayMs)
            self.sendingChunks = false
        }
    }

    private func resendChunk(_ index: Int, on channel: IOBluetoothRFCOMMChannel) {
        queue.async {
            guard
                let activeFileId = self.activeFileId,
                let file = self.filesById[activeFileId]
            else {
                log("autocustom: resend without active file")
                return
            }
            guard index >= 0, index < file.chunkFrames.count else {
                log("autocustom: chunk resend out of range index=\(index)")
                return
            }
            log("autocustom: resending chunk \(index) for \(file.fileId)")
            self.sendOnMain([file.chunkFrames[index]], on: channel, delayMs: 0)
        }
    }

    private func sendOnMain(_ frames: [[UInt8]], on channel: IOBluetoothRFCOMMChannel, delayMs: Int) {
        if Thread.isMainThread {
            sendFrames(frames, on: channel, delayMs: delayMs)
            return
        }
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            sendFrames(frames, on: channel, delayMs: delayMs)
            sema.signal()
        }
        sema.wait()
    }
}

var recentTxFrames: [[UInt8]] = []
var echoWarningEmitted = false
var daemonShuttingDown = false

func noteTx(_ frame: [UInt8]) {
    recentTxFrames.append(frame)
    if recentTxFrames.count > 8 { recentTxFrames.removeFirst(recentTxFrames.count - 8) }
}

func noteEcho(_ bytes: [UInt8]) {
    guard !echoWarningEmitted, bytes.count > 4 else { return }
    guard recentTxFrames.contains(bytes) else { return }
    echoWarningEmitted = true
    log("WARNING: the device echoed one of our own frames back byte-for-byte.")
    log("WARNING: this RFCOMM channel is a LOOPBACK, not the command channel --")
    log("WARNING: commands sent here are never executed. Expected channel: 1.")
}

final class Delegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let autoCustom: AutoCustomResponder?

    init(autoCustom: AutoCustomResponder? = nil) {
        self.autoCustom = autoCustom
    }

    @objc func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        log("delegate: openComplete status=\(ioReturnDesc(error))")
    }
    @objc func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let buf = UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength)
        let bytes = Array(buf)
        let hexStr = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        log("delegate: rx[\(dataLength)]: \(hexStr)")
        noteEcho(bytes)
        autoCustom?.handleBytes(bytes, on: rfcommChannel)
    }
    @objc func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        if daemonShuttingDown {
            log("delegate: channel closed (expected, shutting down)")
            return
        }
        fatal("the device closed the RFCOMM channel. Nothing more can be sent on it.", code: 6)
    }
    @objc func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        log("delegate: writeComplete status=\(ioReturnDesc(error))")
    }
    @objc func rfcommChannelQueueSpaceAvailable(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
    @objc func rfcommChannelControlSignalsChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
    @objc func rfcommChannelFlowControlChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
}

let argv = CommandLine.arguments
func usage() -> Never {
    log("""
    Usage:
      divoom-send <MAC> face <id>
      divoom-send <MAC> brightness <0-100>
      divoom-send <MAC> clock
      divoom-send <MAC> raw <hex bytes...>
      divoom-send <MAC> rawfile <path> [delay_ms]
      divoom-send <MAC> json <json>         # send one SPP_JSON command
      divoom-send <MAC> shell               # stay connected, read commands from stdin
      divoom-send <MAC> daemon               # hold the channel, read commands from the FIFO
      divoom-send <MAC> daemon-custom <fileId> <rawfile> <deviceId> [delay_ms]
      divoom-send <MAC> daemon-custom-multi <deviceId> <delay_ms> <fileId=rawfile>...

    Env: DIVOOM_PORT, DIVOOM_REQUIRE_PORT, DIVOOM_LOG, DIVOOM_FIFO, DIVOOM_GAP_MS,
         DIVOOM_FRAME_DELAY_MS, DIVOOM_HOLD_MS, DIVOOM_QUIT_DWELL_MS,
         DIVOOM_BRIGHT_OP, DIVOOM_ESCAPE, DIVOOM_DEVICE_ID,
         DIVOOM_CUSTOM_SWITCH_MODE, DIVOOM_CUSTOM_SWITCH_DELAY_MS

    Shell mode commands (one per line): 'face <id>', 'brightness <n>',
    'clock', 'raw <hex>', 'rawfile <path> [delay_ms]',
    'custom <fileId> [deviceId] [pageIndex] [customId] [clean|replace]',
    'quit'. Holding the BT channel open between commands
    eliminates connect/disconnect notifications.
    """)
    exit(64)
}

struct ParsedCommand {
    let frames: [[UInt8]]
    let delayMs: Int
}

func parseCommand(_ tokens: [String]) -> ParsedCommand? {
    guard let verb = tokens.first else { return nil }
    let rest = Array(tokens.dropFirst())
    let defaultDelayMs = Int(ProcessInfo.processInfo.environment["DIVOOM_FRAME_DELAY_MS"] ?? "150") ?? 150
    switch verb {
    case "face":
        guard rest.count == 1, let id = UInt8(rest[0]) else { return nil }
        return ParsedCommand(frames: framesForFace(id), delayMs: defaultDelayMs)
    case "brightness":
        guard rest.count == 1, let pct = UInt8(rest[0]), pct <= 100 else { return nil }
        return ParsedCommand(frames: framesForBrightness(pct), delayMs: defaultDelayMs)
    case "clock":
        return ParsedCommand(frames: framesForClock(), delayMs: defaultDelayMs)
    case "raw":
        guard !rest.isEmpty else { return nil }
        return ParsedCommand(frames: framesForRaw(rest.joined(separator: " ")), delayMs: defaultDelayMs)
    case "rawfile":
        guard rest.count == 1 || rest.count == 2 else { return nil }
        guard let frames = framesForRawFile(rest[0]), !frames.isEmpty else { return nil }
        let delayMs = rest.count == 2 ? (Int(rest[1]) ?? defaultDelayMs) : 40
        return ParsedCommand(frames: frames, delayMs: max(0, delayMs))
    case "json":
        guard !rest.isEmpty else { return nil }
        return ParsedCommand(frames: framesForJson(rest.joined(separator: " ")), delayMs: defaultDelayMs)
    case "custom":
        guard rest.count >= 1, rest.count <= 5 else { return nil }
        let deviceId = rest.count >= 2
            ? (Int(rest[1]) ?? Int(ProcessInfo.processInfo.environment["DIVOOM_DEVICE_ID"] ?? "0") ?? 0)
            : (Int(ProcessInfo.processInfo.environment["DIVOOM_DEVICE_ID"] ?? "0") ?? 0)
        guard deviceId > 0 else { return nil }
        let pageIndex = rest.count >= 3 ? (Int(rest[2]) ?? 0) : 0
        let customId = rest.count >= 4 ? (Int(rest[3]) ?? 0) : 0
        let mode = rest.count >= 5 ? rest[4] : (ProcessInfo.processInfo.environment["DIVOOM_CUSTOM_SWITCH_MODE"] ?? "clean")
        guard mode == "clean" || mode == "replace" else { return nil }
        let switchDelayMs = Int(ProcessInfo.processInfo.environment["DIVOOM_CUSTOM_SWITCH_DELAY_MS"] ?? "100") ?? 100
        let frames = framesForCustomSwitch(
            fileId: rest[0],
            deviceId: deviceId,
            pageIndex: pageIndex,
            customId: customId,
            cleanFirst: mode == "clean"
        )
        guard !frames.isEmpty else { return nil }
        return ParsedCommand(frames: frames, delayMs: max(0, switchDelayMs))
    default:
        return nil
    }
}

guard argv.count >= 3 else { usage() }
let mac = argv[1]
let cmd = argv[2]

let isShell = (cmd == "shell")
let isDaemon = (cmd == "daemon" || cmd == "daemon-custom" || cmd == "daemon-custom-multi")

let autoCustom: AutoCustomResponder?
if cmd == "daemon-custom" {
    guard argv.count == 6 || argv.count == 7 else { usage() }
    guard let deviceId = Int(argv[5]) else { usage() }
    let delayMs = argv.count == 7 ? (Int(argv[6]) ?? 40) : 40
    guard let responder = AutoCustomResponder(
        fileId: argv[3],
        rawfilePath: argv[4],
        deviceId: deviceId,
        fileDelayMs: max(0, delayMs)
    ) else {
        exit(65)
    }
    autoCustom = responder
} else if cmd == "daemon-custom-multi" {
    guard argv.count >= 6 else { usage() }
    guard let deviceId = Int(argv[3]), let delayMs = Int(argv[4]) else { usage() }
    let specs = argv.dropFirst(5).map { String($0) }
    var entries: [(String, String)] = []
    for spec in specs {
        guard let eq = spec.firstIndex(of: "="), eq != spec.startIndex else { usage() }
        let fileId = String(spec[..<eq])
        let rawfile = String(spec[spec.index(after: eq)...])
        guard !rawfile.isEmpty else { usage() }
        entries.append((fileId, rawfile))
    }
    guard let responder = AutoCustomResponder(
        entries: entries,
        deviceId: deviceId,
        fileDelayMs: max(0, delayMs)
    ) else {
        exit(65)
    }
    autoCustom = responder
} else {
    autoCustom = nil
}

var commandToSend: ParsedCommand?
if !isShell && !isDaemon {
    guard let parsed = parseCommand(Array(argv.dropFirst(2))) else { usage() }
    commandToSend = parsed
}

guard let device = IOBluetoothDevice(addressString: mac) else {
    log("ERROR: bad MAC \(mac)")
    exit(2)
}

log("refreshing SDP records...")
let sdpResult = device.performSDPQuery(nil)
log("  performSDPQuery = 0x\(String(sdpResult, radix: 16))")
Thread.sleep(forTimeInterval: 1.0)

let sppUUID16 = BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassSerialPort.rawValue)
var sppChannels: [BluetoothRFCOMMChannelID] = []
var nonSppChannels: [(ch: BluetoothRFCOMMChannelID, name: String)] = []

if let records = device.services as? [IOBluetoothSDPServiceRecord] {
    log("SDP services (\(records.count)):")
    for rec in records {
        var rfcommCh: BluetoothRFCOMMChannelID = 0
        let hasRfcomm = rec.getRFCOMMChannelID(&rfcommCh) == kIOReturnSuccess
        let name = rec.getServiceName() ?? "(no name)"
        let isSpp = rec.matchesUUID16(sppUUID16)
        log("  - \(name)  rfcomm_ch=\(hasRfcomm ? String(rfcommCh) : "-")  spp=\(isSpp ? "yes" : "no")")
        guard hasRfcomm else { continue }
        if isSpp {
            if !sppChannels.contains(rfcommCh) { sppChannels.append(rfcommCh) }
        } else {
            nonSppChannels.append((rfcommCh, name))
        }
    }
} else {
    log("SDP services: <none returned>")
}

func channelList(_ chs: [BluetoothRFCOMMChannelID]) -> String {
    return chs.isEmpty ? "none" : chs.map(String.init).joined(separator: ",")
}
let nonSppSummary = nonSppChannels.isEmpty
    ? "none"
    : nonSppChannels.map { "\($0.name):\($0.ch)" }.joined(separator: ",")
log("SDP summary: spp=\(channelList(sppChannels))  non-spp(never tried)=\(nonSppSummary)  paired=\(device.isPaired())")

let delegate = Delegate(autoCustom: autoCustom)
var channel: IOBluetoothRFCOMMChannel?
var openedPort: BluetoothRFCOMMChannelID = 0
var openResult: IOReturn = kIOReturnError

let preferredPort: BluetoothRFCOMMChannelID = 1
let isUploadMode = (cmd == "daemon-custom" || cmd == "daemon-custom-multi")

func parsePortEnv(_ key: String) -> BluetoothRFCOMMChannelID? {
    guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else { return nil }
    guard let n = UInt8(raw), n >= 1, n <= 30 else {
        fatal("\(key)=\(raw) is not an RFCOMM channel number (1-30).", code: 64)
    }
    return BluetoothRFCOMMChannelID(n)
}

let pinnedPort = parsePortEnv("DIVOOM_PORT")
let strictnessOff = (ProcessInfo.processInfo.environment["DIVOOM_REQUIRE_PORT"]?.lowercased() == "any")

let preferredIsAdvertised = sppChannels.contains(preferredPort)
let requiredPort: BluetoothRFCOMMChannelID? = {
    if strictnessOff { return nil }
    if let explicit = parsePortEnv("DIVOOM_REQUIRE_PORT") { return explicit }
    if let pinned = pinnedPort { return pinned }
    if preferredIsAdvertised { return preferredPort }
    return nil
}()
if !preferredIsAdvertised && !sppChannels.isEmpty {
    log("NOTE: SDP does not advertise SPP on channel \(preferredPort) (found \(channelList(sppChannels))).")
    log("NOTE: this is not a MiniToo/Tiivoo 2 SDP layout, so the channel-1 requirement is relaxed.")
}

var portsToTry: [BluetoothRFCOMMChannelID]
if let pinned = pinnedPort {
    portsToTry = [pinned]
    log("port policy: DIVOOM_PORT pins channel \(pinned) (only candidate)")
} else {
    portsToTry = [preferredPort] + sppChannels.filter { $0 != preferredPort }
    log("port policy: preferred=\(preferredPort) candidates=\(channelList(portsToTry))"
        + "  required=\(requiredPort.map(String.init) ?? "none (fallback allowed)")"
        + "  mode=\(isUploadMode ? "upload" : "command")")
}

for port: BluetoothRFCOMMChannelID in portsToTry {
    log("trying RFCOMM port \(port)...")
    openResult = device.openRFCOMMChannelSync(&channel, withChannelID: port, delegate: delegate)
    log("  result = \(ioReturnDesc(openResult))")
    if openResult == kIOReturnSuccess, channel != nil {
        openedPort = port
        break
    }
    channel = nil
    if let required = requiredPort, port == required {
        fatal("""
        RFCOMM channel \(required) would not open (\(ioReturnDesc(openResult))), and this         command requires it.
          Channel \(required) is the only channel that executes commands on this device.
          It accepts exactly one client at a time, so something else is holding it.
        Check, in this order:
          1. A leftover helper on this Mac:   pgrep -x divoom-send
             If anything prints:              core/dv stop
          2. The Divoom app on your phone (force-quit it), or the phone's
             Bluetooth still connected to the device -> disconnect it there.
          3. Another Mac or tablet paired to the same device.
          4. If it still fails, toggle the device off/on in
             System Settings > Bluetooth to force every RFCOMM client off it.
        Not the cause: the device being listed as "Connected" in
        system_profiler, or this Mac using it as an audio output. Both were
        can coexist with the command channel.
        """, code: 3)
    }
}

guard openResult == kIOReturnSuccess, let ch = channel else {
    fatal("""
    could not open any RFCOMM channel (last result \(ioReturnDesc(openResult))).
      Tried: \(channelList(portsToTry))
      Device paired: \(device.isPaired())
    If the device is not paired, pair it in System Settings > Bluetooth first.
    """, code: 3)
}
log("connected on RFCOMM port \(openedPort)")
if openedPort != preferredPort {
    log("WARNING: connected on channel \(openedPort), not the command channel \(preferredPort).")
    log("WARNING: on this firmware only channel \(preferredPort) executes commands --")
    log("WARNING: expect commands to be accepted and silently ignored.")
}

if !isUploadMode {
    sendHandshake(on: ch)
}

func sendFrames(_ frames: [[UInt8]], on channel: IOBluetoothRFCOMMChannel, delayMs: Int = 150) {
    let started = Date()
    log("sendFrames: count=\(frames.count) delay=\(delayMs)ms")
    for (i, bytes) in frames.enumerated() {
        log("tx[\(i)]: \(hex(bytes))")
        noteTx(bytes)
        var mut = bytes
        let result: IOReturn = mut.withUnsafeMutableBufferPointer { buf in
            return channel.writeSync(buf.baseAddress, length: UInt16(buf.count))
        }
        if result != kIOReturnSuccess {
            log("  write failed: 0x\(String(result, radix: 16))")
        }
        if delayMs > 0 {
            Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
        }
    }
    let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
    log("sendFrames: done elapsed=\(elapsedMs)ms")
}

func runDaemonLoop(on channel: IOBluetoothRFCOMMChannel) {
    let fifoPath = ProcessInfo.processInfo.environment["DIVOOM_FIFO"] ?? "/tmp/divoom.fifo"
    let gapMs = Int(ProcessInfo.processInfo.environment["DIVOOM_GAP_MS"] ?? "600") ?? 600
    unlink(fifoPath)
    guard mkfifo(fifoPath, 0o666) == 0 else {
        log("daemon: mkfifo failed errno=\(errno)"); exit(5)
    }
    log("daemon: listening on \(fifoPath)  (gap=\(gapMs)ms)")
    log("daemon: try:   echo 'brightness 10' > \(fifoPath)")

    var buffer = Data()
    var lastSent: Date = .distantPast
    while true {
        guard let fh = FileHandle(forReadingAtPath: fifoPath) else {
            Thread.sleep(forTimeInterval: 0.5); continue
        }
        while true {
            let data = fh.availableData
            if data.isEmpty { break }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line == "quit" || line == "exit" {
                    log("daemon: quit received")
                    daemonShuttingDown = true
                    try? fh.close()
                    unlink(fifoPath)
                    DispatchQueue.main.async {
                        let dwellMs = Int(ProcessInfo.processInfo.environment["DIVOOM_QUIT_DWELL_MS"] ?? "500") ?? 500
                        if dwellMs > 0 { Thread.sleep(forTimeInterval: Double(dwellMs) / 1000.0) }
                        channel.close()
                        log("daemon: rfcomm channel closed (baseband link left up)")
                        exit(0)
                    }
                    return
                }
                let elapsed = Date().timeIntervalSince(lastSent) * 1000
                if elapsed < Double(gapMs) {
                    Thread.sleep(forTimeInterval: (Double(gapMs) - elapsed) / 1000.0)
                }
                let tokens = line.split(separator: " ").map(String.init)
                if let parsed = parseCommand(tokens) {
                    let sema = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        sendFrames(parsed.frames, on: channel, delayMs: parsed.delayMs)
                        sema.signal()
                    }
                    sema.wait()
                    lastSent = Date()
                } else {
                    log("daemon: unknown command: \(line)")
                }
            }
        }
        try? fh.close()
    }
}

if isShell {
    log("shell ready. commands: face <id> | brightness <n> | clock | raw <hex> | quit")
    FileHandle.standardOutput.write(Data("READY\n".utf8))
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        if trimmed == "quit" || trimmed == "exit" { break }
        let tokens = trimmed.split(separator: " ").map(String.init)
        guard let parsed = parseCommand(tokens) else {
            log("? unknown or malformed command: \(trimmed)")
            continue
        }
        sendFrames(parsed.frames, on: ch, delayMs: parsed.delayMs)
    }
    ch.close()
    device.closeConnection()
    log("shell: done")
} else if isDaemon {
    DispatchQueue.global(qos: .userInitiated).async {
        runDaemonLoop(on: ch)
    }
    RunLoop.main.run()
} else {
    guard let command = commandToSend else { usage() }
    sendFrames(command.frames, on: ch, delayMs: command.delayMs)
    let holdMs = Int(ProcessInfo.processInfo.environment["DIVOOM_HOLD_MS"] ?? "1500") ?? 1500
    log("holding channel open for \(holdMs)ms to let device process...")
    Thread.sleep(forTimeInterval: Double(holdMs) / 1000.0)
    ch.close()
    device.closeConnection()
    log("done")
}
