import Cocoa

/// Modifier-aware shortcuts for editor commands. These are deliberately kept
/// separate from the overlay's single-key tool shortcuts.
enum EditorCommandShortcutManager {
    enum Action: String, CaseIterable {
        case undo
        case redo

        var label: String {
            switch self {
            case .undo: return L("Undo")
            case .redo: return L("Redo")
            }
        }

        fileprivate var defaultShortcuts: [Shortcut] {
            switch self {
            case .undo:
                return [Shortcut(character: "z", modifiers: [.command])]
            case .redo:
                return [
                    Shortcut(character: "z", modifiers: [.command, .shift]),
                    Shortcut(character: "y", modifiers: [.command]),
                ]
            }
        }
    }

    struct Shortcut: Codable, Equatable {
        let character: String
        let modifiersRawValue: UInt

        init(character: String, modifiers: NSEvent.ModifierFlags) {
            self.character = character.lowercased()
            self.modifiersRawValue = modifiers
                .intersection(KeyboardShortcutMatcher.relevantModifiers)
                .rawValue
        }

        var modifiers: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiersRawValue)
        }
    }

    static func defaultsKey(for action: Action) -> String {
        "editorCommandShortcuts.\(action.rawValue)"
    }

    static func shortcuts(for action: Action) -> [Shortcut] {
        let key = defaultsKey(for: action)
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return action.defaultShortcuts
        }
        guard let data = UserDefaults.standard.data(forKey: key),
              let shortcuts = try? JSONDecoder().decode([Shortcut].self, from: data) else {
            return action.defaultShortcuts
        }
        return shortcuts
    }

    static func setShortcut(_ shortcut: Shortcut, for action: Action) {
        // A chord can only resolve to one command. If it belonged to the other
        // action (including one of that action's defaults), remove that binding.
        for otherAction in Action.allCases where otherAction != action {
            let existing = shortcuts(for: otherAction)
            let filtered = existing.filter { $0 != shortcut }
            if filtered.count != existing.count,
               let data = try? JSONEncoder().encode(filtered) {
                UserDefaults.standard.set(data, forKey: defaultsKey(for: otherAction))
            }
        }
        guard let data = try? JSONEncoder().encode([shortcut]) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey(for: action))
    }

    static func disable(_ action: Action) {
        guard let data = try? JSONEncoder().encode([Shortcut]()) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey(for: action))
    }

    static func reset(_ action: Action) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(for: action))
    }

    static func action(for event: NSEvent) -> Action? {
        for action in Action.allCases {
            for shortcut in shortcuts(for: action)
            where KeyboardShortcutMatcher.matches(
                event,
                character: shortcut.character,
                modifiers: shortcut.modifiers
            ) {
                return action
            }
        }
        return nil
    }

    static func displayString(for action: Action) -> String {
        let values = shortcuts(for: action).map { displayString(for: $0) }
        return values.isEmpty ? L("None") : values.joined(separator: " / ")
    }

    static func applyPrimaryMenuShortcut(for action: Action, to item: NSMenuItem) {
        guard let shortcut = shortcuts(for: action).first else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = shortcut.character
        item.keyEquivalentModifierMask = shortcut.modifiers
    }

    private static func displayString(for shortcut: Shortcut) -> String {
        var result = ""
        let modifiers = shortcut.modifiers
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += shortcut.character.uppercased()
        return result
    }
}
