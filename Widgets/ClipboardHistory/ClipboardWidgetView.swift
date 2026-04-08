import SwiftUI
import DockDoorWidgetSDK

struct VuePressePapiersWidget: View {
    let taille: CGSize
    let estVertical: Bool
    @ObservedObject var moniteur: MoniteurPressePapier
    var symboleIcone: String = "clipboard.fill"
    /// Contrôlé par le réglage "Afficher l'icône" dans les paramètres du widget.
    /// Par défaut false : la vue double affiche uniquement le texte.
    var afficherIcone: Bool = false

    private var dim: CGFloat { min(taille.width, taille.height) }
    private var estEtendu: Bool {
        estVertical ? taille.height > taille.width * 1.5 : taille.width > taille.height * 1.5
    }

    var body: some View {
        Group {
            if estEtendu { dispositionEtendue } else { dispositionCompacte }
        }
    }

    // MARK: - Compact : icône seule

    private var dispositionCompacte: some View {
        Image(systemName: symboleIcone)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: dim * 0.437, height: dim * 0.437)
            .foregroundStyle(.secondary)
    }

    // MARK: - Étendu : texte centré (+ icône optionnelle)

    private var dernierCopie: ElementPressePapier? {
        moniteur.elements.first { !$0.estEpingle }
    }

    private var dispositionEtendue: some View {
        HStack(spacing: dim * 0.08) {
            if afficherIcone {
                Image(systemName: symboleIcone)
                    .font(.system(size: dim * 0.28))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if let dernier = dernierCopie {
                TexteDefilantWidget(element: dernier, dim: dim, estVertical: estVertical)
            } else {
                Text(S("Vide", "Empty"))
                    .font(.system(size: dim * 0.28))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(dim * 0.10)
    }
}

// MARK: - Widget texte défilant

private struct TexteDefilantWidget: View {
    let element: ElementPressePapier
    let dim: CGFloat
    let estVertical: Bool

    private var taillePolic: CGFloat {
        let proportionnelle = estVertical ? dim * 0.30 : dim * 0.32
        return max(proportionnelle - 1, 9)
    }

    private var facteurMin: CGFloat {
        taillePolic > 9 ? (9 / taillePolic) : 1.0
    }

    var body: some View {
        Text(element.titreAffiche)
            .font(.system(size: taillePolic, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(facteurMin)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
