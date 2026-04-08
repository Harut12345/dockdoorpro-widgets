import Foundation
import DockDoorWidgetSDK

// MARK: - Localisation centralisée du widget Presse-papiers

/// Récupère la langue choisie dans les réglages du widget.
/// Valeurs possibles : "fr" (défaut) ou "en".
func langueWidget() -> String {
    WidgetDefaults.string(key: "langue", widgetId: "clipboard-history", default: "en")
}

/// Retourne la chaîne correspondant à la langue active.
/// Usage : S("Coller", "Paste")
func S(_ fr: String, _ en: String) -> String {
    langueWidget() == "en" ? en : fr
}

// MARK: - Toutes les chaînes de l'interface

enum L {
    // Filtres
    static var tout:    String { S("Tout",   "All") }
    static var images:  String { S("Images", "Images") }
    static var liens:   String { S("Liens",  "Links") }

    // Sections
    static var epingles: String { S("Épinglés", "Pinned") }
    static var recents:  String { S("Récents",  "Recent") }

    // Actions panneau aperçu
    static var coller:   String { S("Coller",  "Paste") }
    static var copier:   String { S("Copier",  "Copy") }
    static var epingler: String { S("Épingler l'élément",   "Pin item") }
    static var supprimer: String { S("Supprimer l'élément", "Delete item") }
    static var ouvrirNavig: String { S("Ouvrir dans le navigateur", "Open in browser") }
    static var effacerHisto: String { S("Effacer l'historique",     "Clear history") }

    // Boutons aperçu
    static var collerTitre:  String { S("Coller", "Paste") }
    static var copierTitre:  String { S("Copier", "Copy") }
    static var copierAide:   String { S("Copier dans le presse-papiers", "Copy to clipboard") }
    static var collerAide:   String { S("Coller directement", "Paste directly") }

    // Aperçu vide
    static var selectionnerElement: String { S("Sélectionnez un élément", "Select an item") }
    static func videFiltre(filtre: String = "") -> String {
        if langueWidget() == "en" { return "None" }
        switch filtre {
        case "Images": return "Aucune image"
        case "Liens":  return "Aucun lien"
        default:       return "Aucun"
        }
    }

    // Types d'éléments (liste)
    static var couleur: String { S("Couleur", "Color") }
    static var lien:    String { S("Lien",    "Link") }
    static var texte:   String { S("Texte",   "Text") }

    // Pipette
    static var pipette:          String { S("Pipette",  "Color Picker") }
    static var annulerPipette:   String { S("Annuler",  "Cancel") }
    static var aideDebutPipette: String { S("Choisir une couleur à l'écran",        "Pick a color on screen") }
    static var aideEnCoursPipette: String { S("Cliquez n'importe où pour choisir une couleur", "Click anywhere to pick a color") }

    // Copies multiples
    static var copiesMultiples: String { S("Copies multiples",   "Multi-paste") }
    static var appuyerAjouter:  String { S("Appuyer pour ajouter", "Tap to add") }
    static var demarrer:        String { S("Démarrer", "Start") }
    static var annuler:         String { S("Annuler",  "Cancel") }

    static func nbElements(_ n: Int) -> String {
        if langueWidget() == "en" {
            return "\(n) \(n >= 2 ? "items" : "item")"
        } else {
            return "\(n) \(n >= 2 ? "éléments" : "élément")"
        }
    }

    // Fichier
    static func fichier(ext: String) -> String {
        S("Fichier " + ext, ext + " File")
    }

    // DateFormatter (locale)
    static var localeDate: Locale {
        Locale(identifier: langueWidget() == "en" ? "en_US" : "fr_FR")
    }

    // Alertes accessibilité (MoniteurPressePapier)
    static var titreAccessibilite: String { S("Permission d'accessibilité requise",
                                               "Accessibility Permission Required") }
    static var texteAccessibilite: String {
        S("Coller en séquence nécessite l'accès à l'Accessibilité pour détecter ⌘V globalement. Veuillez l'activer dans Réglages Système → Confidentialité et sécurité → Accessibilité.",
          "Multi-paste requires Accessibility access to detect ⌘V globally. Please enable it in System Settings → Privacy & Security → Accessibility.")
    }
    static var ouvrirReglages: String { S("Ouvrir les réglages", "Open Settings") }

    // Réglages plugin
    static var labelIcone:    String { S("Widget Icon",                       "Widget Icon") }
    static var labelRaccourci: String { S("Panel Open Shortcut",     "Panel Shortcut") }
    static var labelLangue:   String { "Interface Language (restart required)" }
    static var placeholderRaccourci: String { S("ex : option+v  /  cmd+shift+k",  "e.g. option+v  /  cmd+shift+k") }
}
