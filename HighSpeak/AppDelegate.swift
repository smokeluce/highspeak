import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenu()

        let vc = ViewController()
        window = NSWindow(contentViewController: vc)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 540, height: 660))
        window.minSize = NSSize(width: 440, height: 460)
        window.title = "HighSpeak - 2011"
        // Flat, modern titlebar: transparent, same color as the transcript page.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedRed: 245.0/255.0, green: 245.0/255.0, blue: 247.0/255.0, alpha: 1)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // Minimal menu bar: a way to change the stored API key later, a working
    // Quit item, and an Edit menu so Cmd-C/V/X/A work (copying replies out of
    // the transcript, pasting the API key). This app has no MainMenu.xib.
    func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        // No explicit target: this routes through the responder chain to
        // ViewController.promptForAPIKeyMenuAction() via the window's
        // contentViewController.
        appMenu.addItem(NSMenuItem(title: "Set Groq API Key...",
                                    action: #selector(ViewController.promptForAPIKeyMenuAction),
                                    keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit HighSpeak",
                                    action: #selector(NSApplication.terminate(_:)),
                                    keyEquivalent: "q"))

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        // Chat menu
        let chatMenuItem = NSMenuItem()
        mainMenu.addItem(chatMenuItem)
        let chatMenu = NSMenu(title: "Chat")
        chatMenuItem.submenu = chatMenu
        chatMenu.addItem(NSMenuItem(title: "Clear Chat",
                                    action: #selector(ViewController.clearChatAction),
                                    keyEquivalent: "k"))

        // Speech menu
        let speechMenuItem = NSMenuItem()
        mainMenu.addItem(speechMenuItem)
        let speechMenu = NSMenu(title: "Speech")
        speechMenuItem.submenu = speechMenu
        speechMenu.addItem(NSMenuItem(title: "Speak Replies",
                                      action: #selector(ViewController.speakRepliesAction),
                                      keyEquivalent: ""))
        speechMenu.addItem(NSMenuItem(title: "Speak Code Blocks",
                                      action: #selector(ViewController.speakCodeAction),
                                      keyEquivalent: ""))
        speechMenu.addItem(NSMenuItem.separator())

        let rateItem = NSMenuItem(title: "Speech Rate", action: nil, keyEquivalent: "")
        let rateMenu = NSMenu(title: "Speech Rate")
        let rates: [(String, Int)] = [("Slower", 150), ("Normal", 185), ("Faster", 230)]
        for (title, wpm) in rates {
            let it = NSMenuItem(title: title, action: #selector(ViewController.rateAction(_:)), keyEquivalent: "")
            it.tag = wpm
            rateMenu.addItem(it)
        }
        rateItem.submenu = rateMenu
        speechMenu.addItem(rateItem)

        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu(title: "Voice")
        var voices = NSSpeechSynthesizer.availableVoices
        let english = voices.filter { v in
            let attrs = NSSpeechSynthesizer.attributes(forVoice: v)
            let loc = attrs[NSSpeechSynthesizer.VoiceAttributeKey.localeIdentifier] as? String ?? ""
            return loc.hasPrefix("en")
        }
        if !english.isEmpty { voices = english }
        for v in voices {
            let attrs = NSSpeechSynthesizer.attributes(forVoice: v)
            let name = attrs[NSSpeechSynthesizer.VoiceAttributeKey.name] as? String ?? v.rawValue
            let it = NSMenuItem(title: name, action: #selector(ViewController.voiceAction(_:)), keyEquivalent: "")
            it.representedObject = v.rawValue
            voiceMenu.addItem(it)
        }
        voiceItem.submenu = voiceMenu
        speechMenu.addItem(voiceItem)

        // View menu (theme)
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        let light = NSMenuItem(title: "Light Theme", action: #selector(ViewController.themeAction(_:)), keyEquivalent: "")
        light.tag = 0
        viewMenu.addItem(light)
        let darkItem = NSMenuItem(title: "Dark Theme", action: #selector(ViewController.themeAction(_:)), keyEquivalent: "")
        darkItem.tag = 1
        viewMenu.addItem(darkItem)

        NSApp.mainMenu = mainMenu
    }
}
