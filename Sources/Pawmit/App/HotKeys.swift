import AppKit
import Carbon.HIToolbox

/// 전역 단축키 (Carbon RegisterEventHotKey). 손쉬운 사용 권한 없이 동작한다.
/// 승인 단축키는 대기 중인 요청이 있을 때만 등록해서 다른 앱의 단축키를 평소에 빼앗지 않는다.
@MainActor
final class HotKeyCenter {
    struct Combo: Equatable, Hashable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// "ctrl+opt+y", "cmd+shift+1" 같은 문자열 파싱
        static func parse(_ text: String) -> Combo? {
            var mods: UInt32 = 0
            var key: UInt32?
            for raw in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                switch raw {
                case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
                case "opt", "option", "alt", "⌥": mods |= UInt32(optionKey)
                case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
                case "shift", "⇧": mods |= UInt32(shiftKey)
                default: key = keyCodes[raw]
                }
            }
            guard let key, mods != 0 else { return nil }
            return Combo(keyCode: key, modifiers: mods)
        }

        /// 버튼에 붙일 표시 (⌃⌥Y)
        var label: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            let name = Combo.keyCodes.first { $0.value == keyCode }?.key ?? "?"
            return s + (name == "return" ? "↩" : name == "space" ? "␣" : name.uppercased())
        }

        static let keyCodes: [String: UInt32] = {
            var map: [String: UInt32] = [
                "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
                "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
                "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
                "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
                "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
                "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
                "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
                "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return), "space": UInt32(kVK_Space),
                "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
            ]
            let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            for (i, code) in digits.enumerated() { map["\(i)"] = UInt32(code) }
            return map
        }()
    }

    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var groups: [String: [UInt32]] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// 같은 group 이름으로 다시 등록하면 이전 것은 지운다
    func register(group: String, _ bindings: [(Combo, () -> Void)]) {
        unregister(group: group)
        installHandler()
        var ids: [UInt32] = []
        for (combo, handler) in bindings {
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x5041_574D), id: id) // 'PAWM'
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else {
                Log.info("단축키 등록 실패 \(combo.label) (다른 앱이 쓰는 중일 수 있음)")
                continue
            }
            refs[id] = ref
            handlers[id] = handler
            ids.append(id)
        }
        groups[group] = ids
    }

    func unregister(group: String) {
        for id in groups[group] ?? [] {
            if let ref = refs[id] { UnregisterEventHotKey(ref) }
            refs.removeValue(forKey: id)
            handlers.removeValue(forKey: id)
        }
        groups.removeValue(forKey: group)
    }
}
