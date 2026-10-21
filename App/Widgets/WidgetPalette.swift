import SwiftUI
import UIKit

/// The app's colours, redeclared for the widget extension.
///
/// The extension does not compile the app's Design folder and has no asset
/// catalogue of its own — see project.yml, where `PocketdWidgets` takes
/// `App/Widgets`, `App/Shared` and a handful of named Kit files and nothing
/// else. So the values are literals here, which is a duplicate and is meant to
/// be read as one: each one is the light/dark pair of the `Color.pd` token it is
/// named after (App/Sources/Design/Theme.swift), and if that token moves, this
/// moves with it by hand.
///
/// One palette for every widget rather than one per file. The Today and
/// Routines widgets used to disagree — cream and Pocketd's ink on one, the
/// system's grey fill, orange and green on the other — so two widgets from the
/// same app looked like they came from two.
///
/// A `UIColor` dynamic provider rather than two `Color`s and a `colorScheme`
/// check, because the widget's rendering environment resolves the trait in every
/// place a widget is drawn — gallery, home screen, StandBy, a Live Activity on a
/// dark lock screen — and a manual branch would have to be threaded into every
/// nested view that draws anything.
///
/// Computed rather than stored: these are cheap, and a stored global would be a
/// global initialiser running a UIKit closure on whichever thread got there
/// first.
enum WidgetPalette {
    /// Behind every home-screen widget and the Live Activity: the app's cream
    /// `canvas` in the light, and its `card` in the dark — the canvas's
    /// near-black reads as a hole in a dark home screen, where a card reads as
    /// a card.
    static var background: Color { dynamic(light: 0xFFFEFB, dark: 0x1E1C19) }
    static var ink: Color { dynamic(light: 0x242424, dark: 0xF1EFEA) }
    /// `Color.pd.inkSecondary` — darkened in the app to pass 4.5:1, so the
    /// widget's grey lines pass with it.
    static var secondary: Color { dynamic(light: 0x686868, dark: 0xA39F97) }
    /// `Color.pd.inkTertiary`. Decoration only, as in the app: never words.
    static var tertiary: Color { dynamic(light: 0x8A8A8A, dark: 0x7C7871) }
    static var accent: Color { dynamic(light: 0x39649E, dark: 0x8FB0EA) }
    static var positive: Color { dynamic(light: 0x2E613F, dark: 0x79CF95) }
    static var caution: Color { dynamic(light: 0x7D541D, dark: 0xE0B364) }
    static var divider: Color { dynamic(light: 0xE5E5E5, dark: 0x2C2926) }
    static var track: Color { dynamic(light: 0xDEE0DB, dark: 0x34312C) }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? uiColor(dark) : uiColor(light)
        })
    }

    private static func uiColor(_ rgb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
