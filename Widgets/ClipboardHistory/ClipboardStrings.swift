import Foundation
import DockDoorWidgetSDK

// MARK: - Centralised widget localisation

/// Returns the language chosen in the widget settings.
/// Possible values: "fr" (French) or "en" (default).
func widgetLanguage() -> String {
    WidgetDefaults.string(key: "langue", widgetId: "clipboard-history", default: "en")
}

/// Returns the string matching the active language.
/// Usage: S("Coller", "Paste")
func S(_ fr: String, _ en: String) -> String {
    widgetLanguage() == "en" ? en : fr
}

// MARK: - All interface strings

enum L {
    // Filters
    static var all:   String { S("Tout",    "All") }
    static var media: String { S("Médias",  "Media") }
    static var data:  String { S("Données", "Data") }

    // Sections
    static var pinned: String { S("Épinglés", "Pinned") }
    static var recent: String { S("Récents",  "Recent") }

    // Preview panel actions
    static var paste:         String { S("Coller",  "Paste") }
    static var copy:          String { S("Copier",  "Copy") }
    static var pinItem:       String { S("Épingler l'élément",   "Pin item") }
    static var deleteItem:    String { S("Supprimer l'élément", "Delete item") }
    static var openInBrowser: String { S("Ouvrir dans le navigateur", "Open in browser") }
    static var clearHistory:  String { S("Effacer l'historique",     "Clear history") }

    // Preview buttons
    static var pasteTitle: String { S("Coller", "Paste") }
    static var copyTitle:  String { S("Copier", "Copy") }
    static var copyHint:   String { S("Copier dans le presse-papiers", "Copy to clipboard") }
    static var pasteHint:  String { S("Coller directement", "Paste directly") }

    // Empty preview
    static var selectItem: String { S("Sélectionnez un élément", "Select an item") }
    static func emptyFilter(filter: String = "") -> String {
        if widgetLanguage() == "en" {
            switch filter {
            case "Media": return "Nothing to see here 👀"
            case "Data":  return "Empty as a Monday morning"
            default:      return "Pretty quiet around here..."
            }
        }
        switch filter {
        case "Médias":  return "Rien à voir ici 👀"
        case "Données": return "Vide comme un lundi matin"
        default:        return "C'est calme par ici..."
        }
    }

    // Item type labels (list)
    static var color: String { S("Couleur", "Color") }
    static var link:  String { S("Lien",    "Link") }
    static var text:  String { S("Texte",   "Text") }

    // Color picker
    static var colorPicker:           String { S("Pipette",  "Color Picker") }
    static var cancelColorPicker:     String { S("Annuler",  "Cancel") }
    static var colorPickerStartHint:  String { S("Choisir une couleur à l'écran",        "Pick a color on screen") }
    static var colorPickerActiveHint: String { S("Cliquez n'importe où pour choisir une couleur", "Click anywhere to pick a color") }

    // Multi-paste
    static var multiPaste: String { S("Copies multiples",   "Multi-paste") }
    static var tapToAdd:   String { S("Appuyer pour ajouter", "Tap to add") }
    static var start:      String { S("Démarrer", "Start") }
    static var cancel:     String { S("Annuler",  "Cancel") }

    static func itemCount(_ n: Int) -> String {
        if widgetLanguage() == "en" {
            return "\(n) \(n >= 2 ? "items" : "item")"
        } else {
            return "\(n) \(n >= 2 ? "éléments" : "élément")"
        }
    }

    // File
    static func file(ext: String) -> String {
        S("Fichier " + ext, ext + " File")
    }

    // DateFormatter locale
    static var dateLocale: Locale {
        Locale(identifier: widgetLanguage() == "en" ? "en_US" : "fr_FR")
    }

    // Accessibility alerts (ClipboardMonitor)
    static var accessibilityTitle: String { S("Permission d'accessibilité requise",
                                               "Accessibility Permission Required") }
    static var accessibilityText: String {
        S("Coller en séquence nécessite l'accès à l'Accessibilité pour détecter ⌘V globalement. Veuillez l'activer dans Réglages Système → Confidentialité et sécurité → Accessibilité.",
          "Multi-paste requires Accessibility access to detect ⌘V globally. Please enable it in System Settings → Privacy & Security → Accessibility.")
    }
    static var openSettings: String { S("Ouvrir les réglages", "Open Settings") }

    // Plugin settings
    static var iconLabel:            String { S("Icône du widget",                          "Widget Icon") }
    static var shortcutLabel:        String { S("Raccourci d'ouverture du panneau",         "Panel Shortcut") }
    static var languageLabel:        String { S("Langue de l'interface (redémarrage requis)", "Interface Language (restart required)") }
    static var shortcutPlaceholder:  String { S("ex : option+v  /  cmd+shift+k",            "e.g. option+v  /  cmd+shift+k") }
}
