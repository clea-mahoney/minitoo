import Foundation
import CoreAudio

setvbuf(stdout, nil, _IOLBF, 0)

let DEFAULT_EXCLUDE = ["minitoo", "tiivoo", "divoom"]
let DEFAULT_PREFER_OUTPUT = ["macbook pro speakers", "built-in", "soundcore"]
let DEFAULT_PREFER_INPUT = ["macbook pro microphone", "built-in microphone", "imac microphone"]

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("audio-guard: " + msg + "\n").utf8))
    exit(1)
}

func systemObject() -> AudioObjectID { return AudioObjectID(kAudioObjectSystemObject) }

func getDeviceIDs() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject(), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(systemObject(), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func cfStringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    let buf = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<CFString?>.alignment)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return nil }
    guard let cf = buf.assumingMemoryBound(to: CFString?.self).pointee else { return nil }
    return cf as String
}

func deviceName(_ id: AudioObjectID) -> String {
    return cfStringProperty(id, kAudioObjectPropertyName) ?? "(unknown)"
}

func deviceUID(_ id: AudioObjectID) -> String {
    return cfStringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
}

func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func outputChannelCount(_ id: AudioObjectID) -> Int { channelCount(id, scope: kAudioObjectPropertyScopeOutput) }
func inputChannelCount(_ id: AudioObjectID) -> Int { channelCount(id, scope: kAudioObjectPropertyScopeInput) }

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject(), &addr, 0, nil, &size, &id) == noErr else { return 0 }
    return id
}

func setDefaultDevice(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value = id
    let size = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectSetPropertyData(systemObject(), &addr, 0, nil, size, &value) == noErr
}

func defaultOutputDevice() -> AudioObjectID { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }
func defaultInputDevice() -> AudioObjectID { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
func setDefaultOutputDevice(_ id: AudioObjectID) -> Bool { setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, id) }
func setDefaultInputDevice(_ id: AudioObjectID) -> Bool { setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, id) }

var args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "status"
if !args.isEmpty { args.removeFirst() }

func optValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let excludeTerms: [String] = (optValue("--exclude") ?? DEFAULT_EXCLUDE.joined(separator: ","))
    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
let preferOutputTerm = optValue("--prefer-output")?.lowercased()
let preferInputTerm = optValue("--prefer-input")?.lowercased()

func isExcluded(_ name: String) -> Bool {
    let lower = name.lowercased()
    return excludeTerms.contains { lower.contains($0) }
}

struct AudioDevice {
    let id: AudioObjectID
    let name: String
    let channels: Int
}

func outputDevices() -> [AudioDevice] {
    return getDeviceIDs().compactMap { id in
        let ch = outputChannelCount(id)
        return ch > 0 ? AudioDevice(id: id, name: deviceName(id), channels: ch) : nil
    }
}

func inputDevices() -> [AudioDevice] {
    return getDeviceIDs().compactMap { id in
        let ch = inputChannelCount(id)
        return ch > 0 ? AudioDevice(id: id, name: deviceName(id), channels: ch) : nil
    }
}

let outputAllowFile = (ProcessInfo.processInfo.environment["CLAUDDY_AUDIO_OUTPUT_ALLOW"]
                 ?? (NSHomeDirectory() + "/.clauddy/audio-output-allow"))

func outputAllowedNow() -> Bool {
    guard let s = try? String(contentsOfFile: outputAllowFile, encoding: .utf8) else { return false }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let expiry = Int(t) else { return true } // malformed/empty: treat as open-ended allow
    return Int(Date().timeIntervalSince1970) < expiry
}

let outputStateFile = (ProcessInfo.processInfo.environment["CLAUDDY_AUDIO_OUTPUT_STATE"]
                 ?? (NSHomeDirectory() + "/.clauddy/audio-output-last-good"))
let inputStateFile = (ProcessInfo.processInfo.environment["CLAUDDY_AUDIO_STATE"]
                 ?? (NSHomeDirectory() + "/.clauddy/audio-input-last-good"))

func rememberGood(_ stateFile: String, _ name: String) {
    let dir = (stateFile as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? name.write(toFile: stateFile, atomically: true, encoding: .utf8)
}

func lastGoodName(_ stateFile: String) -> String? {
    guard let s = try? String(contentsOfFile: stateFile, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

func isPreferred(_ id: AudioObjectID, name: String, preferOrder: [String]) -> Bool {
    if deviceUID(id).lowercased().contains("builtin") { return true }
    let lower = name.lowercased()
    return preferOrder.contains { lower.contains($0) }
}

func isVirtual(_ name: String) -> Bool {
    let virtualTerms = ["teams", "zoom", "loopback", "blackhole", "soundflower", "aggregate", "krisp", "obs"]
    let lower = name.lowercased()
    return virtualTerms.contains { lower.contains($0) }
}

func pickReplacement(_ devices: [AudioDevice], preferTerm: String?, stateFile: String, preferOrder: [String]) -> AudioDevice? {
    let usable = devices.filter { !isExcluded($0.name) }
    if usable.isEmpty { return nil }
    if let want = preferTerm, let hit = usable.first(where: { $0.name.lowercased().contains(want) }) { return hit }
    if let good = lastGoodName(stateFile)?.lowercased(), let hit = usable.first(where: { $0.name.lowercased() == good }) { return hit }
    if let preferred = usable.first(where: { isPreferred($0.id, name: $0.name, preferOrder: preferOrder) }) { return preferred }
    return usable.first
}

func reportOutput() {
    let outId = defaultOutputDevice()
    let name = deviceName(outId)
    print("default output: \(name)\(isExcluded(name) ? "   << EXCLUDED" : "")\(outputAllowedNow() ? "   (allow-window open)" : "")")
}

func reportInput() {
    let inId = defaultInputDevice()
    let name = deviceName(inId)
    print("default input:  \(name)\(isExcluded(name) ? "   << EXCLUDED" : "")")
}

func enforceOutput(verbose: Bool) -> Bool {
    if outputAllowedNow() {
        if verbose { print("allow-window open (\(outputAllowFile)) -- leaving output alone") }
        return false
    }
    let current = defaultOutputDevice()
    let currentName = deviceName(current)
    if !isExcluded(currentName) {
        if !currentName.isEmpty && currentName != "(unknown)" { rememberGood(outputStateFile, currentName) }
        if verbose { print("output is \(currentName) -- allowed, nothing to do") }
        return false
    }
    guard let replacement = pickReplacement(outputDevices(), preferTerm: preferOutputTerm, stateFile: outputStateFile, preferOrder: DEFAULT_PREFER_OUTPUT) else {
        FileHandle.standardError.write(Data("no non-excluded output device available; leaving \(currentName) as output\n".utf8))
        return false
    }
    if setDefaultOutputDevice(replacement.id) {
        print("output was \(currentName) (excluded, no allow-window) -> switched to \(replacement.name)")
        rememberGood(outputStateFile, replacement.name)
        return true
    }
    FileHandle.standardError.write(Data("failed to set default output to \(replacement.name)\n".utf8))
    return false
}

func enforceInput(verbose: Bool) -> Bool {
    let current = defaultInputDevice()
    let currentName = deviceName(current)
    if !isExcluded(currentName) {
        if !currentName.isEmpty && currentName != "(unknown)" { rememberGood(inputStateFile, currentName) }
        if verbose { print("input is \(currentName) -- allowed, nothing to do") }
        return false
    }
    guard let replacement = pickReplacement(inputDevices(), preferTerm: preferInputTerm, stateFile: inputStateFile, preferOrder: DEFAULT_PREFER_INPUT) else {
        FileHandle.standardError.write(Data("no non-excluded input device available; leaving \(currentName) as input\n".utf8))
        return false
    }
    if setDefaultInputDevice(replacement.id) {
        print("input was \(currentName) (excluded) -> switched to \(replacement.name)")
        rememberGood(inputStateFile, replacement.name)
        return true
    }
    FileHandle.standardError.write(Data("failed to set default input to \(replacement.name)\n".utf8))
    return false
}

switch cmd {
case "list":
    print("output devices:")
    for d in outputDevices() {
        let marks = [
            d.id == defaultOutputDevice() ? "DEFAULT" : nil,
            isExcluded(d.name) ? "excluded" : nil,
        ].compactMap { $0 }
        print("  \(d.name)  ch=\(d.channels)  uid=\(deviceUID(d.id))\(marks.isEmpty ? "" : "  [\(marks.joined(separator: ","))]")")
    }
    print("")
    print("input devices:")
    for d in inputDevices() {
        let marks = [
            d.id == defaultInputDevice() ? "DEFAULT" : nil,
            isExcluded(d.name) ? "excluded" : nil,
            isVirtual(d.name) ? "virtual" : nil,
        ].compactMap { $0 }
        print("  \(d.name)  ch=\(d.channels)  uid=\(deviceUID(d.id))\(marks.isEmpty ? "" : "  [\(marks.joined(separator: ","))]")")
    }
    print("")
    reportOutput()
    reportInput()

case "status":
    reportOutput()
    reportInput()
    let outBad = isExcluded(deviceName(defaultOutputDevice())) && !outputAllowedNow()
    let inBad = isExcluded(deviceName(defaultInputDevice()))
    exit((outBad || inBad) ? 2 : 0)

case "fix":
    _ = enforceOutput(verbose: true)
    _ = enforceInput(verbose: true)

case "set-output":
    guard let want = args.first(where: { !$0.hasPrefix("--") })?.lowercased() else {
        fail("set-output needs a device name substring")
    }
    guard let hit = outputDevices().first(where: { $0.name.lowercased().contains(want) }) else {
        fail("no output device matching '\(want)'")
    }
    if setDefaultOutputDevice(hit.id) {
        print("default output set to \(hit.name)")
    } else {
        fail("could not set default output to \(hit.name)")
    }

case "set-input":
    guard let want = args.first(where: { !$0.hasPrefix("--") })?.lowercased() else {
        fail("set-input needs a device name substring")
    }
    guard let hit = inputDevices().first(where: { $0.name.lowercased().contains(want) }) else {
        fail("no input device matching '\(want)'")
    }
    if setDefaultInputDevice(hit.id) {
        print("default input set to \(hit.name)")
    } else {
        fail("could not set default input to \(hit.name)")
    }

case "watch":
    _ = enforceOutput(verbose: true)
    _ = enforceInput(verbose: true)

    var addrOut = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let queueOut = DispatchQueue(label: "audio-guard.watch.output")
    let statusOut = AudioObjectAddPropertyListenerBlock(systemObject(), &addrOut, queueOut) { _, _ in
        _ = enforceOutput(verbose: false)
        if isExcluded(deviceName(defaultOutputDevice())) && !outputAllowedNow() {
            Thread.sleep(forTimeInterval: 0.4)
            _ = enforceOutput(verbose: false)
        }
    }
    if statusOut != noErr {
        fail("could not register a CoreAudio output listener (status \(statusOut))")
    }

    var addrIn = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let queueIn = DispatchQueue(label: "audio-guard.watch.input")
    let statusIn = AudioObjectAddPropertyListenerBlock(systemObject(), &addrIn, queueIn) { _, _ in
        _ = enforceInput(verbose: false)
        if isExcluded(deviceName(defaultInputDevice())) {
            Thread.sleep(forTimeInterval: 0.4)
            _ = enforceInput(verbose: false)
        }
    }
    if statusIn != noErr {
        fail("could not register a CoreAudio input listener (status \(statusIn))")
    }

    print("watching default-output/input changes; excluding: \(excludeTerms.joined(separator: ",")); output allow-file: \(outputAllowFile)")
    RunLoop.main.run()

default:
    print("""
    Usage:
      audio-guard list
      audio-guard status                 # exit 2 if an excluded device is output (no allow-window) or input
      audio-guard fix        [--exclude a,b] [--prefer-output <substr>] [--prefer-input <substr>]
      audio-guard watch      [--exclude a,b] [--prefer-output <substr>] [--prefer-input <substr>]
      audio-guard set-output <name-substring>
      audio-guard set-input  <name-substring>

    Default exclusions: \(DEFAULT_EXCLUDE.joined(separator: ", "))
    Output allow-file: \(outputAllowFile) (contents: empty = open-ended allow, or a unix
    timestamp the allow-window expires at. Scripts that want the MiniToo as
    output touch this before switching and remove it right after restoring.)
    Input has no allow-file -- the MiniToo mic is never wanted.
    """)
    exit(64)
}
