import AppKit
import SwiftUI

enum ContenuPressePapier {
    case texte(String)
    case image(NSImage)
    case urlFichier(URL)
    case inconnu
}

struct ElementPressePapier: Identifiable {
    let id = UUID()
    let contenu: ContenuPressePapier
    let source: String
    let date: Date
    var estEpingle: Bool = false

    // OPTIMISATION 9 : résultat de détection de couleur mis en cache à la création
    // évite de relancer les regex à chaque re-render de la vue
    let couleurCachee: Color?

    init(contenu: ContenuPressePapier, source: String, date: Date, estEpingle: Bool = false) {
        self.contenu     = contenu
        self.source      = source
        self.date        = date
        self.estEpingle  = estEpingle
        // Calcul unique au moment de la création de l'élément
        if case .texte(let t) = contenu {
            self.couleurCachee = ElementPressePapier.detecterCouleurStatique(dans: t)
        } else {
            self.couleurCachee = nil
        }
    }

    // Regex compilées une seule fois (partagées avec ClipboardPanel via accès statique)
    private static let regexHex = try! NSRegularExpression(pattern: "^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$")
    private static let regexRGB = try! NSRegularExpression(pattern: "^rgb\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*\\)$", options: .caseInsensitive)
    private static let regexHSL = try! NSRegularExpression(pattern: "^hsl\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})%\\s*,\\s*(\\d{1,3})%\\s*\\)$", options: .caseInsensitive)

    static func detecterCouleurStatique(dans texte: String) -> Color? {
        let t = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(t.startIndex..., in: t)

        if regexHex.firstMatch(in: t, range: range) != nil {
            var hex = t.dropFirst()
            if hex.count == 3 { hex = Substring(hex.map { "\($0)\($0)" }.joined()) }
            let scanner = Scanner(string: String(hex))
            var rgb: UInt64 = 0
            scanner.scanHexInt64(&rgb)
            return Color(
                red:   Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8)  & 0xFF) / 255,
                blue:  Double( rgb        & 0xFF) / 255
            )
        }

        if regexRGB.firstMatch(in: t, range: range) != nil {
            let nums = t.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            if nums.count >= 3 {
                return Color(red: Double(nums[0])/255, green: Double(nums[1])/255, blue: Double(nums[2])/255)
            }
        }

        if regexHSL.firstMatch(in: t, range: range) != nil {
            let nums = t.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            if nums.count >= 3 {
                return Color(hue: Double(nums[0])/360, saturation: Double(nums[1])/100, brightness: Double(nums[2])/100)
            }
        }

        return nil
    }

    var titreAffiche: String {
        switch contenu {
        case .texte(let s):
            let debut = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(debut.prefix(60))
        case .image: return "Image"
        case .urlFichier(let url): return url.deletingPathExtension().lastPathComponent
        case .inconnu: return "Inconnu"
        }
    }

    var iconeType: String {
        switch contenu {
        case .texte:     return "doc.plaintext"
        case .image:     return "photo"
        case .urlFichier: return "doc"
        case .inconnu:   return "questionmark"
        }
    }

    var couleurType: Color {
        switch contenu {
        case .texte:     return Color.blue
        case .image:     return Color.purple
        case .urlFichier: return Color.orange
        case .inconnu:   return Color.gray
        }
    }
}

final class MoniteurPressePapier: ObservableObject {
    static let shared = MoniteurPressePapier()

    @Published var elements: [ElementPressePapier] = [] { didSet { planifierSauvegarde() } }

    // OPTIMISATION 2 : DispatchWorkItem annulable — plus léger qu'un Timer recréé à chaque changement
    private var workItemSauvegarde: DispatchWorkItem?

    private func planifierSauvegarde() {
        workItemSauvegarde?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.sauvegarderHistorique() }
        workItemSauvegarde = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // MARK: - État de la séquence (publié pour que l'UI puisse l'observer)
    @Published private(set) var fileSequence: [ElementPressePapier] = []
    @Published private(set) var indexSequence: Int = 0

    var estSequenceActive: Bool { !fileSequence.isEmpty }
    var progressionSequence: (actuel: Int, total: Int) { (indexSequence, fileSequence.count) }

    private var minuterieSondage: Timer?
    private var dernierNombreChangements: Int = NSPasteboard.general.changeCount
    private let cleUD = "pressepapier.historique.v2"

    // MARK: - CGEventTap
    private var tapEvenement: CFMachPort?
    private var sourceRunLoop: CFRunLoopSource?

    // Protection contre les appels concurrents à avancerSequence() déclenchés par ⌘V rapides
    private var estEnAvance: Bool = false

    private init() {
        chargerHistorique()
        demarrerSondage()
    }

    // MARK: - Sondage

    private func demarrerSondage() {
        minuterieSondage = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.verifierPressePapier()
        }
    }

    private func verifierPressePapier() {
        let pb = NSPasteboard.general
        guard pb.changeCount != dernierNombreChangements else { return }
        dernierNombreChangements = pb.changeCount
        // Ne pas enregistrer les changements que nous avons déclenchés nous-mêmes (écriture de séquence)
        guard !estSequenceActive else { return }
        let nomApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Inconnu"

        // 1. URLs de fichiers — doit précéder la vérification image
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let premiere = urls.first, premiere.isFileURL {
            ajouterElement(ElementPressePapier(contenu: .urlFichier(premiere), source: nomApp, date: Date()))
            return
        }

        // 2. Vraies images bitmap
        let typesImage: [NSPasteboard.PasteboardType] = [.tiff, .png,
            NSPasteboard.PasteboardType("com.adobe.pdf"),
            NSPasteboard.PasteboardType("public.jpeg")]
        let aDonneesImage = typesImage.contains { pb.data(forType: $0) != nil }
        if aDonneesImage,
           let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let premiere = imgs.first {
            ajouterElement(ElementPressePapier(contenu: .image(premiere), source: nomApp, date: Date()))
            return
        }

        // 3. Texte brut
        if let texte = pb.string(forType: .string), !texte.isEmpty {
            if let dernier = elements.first(where: { !$0.estEpingle }), case .texte(let t) = dernier.contenu, t == texte { return }
            ajouterElement(ElementPressePapier(contenu: .texte(texte), source: nomApp, date: Date()))
        }
    }

    private func ajouterElement(_ element: ElementPressePapier) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // OPTIMISATION 3 : une seule passe sur la liste au lieu de deux .filter() successifs
            var epingles    = [ElementPressePapier]()
            var nonEpingles = [ElementPressePapier]()
            for e in self.elements {
                if e.estEpingle { epingles.append(e) } else { nonEpingles.append(e) }
            }
            nonEpingles.insert(element, at: 0)
            if nonEpingles.count > 150 { nonEpingles = Array(nonEpingles.prefix(150)) }
            self.elements = epingles + nonEpingles
        }
    }

    // MARK: - Actions de base sur le presse-papiers

    func coller(element: ElementPressePapier) {
        copierVersPressePapier(element: element)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let src  = CGEventSource(stateID: .hidSystemState)
            let bas  = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let haut = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            bas?.flags  = .maskCommand; haut?.flags = .maskCommand
            bas?.post(tap: .cgSessionEventTap); haut?.post(tap: .cgSessionEventTap)
        }
    }

    func copierVersPressePapier(element: ElementPressePapier) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch element.contenu {
        case .texte(let t):          pb.setString(t, forType: .string)
        case .image(let img):        pb.writeObjects([img])
        case .urlFichier(let url):   pb.writeObjects([url as NSURL])
        case .inconnu: break
        }
        // Synchroniser dernierNombreChangements pour que le sondage ignore cette écriture
        dernierNombreChangements = pb.changeCount
    }

    func basculerEpingle(element: ElementPressePapier) {
        if let idx = elements.firstIndex(where: { $0.id == element.id }) {
            elements[idx].estEpingle.toggle()
            elements = elements.filter { $0.estEpingle } + elements.filter { !$0.estEpingle }
        }
    }

    func supprimer(element: ElementPressePapier) { elements.removeAll { $0.id == element.id } }
    func toutEffacer() { elements.removeAll { !$0.estEpingle } }

    // MARK: - Demande d'ouverture du panneau

    static let notificationOuverturePanneau = Notification.Name("MoniteurPressePapier.ouvrirPanneau")

    func demanderOuverturePanneau() {
        NotificationCenter.default.post(name: Self.notificationOuverturePanneau, object: self)
    }

    // MARK: - Coller en séquence

    func demarrerSequence(elements: [ElementPressePapier]) {
        guard !elements.isEmpty else { return }
        fileSequence  = elements
        indexSequence = 0
        estEnAvance   = false
        copierVersPressePapier(element: elements[0])
        installerTapEvenement()
    }

    func annulerSequence() {
        fileSequence  = []
        indexSequence = 0
        estEnAvance   = false
        supprimerTapEvenement()
    }

    fileprivate func avancerSequence() {
        guard estSequenceActive, !estEnAvance else { return }
        estEnAvance = true

        indexSequence += 1
        if indexSequence < fileSequence.count {
            copierVersPressePapier(element: fileSequence[indexSequence])
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.annulerSequence()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.estEnAvance = false
        }
    }

    // MARK: - Installation du CGEventTap

    private func installerTapEvenement() {
        supprimerTapEvenement()

        let masque = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: masque,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let moniteur = Unmanaged<MoniteurPressePapier>.fromOpaque(refcon).takeUnretainedValue()
                let codeTouche = event.getIntegerValueField(.keyboardEventKeycode)
                if codeTouche == 9, event.flags.contains(.maskCommand) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        moniteur.avancerSequence()
                    }
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            let alerte = NSAlert()
            alerte.messageText = L.titreAccessibilite
            alerte.informativeText = L.texteAccessibilite
            alerte.alertStyle = .warning
            alerte.addButton(withTitle: L.ouvrirReglages)
            alerte.addButton(withTitle: L.annuler)
            if alerte.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            annulerSequence()
            return
        }

        tapEvenement = tap
        sourceRunLoop = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), sourceRunLoop, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func supprimerTapEvenement() {
        if let tap = tapEvenement {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = sourceRunLoop {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            tapEvenement  = nil
            sourceRunLoop = nil
        }
    }

    // MARK: - Persistance

    private func sauvegarderHistorique() {
        let dicts = elements.compactMap { element -> [String: Any]? in
            var d: [String: Any] = ["source": element.source, "date": element.date.timeIntervalSince1970, "epingle": element.estEpingle]
            switch element.contenu {
            case .texte(let t):        d["type"] = "texte"; d["valeur"] = t
            case .urlFichier(let url): d["type"] = "fichier"; d["valeur"] = url.absoluteString
            default: return nil  // images non persistées intentionnellement
            }
            return d
        }
        UserDefaults.standard.set(dicts, forKey: cleUD)
    }

    private func chargerHistorique() {
        guard let dicts = UserDefaults.standard.object(forKey: cleUD) as? [[String: Any]] else { return }
        elements = dicts.compactMap { d in
            guard let type = d["type"] as? String,
                  let val  = d["valeur"] as? String,
                  let src  = d["source"] as? String,
                  let ts   = d["date"] as? TimeInterval else { return nil }
            let contenu: ContenuPressePapier
            if type == "fichier", let url = URL(string: val) {
                contenu = .urlFichier(url)
            } else {
                contenu = .texte(val)
            }
            var element = ElementPressePapier(contenu: contenu, source: src, date: Date(timeIntervalSince1970: ts))
            element.estEpingle = d["epingle"] as? Bool ?? false
            return element
        }
    }
}
