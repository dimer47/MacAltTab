// Mises à jour, même principe qu'À Voix Haute :
// - dernière version lue sur l'API publique de GitHub (aucun jeton embarqué) ;
// - rien n'est installé sans accord ;
// - le DMG doit être notarisé ET signé par notre équipe, sinon il est refusé ;
// - un script détaché remplace l'app après sa sortie, puis la relance.

import AppKit

final class Updater {
    static let shared = Updater()
    private static let repo = "dimer47/MacAltTab"
    private static let team = "5D6QHL72QC"
    private var timer: Timer?
    private var busy = false

    static var auto: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    static var installed: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Une vérification maintenant, puis chaque jour : l'app reste lancée des semaines.
    func start() {
        timer?.invalidate()
        guard Self.auto else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.check(silent: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(silent: true)
        }
    }

    func check(silent: Bool) {
        guard !busy else { return }
        busy = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacAltTab/\(Self.installed)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                self.busy = false
                guard err == nil, (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = o["tag_name"] as? String,
                      let assets = o["assets"] as? [[String: Any]],
                      let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                      let s = dmg["browser_download_url"] as? String, let url = URL(string: s) else {
                    if !silent { self.alert("Vérification impossible", "GitHub n'a pas répondu. Réessaie plus tard.") }
                    return
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard Self.isNewer(version, than: Self.installed) else {
                    if !silent { self.alert("À jour", "MacAltTab \(Self.installed) est la dernière version.") }
                    return
                }
                self.offer(version, notes: o["body"] as? String ?? "", url: url)
            }
        }.resume()
    }

    /// « 1.10.0 » > « 1.9.0 » : comparaison segment par segment.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func offer(_ version: String, notes: String, url: URL) {
        let a = NSAlert()
        a.messageText = "MacAltTab \(version) est disponible"
        a.informativeText = "Version installée : \(Self.installed)\n\n" + String(notes.prefix(1200))
        a.addButton(withTitle: "Installer et relancer")
        a.addButton(withTitle: "Plus tard")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        install(url, version: version)
    }

    private func install(_ url: URL, version: String) {
        busy = true
        URLSession.shared.downloadTask(with: url) { tmp, resp, err in
            var failure: String?
            do {
                guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Fail("Téléchargement échoué.") }
                let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("MacAltTab-\(version).dmg")
                try? FileManager.default.removeItem(at: dmg)
                try FileManager.default.moveItem(at: tmp, to: dmg)
                try Self.verify(dmg)
                try Self.replace(from: dmg)
            } catch { failure = (error as? Fail)?.message ?? error.localizedDescription }
            DispatchQueue.main.async {
                self.busy = false
                if let failure { self.alert("Mise à jour impossible", failure) }
                else { NSApp.terminate(nil) } // le script attend notre sortie
            }
        }.resume()
    }

    struct Fail: Error { let message: String; init(_ m: String) { message = m } }

    /// Notarisé par Apple ne suffit pas : il faut aussi notre identifiant d'équipe.
    private static func verify(_ dmg: URL) throws {
        let (status, out) = run("/usr/sbin/spctl", ["-a", "-vvv", "-t", "open", "--context", "context:primary-signature", dmg.path])
        guard status == 0, out.contains("accepted"), out.contains("Notarized Developer ID"), out.contains(team) else {
            throw Fail("Signature du téléchargement refusée.")
        }
    }

    private static func replace(from dmg: URL) throws {
        let (status, out) = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"])
        guard status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: Any],
              let mount = (plist["system-entities"] as? [[String: Any]])?.compactMap({ $0["mount-point"] as? String }).first
        else { throw Fail("Impossible d'ouvrir le DMG.") }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount, "-quiet"]) }

        guard let name = try FileManager.default.contentsOfDirectory(atPath: mount).first(where: { $0.hasSuffix(".app") }) else {
            throw Fail("Aucune app dans le DMG.")
        }
        let current = Bundle.main.bundleURL
        let staged = current.deletingLastPathComponent().appendingPathComponent(".MacAltTab-nouvelle.app")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: mount).appendingPathComponent(name), to: staged)

        // L'app ne peut pas se remplacer pendant qu'elle tourne : un script prend le relais.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("permuter-\(UUID().uuidString).sh")
        try """
        #!/bin/bash
        PID=$1; NOUVELLE="$2"; ANCIENNE="$3"
        for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        rm -rf "$ANCIENNE" && mv "$NOUVELLE" "$ANCIENNE"
        open "$ANCIENNE"
        rm -f "$0"
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, String(getpid()), staged.path, current.path]
        try p.run()
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
